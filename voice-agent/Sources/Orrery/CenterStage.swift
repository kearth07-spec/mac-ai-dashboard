import SwiftUI

struct CenterStage: View {
    @EnvironmentObject private var audio: AudioSpectrum
    let cpu: Double
    let memory: Double
    @State private var started = Date()

    var body: some View {
        ZStack {
            // 絵の更新はこのサブツリーだけで完結させる（画面全体の再レイアウトを避ける）
            HostedAnimation {
                DialTimeline(audio: audio, cpu: cpu, memory: memory, started: started)
            }
            CodexReadout(isLive: audio.isLive,
                         source: audio.sourceLabel,
                         isTargeted: audio.isTargeted)
        }
        .overlay(alignment: .bottom) { CodexButton() }
    }
}

private struct CodexReadout: View {
    let isLive: Bool
    let source: String
    let isTargeted: Bool

    private static let tracking: CGFloat = 14

    private func smallButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(HUD.mono(9, .bold))
                .tracking(1.2)
                .foregroundStyle(HUD.warn)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(HUD.warn.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("MUSCLE")
                .font(.system(size: 64, weight: .black, design: .default))
                .tracking(Self.tracking)
                // trackingは最後の文字の後ろにも隙間を作るので、その半分だけ右に寄せて中心を合わせる
                .padding(.leading, Self.tracking)
                .foregroundStyle(.white)
                .shadow(color: HUD.cyan.opacity(isLive ? 0.9 : 0.45), radius: 18)

            HStack(spacing: 7) {
                Circle()
                    .fill(isLive ? HUD.up : HUD.cyan.opacity(0.3))
                    .frame(width: 6, height: 6)
                    .shadow(color: HUD.up.opacity(isLive ? 0.9 : 0), radius: 5)
                Text(isLive ? "SPEAKING" : "STANDBY")
                    .font(HUD.mono(10, .bold))
                    .tracking(2.2)
                    .foregroundStyle(isLive ? .white : HUD.cyan.opacity(0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(HUD.cyan.opacity(isLive ? 0.14 : 0.04)))
            .overlay(Capsule().stroke(HUD.cyan.opacity(isLive ? 0.5 : 0.15), lineWidth: 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isLive)

            Text("SOURCE ▸ \(source)")
                .font(HUD.mono(9, .semibold))
                .tracking(1.4)
                .foregroundStyle((isTargeted ? HUD.cyan : HUD.warn).opacity(0.6))
                .lineLimit(1)

            if source == "NO ACCESS" {
                HStack(spacing: 8) {
                    smallButton("設定を開く") { PrivacySettings.open(.screenCapture) }
                    smallButton("許可したら再起動") { PrivacySettings.relaunch() }
                }
            }
        }
    }
}

/// 押すと設定で選んだAIが立ち上がる。Codexのときは話している間HUDが最前面に出る。
private struct CodexButton: View {
    @EnvironmentObject private var windowState: HUDWindowState
    /// 起動するAIが変わったらボタンの文言を変える
    @ObservedObject private var settings = HUDSettings.shared
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 9) {
            AnswerBubble(assistant: Services.shared.assistant)

            Button(action: toggle) {
                HStack(spacing: 9) {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .bold))
                    Text(title)
                        .font(HUD.mono(12, .bold))
                        .tracking(2)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 11)
                .background(
                    Capsule().fill(LinearGradient(
                        colors: windowState.sessionActive
                            ? [HUD.up.opacity(0.34), HUD.cyan.opacity(0.34)]
                            : [HUD.cyan.opacity(0.34), HUD.violet.opacity(0.34)],
                        startPoint: .leading, endPoint: .trailing))
                )
                .overlay(Capsule().stroke(HUD.cyan.opacity(hovering ? 0.9 : 0.45), lineWidth: 1))
                .shadow(color: HUD.cyan.opacity(hovering ? 0.55 : 0.25), radius: hovering ? 16 : 8)
                .scaleEffect(hovering ? 1.04 : 1)
            }
            .buttonStyle(.plain)
            .disabled(windowState.starting)
            .onHover { hovering = $0 }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)

            if let notice = windowState.notice {
                VStack(spacing: 6) {
                    Text(notice)
                        .font(HUD.mono(10))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(HUD.warn.opacity(0.85))
                        .frame(maxWidth: 460)
                    if let pane = windowState.noticePane {
                        HStack(spacing: 8) {
                            noticeButton(pane == .automation ? String("オートメーション設定を開く") : String("アクセシビリティ設定を開く")) {
                                PrivacySettings.open(pane)
                            }
                            noticeButton("許可したら再起動") { PrivacySettings.relaunch() }
                        }
                    }
                }
            }
        }
    }

    private func noticeButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(HUD.mono(9, .bold))
                .tracking(1.2)
                .foregroundStyle(HUD.warn)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(Capsule().stroke(HUD.warn.opacity(0.5), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var title: String {
        if windowState.sessionActive { return "セッション終了" }
        return windowState.starting ? "起動中…" : HUDConfig.agentTarget.buttonTitle
    }

    private var icon: String {
        if windowState.sessionActive { return "stop.circle.fill" }
        return HUDConfig.agentTarget == .claudeCode ? "terminal.fill" : "waveform.circle.fill"
    }

    private func toggle() {
        if windowState.sessionActive {
            windowState.endVoiceSession()
        } else {
            windowState.requestVoiceSession()
        }
    }
}

/// 中央の絵の更新だけを回す。
private struct DialTimeline: View {
    let audio: AudioSpectrum
    let cpu: Double
    let memory: Double
    let started: Date

    var body: some View {
        if HUDConfig.isStatic {
            OrreryDial(snapshot: audio.current, cpu: cpu, memory: memory)
        } else {
            TimelineView(.periodic(from: started,
                                   by: HUDConfig.frameInterval(isLive: audio.isLive))) { _ in
                OrreryDial(snapshot: audio.current, cpu: cpu, memory: memory)
            }
        }
    }
}

/// マッスルの答え。考え中・読み上げ中・失敗を表示し、答えの全文を読めるようにする。
private struct AnswerBubble: View {
    @ObservedObject var assistant: VoiceAssistant

    var body: some View {
        if !assistant.question.isEmpty || !assistant.answer.isEmpty || isFailed {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .bold))
                    Text(status)
                        .font(HUD.mono(9, .bold))
                        .tracking(1.6)
                    Spacer()
                    if assistant.isBusy {
                        Button("止める") { assistant.stop() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundStyle(isFailed ? HUD.warn : HUD.cyan)

                if !assistant.question.isEmpty {
                    Text("「\(assistant.question)」")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(2)
                }
                if case .failed(let message) = assistant.phase {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(HUD.warn)
                        .fixedSize(horizontal: false, vertical: true)
                } else if assistant.phase == .thinking {
                    Text("考えています…（10〜20秒ほどかかることがあります）")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                } else if !assistant.answer.isEmpty {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(assistant.answer)
                            .font(.system(size: 13))
                            .foregroundStyle(.white)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 150)
                }
            }
            .padding(14)
            .frame(width: 520)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HUD.cyan.opacity(0.35), lineWidth: 1))
        }
    }

    private var isFailed: Bool {
        if case .failed = assistant.phase { return true }
        return false
    }

    private var status: String {
        switch assistant.phase {
        case .thinking: return "THINKING"
        case .speaking: return "SPEAKING"
        case .failed: return "ERROR"
        case .idle: return "MUSCLE"
        }
    }

    private var icon: String {
        switch assistant.phase {
        case .thinking: return "ellipsis.bubble"
        case .speaking: return "speaker.wave.2.fill"
        case .failed: return "exclamationmark.triangle"
        case .idle: return "bubble.left"
        }
    }
}
