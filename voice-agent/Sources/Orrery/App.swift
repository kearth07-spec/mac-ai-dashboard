import AppKit
import SwiftUI

/// ウィンドウの重なり方。ボタンか ⌘T で切り替える。
enum HUDWindowMode: String {
    case normal
    case front
    case desktop

    var label: String {
        switch self {
        case .normal: return "通常"
        case .front: return "最前面"
        case .desktop: return "デスクトップ"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "macwindow"
        case .front: return "pin.fill"
        case .desktop: return "rectangle.on.rectangle"
        }
    }

    var next: HUDWindowMode {
        switch self {
        case .normal: return .front
        case .front: return .desktop
        case .desktop: return .normal
        }
    }

    var windowLevel: NSWindow.Level {
        switch self {
        case .normal: return .normal
        case .front: return .floating
        case .desktop: return NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }

    /// 通常と最前面ではふつうのウィンドウとして扱う（Mission Controlやウィンドウ整列に出る）。
    /// デスクトップのときだけ壁紙のように振る舞わせる。
    var collectionBehavior: NSWindow.CollectionBehavior {
        switch self {
        case .normal: return [.fullScreenPrimary]
        case .front: return [.canJoinAllSpaces, .fullScreenAuxiliary]
        case .desktop: return [.canJoinAllSpaces, .stationary, .ignoresCycle]
        }
    }

    /// デスクトップに敷いているときは動かさない
    var isMovable: Bool { self != .desktop }
}

/// ウィンドウ操作のうち、メニューから呼ぶもの。
enum WindowActions {
    private static var target: NSWindow? {
        NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible }
    }

    /// 動かしたりリサイズしたあと、画面いっぱいに戻す
    static func fitToScreen() {
        guard let window = target, let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(screen.visibleFrame, display: true, animate: true)
    }

    /// 画面中央に、少し小さめで置く
    static func centerSmall() {
        guard let window = target, let screen = window.screen ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = CGSize(width: area.width * 0.62, height: area.height * 0.62)
        window.setFrame(CGRect(x: area.midX - size.width / 2,
                               y: area.midY - size.height / 2,
                               width: size.width, height: size.height),
                        display: true, animate: true)
    }
}

@MainActor
final class HUDWindowState: ObservableObject {
    /// メニューバーと声の両方から使うので、アプリ全体で1つにする
    static let shared = HUDWindowState()

    @Published var mode: HUDWindowMode = .normal
    /// Codexと音声で話している最中かどうか（Claude系は指示を渡して終わるのでセッションにならない）
    @Published private(set) var sessionActive = false
    @Published private(set) var notice: String?
    /// お知らせの下に出す設定ボタン（nilなら出さない）
    @Published private(set) var noticePane: PrivacySettings.Pane?

    @Published private(set) var starting = false

    private var modeBeforeSession: HUDWindowMode = .normal
    private var sessionTarget: AgentTarget = .codex
    private var noticeStamp = 0

    /// ボタンでも音声コマンドでも、ここを通ってAIを起動する。
    /// command は合図のあとに話した内容（Claude系ではそのまま指示として渡す）。
    func requestVoiceSession(command: String = "") {
        guard !sessionActive, !starting else { return }
        let target = HUDConfig.agentTarget
        let command = target.acceptsSpokenCommand ? command : ""
        starting = true
        AgentLauncher.start(target, command: command) { [weak self] outcome in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.starting = false
                self.handle(outcome, target: target, command: command)
            }
        }
    }

    private func handle(_ outcome: AgentLauncher.Outcome, target: AgentTarget, command: String) {
        switch outcome {
        case .started:
            if target.usesVoiceSession {
                show(nil)
                beginSession(target: target)
            } else if command.isEmpty {
                show("\(target.label) を開きました", autoHide: true)
            } else {
                show("\(target.label) に送りました ▸ 「\(command)」", autoHide: true)
            }
        case .needsAccessibility:
            switch target {
            case .codex:
                show("音声モードは Codex 側で ⌃⇧V を押すと開きます。"
                     + "自動で開くには システム設定 › プライバシーとセキュリティ › アクセシビリティ でこのアプリを許可してください。",
                     pane: .accessibility)
                beginSession(target: target)
            default:
                show("Claudeアプリを開きました。"
                     + (command.isEmpty ? "" : "話した内容はクリップボードにあるので ⌘V で貼り付けられます。")
                     + "自動で入力するには アクセシビリティ でこのアプリを許可してください。",
                     pane: .accessibility)
            }
        case .notInstalled:
            switch target {
            case .codex: show("Codexアプリ（\(AgentLauncher.codexBundleIdentifier)）が見つかりませんでした。")
            default: show("Claudeアプリ（\(AgentLauncher.claudeBundleIdentifier)）が見つかりませんでした。"
                          + "claude.ai/download からインストールしてください。")
            }
        case .needsAutomation:
            show("ターミナルを操作する許可がありません。"
                 + "システム設定 › プライバシーとセキュリティ › オートメーション で Orrery の「ターミナル」をONにしてください。",
                 pane: .automation)
        case .failed(let message):
            show(message)
        }
    }

    private func show(_ text: String?, pane: PrivacySettings.Pane? = nil, autoHide: Bool = false) {
        noticeStamp += 1
        notice = text
        noticePane = pane
        guard autoHide else { return }
        let stamp = noticeStamp
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.noticeStamp == stamp else { return }
                self.notice = nil
            }
        }
    }

    func endVoiceSession() {
        endSession()
        AgentLauncher.activate(sessionTarget)
    }

    /// セッション中はHUDを最前面に出し、終わったら元の重なり方に戻す
    func beginSession(target: AgentTarget) {
        guard !sessionActive else { return }
        sessionTarget = target
        modeBeforeSession = mode
        sessionActive = true
        mode = .front
    }

    func endSession() {
        guard sessionActive else { return }
        sessionActive = false
        mode = modeBeforeSession
        show(nil)
    }
}

