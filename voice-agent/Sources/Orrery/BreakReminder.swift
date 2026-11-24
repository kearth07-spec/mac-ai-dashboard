import AppKit
import CoreGraphics
@preconcurrency import UserNotifications

/// 座りっぱなしを防ぐ休憩リマインダー。
/// キーボードやトラックパッドを5分以上触らなければ「休憩した」とみなし、
/// 続けて作業した時間が設定の分数（既定50分）を超えたら知らせる。
@MainActor
final class BreakReminder: ObservableObject {
    struct Stretch {
        let name: String
        let how: String
    }

    /// デスクワークの合間にできる、椅子のまわりで済むストレッチ
    static let stretches: [Stretch] = [
        Stretch(name: "あご引き（チンイン）",
                how: "目線は正面のまま、あごを真後ろへスッと引く。首の後ろが伸びるのを感じて5秒×10回。前に出た頭の姿勢をリセットします。"),
        Stretch(name: "胸を開く",
                how: "両手を背中で組み、肩甲骨を寄せて胸を張る。息を止めずに20秒。丸まった背中と巻き肩をリセットします。"),
        Stretch(name: "首の横を伸ばす",
                how: "右手を頭の左側に添え、ゆっくり右へ倒す。左肩は下げたまま20秒、反対側も。"),
        Stretch(name: "太もも裏を伸ばす",
                how: "椅子に浅く座り片脚を前に伸ばす。背すじを伸ばしたまま、おへそを前に出すように倒して20秒、反対側も。"),
        Stretch(name: "かかと上げ",
                how: "立ってかかとをゆっくり上げ下げ×15回。ふくらはぎのポンプで、下半身にたまった血流を戻します。"),
        Stretch(name: "腰をそらす",
                how: "立って腰に両手を当て、ゆっくり後ろへそらして2秒キープ×5回。座りっぱなしで曲がった腰をリセットします。"),
        Stretch(name: "肩回し",
                how: "両手を肩に置き、ひじで大きな円を描くように後ろ回し×10回。肩甲骨から動かすのがコツです。")
    ]

    /// この秒数だけ何も触らなければ休憩とみなす
    static let restThreshold: TimeInterval = 5 * 60

    @Published private(set) var workedSeconds: TimeInterval = 0
    @Published private(set) var isDue = false
    @Published private(set) var stretchIndex = Int.random(in: 0..<BreakReminder.stretches.count)

    var stretch: Stretch { Self.stretches[stretchIndex % Self.stretches.count] }

    private var sessionStart = Date()
    private var notified = false
    private var ticker: Timer?

    func start() {
        guard ticker == nil else { return }
        sessionStart = Date()
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        tick()
    }

    /// 「休憩した」ボタン
    func tookBreak() {
        reset(at: Date())
        nextStretch()
    }

    func nextStretch() {
        stretchIndex = (stretchIndex + 1) % Self.stretches.count
    }

    private func reset(at date: Date) {
        sessionStart = date
        workedSeconds = 0
        isDue = false
        notified = false
    }

    private func tick() {
        let now = Date()
        // 最後にキーボード・マウス・トラックパッドを触ってからの秒数
        let inputs: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown,
                                     .scrollWheel, .leftMouseDragged]
        let idle = inputs
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0

        if idle >= Self.restThreshold {
            // 離席中。戻ってきたところから数え直す
            if workedSeconds > 0 || isDue { reset(at: now) } else { sessionStart = now }
            return
        }

        workedSeconds = now.timeIntervalSince(sessionStart)
        let settings = HUDSettings.shared
        let limit = max(1, settings.breakMinutes) * 60
        isDue = workedSeconds >= limit
        if isDue, !notified, settings.breakNotify {
            notified = true
            notify(minutes: Int(workedSeconds / 60))
        }
    }

    /// 画面右上の通知で知らせる（ダッシュボードを閉じていても届く）
    private func notify(minutes: Int) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let stretch = self.stretch
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "マッスル：そろそろ休憩しましょう"
            content.body = "\(minutes)分続けて作業しています。\(stretch.name) ▸ \(stretch.how)"
            content.sound = .default
            center.add(UNNotificationRequest(identifier: "muscle.break", content: content, trigger: nil))
        }
    }
}
