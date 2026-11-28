import AVFoundation
import Foundation

/// マイクの音から「パンパン」と2回手を叩いたのを見つける。オーディオスレッドから呼ぶ。
///
/// 手拍子は「急に大きくなって、すぐ消える」音。話し声や物音と区別するために、
/// 1. 直前までの環境音より十分大きい音が急に立ち上がり
/// 2. 約0.1秒後にはほぼ消えている
/// ものを1回の手拍子とみなし、それが 0.15〜0.9秒の間隔で2回続いたら反応する。
final class ClapDetector: @unchecked Sendable {
    /// 感度。高いほど小さな手拍子でも反応する（そのぶん物音にも反応しやすい）
    enum Sensitivity: String, CaseIterable, Identifiable {
        case low, medium, high
        var id: String { rawValue }

        var label: String {
            switch self {
            case .low: return "低い（誤作動しにくい）"
            case .medium: return "ふつう"
            case .high: return "高い（小さな音でも反応）"
            }
        }

        /// 環境音の何倍の大きさで立ち上がれば手拍子の候補にするか
        fileprivate var ratio: Float {
            switch self {
            case .low: return 14
            case .medium: return 9
            case .high: return 6
            }
        }

        /// 候補にする最小の大きさ（RMS）
        fileprivate var floor: Float {
            switch self {
            case .low: return 0.06
            case .medium: return 0.035
            case .high: return 0.02
            }
        }
    }

    /// 2回目の手拍子を見つけたら呼ぶ（オーディオスレッドから呼ばれる）
    var onDoubleClap: (() -> Void)?

    private let lock = NSLock()
    private var sensitivity: Sensitivity = .medium

    /// 解析の窓（約5ms）
    private let windowSize = 256
    private var background: Float = 0.005
    private var clock: Double = 0
    /// 候補の手拍子（立ち上がった時刻と大きさ）
    private var candidate: (time: Double, energy: Float)?
    private var lastClap: Double = -10
    private var lastTrigger: Double = -10

    func set(sensitivity: Sensitivity) {
        lock.lock()
        self.sensitivity = sensitivity
        lock.unlock()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        guard rate > 0, frames > 0 else { return }

        lock.lock()
        let level = sensitivity
        lock.unlock()

        var start = 0
        while start < frames {
            let count = min(windowSize, frames - start)
            var sum: Float = 0
            for index in start..<(start + count) {
                let sample = channel[index]
                sum += sample * sample
            }
            let rms = (sum / Float(count)).squareRoot()
            step(rms: rms, now: clock, level: level)
            clock += Double(count) / rate
            start += count
        }
    }

    private func step(rms: Float, now: Double, level: Sensitivity) {
        if let current = candidate {
            let elapsed = now - current.time
            // 立ち上がりから 0.07〜0.16秒の間にまだ大きい音が続いていたら、話し声や物音とみなす
            if elapsed > 0.07, elapsed < 0.16, rms > current.energy * 0.3 {
                candidate = nil
                return
            }
            if elapsed >= 0.16 {
                candidate = nil
                registerClap(at: current.time)
            }
            return
        }

        if rms > level.floor, rms > background * level.ratio {
            candidate = (now, rms)
            return
        }
        // 環境音の大きさをゆっくり追いかける（急な大きい音には引きずられないように上限をつける）
        let target = min(rms, background * 3)
        background = max(0.0005, background * 0.98 + target * 0.02)
    }

    private func registerClap(at time: Double) {
        let gap = time - lastClap
        lastClap = time
        guard gap > 0.15, gap < 0.9, time - lastTrigger > 3 else { return }
        lastTrigger = time
        lastClap = -10
        onDoubleClap?()
    }
}