@main
struct OrreryApp: App {
    static let windowID = "hud"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var audio = AudioSpectrum()
    @StateObject private var windowState = HUDWindowState.shared
    @StateObject private var settings = HUDSettings.shared

    init() {
        // ウィンドウを開く前から（ログイン時の自動起動でも）声と手拍子を聞けるように、ここで用意する
        Services.shared.connectWakeWord()
    }

    var body: some Scene {
        // ウィンドウは1枚だけ。閉じても（⌘W）アプリは裏で聞き取りを続ける
        Window("ORRERY", id: Self.windowID) {
            HUDView()
                .environmentObject(audio)
                .environmentObject(audio.settings)
                .environmentObject(windowState)
                .ignoresSafeArea()
                .background(WindowConfigurator(mode: windowState.mode,
                                               background: HUD.palette.backgroundNS))
                .task { await audio.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("表示") {
                Button("重なり方を切り替え（現在: \(windowState.mode.label)）") {
                    windowState.mode = windowState.mode.next
                }
                .keyboardShortcut("t", modifiers: .command)
                Divider()
                Button("画面いっぱいに合わせる") { WindowActions.fitToScreen() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("中央に小さく置く") { WindowActions.centerSmall() }
                    .keyboardShortcut("9", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
        }

        // ウィンドウを閉じていても、メニューバーのアイコンから開いたり止めたりできる
        MenuBarExtra("ORRERY", systemImage: "waveform.circle") {
            MenuBarContent()
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    let mode: HUDWindowMode
    let background: NSColor

    func makeNSView(context: Context) -> NSView { NSView() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ view: NSView, context: Context) {
        let mode = self.mode
        let background = self.background
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if !coordinator.configured {
                coordinator.configured = true
                Self.configureOnce(window)
            }
            // 重なり方はモードごとに、背景色はテーマごとに切り替える
            window.level = mode.windowLevel
            window.collectionBehavior = mode.collectionBehavior
            window.isMovable = mode.isMovable
            window.isMovableByWindowBackground = mode.isMovable
            window.backgroundColor = background
        }
    }

    /// 一度だけの設定。ここでフレームを決め、以後はユーザーの移動やリサイズを尊重する。
    private static func configureOnce(_ window: NSWindow) {
        window.title = "ORRERY"
        // 背景は不透明に塗っているので、透明ウィンドウにしない。
        // 透明だと再描画のたびに背後との合成が走って重くなる。
        window.isOpaque = true
        window.backgroundColor = NSColor(calibratedRed: 0.015, green: 0.025, blue: 0.04, alpha: 1)
        window.hasShadow = true

        // タイトルバーは透明にするが、リサイズと最小化はふつうに使えるようにしておく
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert([.fullSizeContentView, .resizable, .miniaturizable, .closable])
        for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.setContentBorderThickness(0, for: .minY)

        if let override = ProcessInfo.processInfo.environment["HUD_WINDOW"] {
            // 切り分け用: HUD_WINDOW=1200x800
            let parts = override.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2, let screen = window.screen ?? NSScreen.main {
                window.setFrame(CGRect(x: screen.visibleFrame.minX + 40,
                                       y: screen.visibleFrame.minY + 40,
                                       width: parts[0], height: parts[1]), display: true)
            }
        } else if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
        }
        window.minSize = CGSize(width: 900, height: 600)
    }

    final class Coordinator {
        var configured = false
    }
}
