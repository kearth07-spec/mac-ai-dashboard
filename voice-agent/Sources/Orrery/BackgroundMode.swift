import AppKit
import ServiceManagement
import SwiftUI

/// ウィンドウを閉じても終了せず、裏で声と手拍子を聞き続けるための設定。
/// ⌘Q もウィンドウを閉じるだけにして、本当の終了はメニューバーの「完全に終了」から行う。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// true のときだけ本当に終了する
    nonisolated(unsafe) static var allowQuit = false

    static func quit() {
        allowQuit = true
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if Self.allowQuit { return .terminateNow }
        // ログアウト・再起動・シャットダウンのときは止めない
        if NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil {
            return .terminateNow
        }
        // ふつうの ⌘Q はウィンドウを閉じるだけ（メニューバーのアイコンは titled ではないので残る）
        for window in sender.windows where window.isVisible && window.styleMask.contains(.titled) {
            window.close()
        }
        AudioSpectrum.log("⌘Q: ウィンドウを閉じて裏で聞き取りを続けます")
        return .terminateCancel
    }
}

/// Macにログインしたら自動で起動する（システム設定 › 一般 › ログイン項目 に載る）。
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AudioSpectrum.log("login item: \(error.localizedDescription)")
            // 承認待ちなどで登録できないときは、ログイン項目の設定画面を開いて手で許可してもらう
            if enabled { SMAppService.openSystemSettingsLoginItems() }
        }
    }
}

/// 画面上部のメニューバーに常に出るメニュー。ウィンドウを閉じていてもここから操作できる。
struct MenuBarContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject private var windowState = HUDWindowState.shared
    @ObservedObject private var wake = Services.shared.wake
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        Text(wake.isListening ? "● 聞き取り中（声・手拍子）" : "○ 聞き取り停止中")
        Button("ダッシュボードを開く") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: OrreryApp.windowID)
        }
        Divider()
        Toggle("声・手拍子で起動", isOn: $wake.enabled)
        Toggle("手拍子（パンパン）でも起動", isOn: $settings.clapEnabled)
        Button("\(HUDConfig.agentTarget.label) をいま起動") {
            windowState.requestVoiceSession()
        }
        Divider()
        Toggle("Macにログインしたら自動で起動", isOn: Binding(
            get: { LoginItem.isEnabled },
            set: { LoginItem.set($0) }))
        Divider()
        Button("ORRERY を完全に終了") { AppDelegate.quit() }
    }
}
