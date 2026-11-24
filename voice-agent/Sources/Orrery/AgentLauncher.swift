import AppKit
import ApplicationServices

/// 声やボタンで起動するAI。設定画面（⌘,）の「一般 › 起動するAI」か HUD_AGENT で切り替える。
enum AgentTarget: String, CaseIterable, Identifiable {
    /// マッスル自身が答える。Claude Code に聞いて、答えを画面に出して読み上げる
    case voiceChat
    /// Claudeデスクトップアプリ。新しいチャットを開き、話した内容をそのまま送る
    case claudeApp
    /// ターミナルで Claude Code を起動し、話した内容を最初の指示として渡す
    case claudeCode
    /// Codexアプリの音声ライブ（元のORRERYの動き）
    case codex

    var id: String { rawValue }

    /// 設定画面に出す名前
    var label: String {
        switch self {
        case .voiceChat: return "マッスルと会話（声で答える）"
        case .claudeApp: return "Claudeアプリ"
        case .claudeCode: return "Claude Code（ターミナル）"
        case .codex: return "Codex（音声ライブ）"
        }
    }

    /// HUDに出す短い名前
    var shortName: String {
        switch self {
        case .voiceChat: return "MUSCLE"
        case .claudeApp: return "CLAUDE"
        case .claudeCode: return "CLAUDE CODE"
        case .codex: return "CODEX"
        }
    }

    var buttonTitle: String {
        switch self {
        case .voiceChat: return "マッスルに話す"
        case .claudeApp: return "CLAUDE と話す"
        case .claudeCode: return "CLAUDE CODE 起動"
        case .codex: return "CODEX と話す"
        }
    }

    /// 音を拾う対象アプリの既定（HUD_AUDIO_APPS で上書き可）
    var audioKeyword: String {
        switch self {
        case .voiceChat, .claudeApp, .claudeCode: return "claude"
        case .codex: return "codex"
        }
    }

    /// Codexは向こうの音声ライブで会話するので「セッション」としてHUDを最前面に出す。
    /// Claude系は話した内容を文字で渡して終わり。
    var usesVoiceSession: Bool { self == .codex }

    /// 合図のあとに続けて話した内容を指示として受け取るか
    var acceptsSpokenCommand: Bool { self != .codex }

    /// HUD_AGENT の値（claude / claude-app / claude-code / codex など）を解釈する
    init?(loose raw: String) {
        let key = raw.lowercased().filter { $0.isLetter }
        switch key {
        case "voice", "voicechat", "chat", "muscle": self = .voiceChat
        case "claude", "claudeapp", "claudedesktop": self = .claudeApp
        case "claudecode", "code", "cc": self = .claudeCode
        case "codex": self = .codex
        default: return nil
        }
    }
}

/// 選ばれたAIを立ち上げる。
enum AgentLauncher {
    static let codexBundleIdentifier = "com.openai.codex"
    static let claudeBundleIdentifier = "com.anthropic.claudefordesktop"

    private nonisolated(unsafe) static var didPromptAccessibility = false

    private enum Key {
        static let n: CGKeyCode = 45
        static let v: CGKeyCode = 9
        static let returnKey: CGKeyCode = 36
    }

    enum Outcome {
        /// 立ち上げて、必要なキー操作や指示の受け渡しまで済んだ
        case started
        /// アプリは開いたが、アクセシビリティ未許可でキーを送れなかった
        case needsAccessibility
        /// 対象のアプリが見つからない
        case notInstalled
        /// ターミナルの操作（オートメーション）が許可されていない
        case needsAutomation
        case failed(String)
    }

    /// completion は必ずメインスレッドで呼ぶ
    static func start(_ target: AgentTarget, command: String,
                      completion: @escaping (Outcome) -> Void) {
        switch target {
        case .voiceChat: completion(.started)   // マッスル自身が答えるので、外のアプリは開かない
        case .codex: startCodex(completion: completion)
        case .claudeApp: startClaudeApp(command: command, completion: completion)
        case .claudeCode: startClaudeCode(command: command, completion: completion)
        }
    }

    /// セッションを終えたときに対象アプリを前面へ戻す
    static func activate(_ target: AgentTarget) {
        switch target {
        case .voiceChat: break
        case .codex: open(bundleIdentifier: codexBundleIdentifier) { _ in }
        case .claudeApp: open(bundleIdentifier: claudeBundleIdentifier) { _ in }
        case .claudeCode:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: url, configuration: .init(), completionHandler: nil)
            }
        }
    }

    // MARK: - Codex

    /// ⌘N で新しいチャット → ⌃⇧V で音声ライブ
    private static func startCodex(completion: @escaping (Outcome) -> Void) {
        openAndFocus(bundleIdentifier: codexBundleIdentifier) { state in
            switch state {
            case .missing: completion(.notInstalled)
            case .untrusted: completion(.needsAccessibility)
            case .ready:
                send(key: Key.n, flags: .maskCommand)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    send(key: Key.v, flags: [.maskControl, .maskShift])
                    completion(.started)
                }
            }
        }
    }

    // MARK: - Claudeアプリ

    /// ⌘N で新しいチャット → 話した内容を貼り付けて送信
    private static func startClaudeApp(command: String, completion: @escaping (Outcome) -> Void) {
        openAndFocus(bundleIdentifier: claudeBundleIdentifier) { state in
            switch state {
            case .missing:
                completion(.notInstalled)
            case .untrusted:
                // キーは送れないが、せめて内容はクリップボードに置いて ⌘V で貼れるようにする
                if !command.isEmpty { setClipboard(command) }
                completion(.needsAccessibility)
            case .ready:
                send(key: Key.n, flags: .maskCommand)
                guard !command.isEmpty else {
                    completion(.started)
                    return
                }
                // 新しいチャットの入力欄にフォーカスが移るのを待つ
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    paste(command) {
                        send(key: Key.returnKey, flags: [])
                        completion(.started)
                    }
                }
            }
        }
    }

    // MARK: - Claude Code

    /// ターミナルの新しいウィンドウで `cd <作業フォルダ> && claude "<話した内容>"` を実行する
    private static func startClaudeCode(command: String, completion: @escaping (Outcome) -> Void) {
        var line = "cd \(shellQuote(HUDConfig.claudeCodeDirectory)) && claude"
        if !command.isEmpty { line += " \(shellQuote(command))" }

        let source = """
        tell application "Terminal"
            activate
            do script "\(appleScriptEscape(line))"
        end tell
        """

        DispatchQueue.main.async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else {
                completion(.started)
                return
            }
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            AudioSpectrum.log("claude code: AppleScript error \(code)")
            // -1743: オートメーションが許可されていない
            if code == -1743 {
                completion(.needsAutomation)
            } else {
                completion(.failed("ターミナルを開けませんでした（エラー \(code)）"))
            }
        }
    }

    // MARK: - 共通

    private enum FocusState { case ready, untrusted, missing }

    private static func open(bundleIdentifier: String, completion: @escaping (Bool) -> Void) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            completion(false)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { completion(true) }
        }
    }

    /// アプリを開いて前面に来るまで待つ。キーを送れる状態かどうかを返す。
    private static func openAndFocus(bundleIdentifier: String,
                                     completion: @escaping (FocusState) -> Void) {
        open(bundleIdentifier: bundleIdentifier) { found in
            guard found else {
                completion(.missing)
                return
            }
            // 許可ダイアログは1回の起動につき1度だけ。毎回出すと押すたびに出てしまう。
            let trusted = AXIsProcessTrusted()
            if !trusted, !didPromptAccessibility {
                didPromptAccessibility = true
                _ = AXIsProcessTrustedWithOptions(
                    [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
            }
            guard trusted else {
                completion(.untrusted)
                return
            }
            // ショートカットはアプリ内スコープなので、前面に出るまで待つ
            waitUntilFrontmost(bundleIdentifier: bundleIdentifier, remaining: 16) { isFront in
                completion(isFront ? .ready : .untrusted)
            }
        }
    }

    private static func waitUntilFrontmost(bundleIdentifier: String, remaining: Int,
                                           completion: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleIdentifier {
            // 前面になった直後はキーを取りこぼすので少しだけ置く
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { completion(true) }
            return
        }
        guard remaining > 0 else {
            completion(false)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            waitUntilFrontmost(bundleIdentifier: bundleIdentifier, remaining: remaining - 1,
                               completion: completion)
        }
    }

    private static func send(key: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private static func setClipboard(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
    }

    /// クリップボード経由で貼り付ける（日本語もそのまま入る）。元の内容はあとで戻す。
    private static func paste(_ text: String, then next: @escaping () -> Void) {
        let board = NSPasteboard.general
        let previous = board.string(forType: .string)
        setClipboard(text)
        send(key: Key.v, flags: .maskCommand)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            next()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                if let previous { setClipboard(previous) }
            }
        }
    }

    private static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
