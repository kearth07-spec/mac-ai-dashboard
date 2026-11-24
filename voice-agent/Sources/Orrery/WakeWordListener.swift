import AVFoundation
import Combine
import Speech
import SwiftUI

/// 決めた言葉を聞き取ったらセッションを開く。認識は端末内だけで行い、音声は保存も送信もしない。
@MainActor
final class WakeWordListener: ObservableObject {
    @Published private(set) var isListening = false
    /// 直近に聞き取れた文（うまく反応しないときの手がかり用）
    @Published private(set) var heard = ""
    @Published private(set) var message: String?
    @Published var enabled = false {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: Self.preferenceKey)
            enabled ? start() : stop()
        }
    }

    /// 合図のあとの指示を聞き取っている最中か
    @Published private(set) var isCapturing = false

    /// 呼び出し側でAIの起動につなぐ。引数は合図のあとに話した内容（無ければ空文字）
    var onTrigger: ((String) -> Void)?
    /// セッション中は反応させない（Codexの声で自分が誤爆しないように）
    var isSuppressed: () -> Bool = { false }

    private static let preferenceKey = "wakeWordEnabled"
    private static let cooldown: TimeInterval = 6
    /// 指示を話し終えたとみなす無音の長さ
    private static let commandSilence: TimeInterval = 1.6
    /// 合図だけ言って黙っているとき、指示を待つ長さ
    private static let commandWait: TimeInterval = 5
    /// 指示を聞き取る最大の長さ
    private static let commandLimit: TimeInterval = 20

    private let engine = AVAudioEngine()
    private let box = RequestBox()
    private let recognizer: SFSpeechRecognizer?
    private var task: SFSpeechRecognitionTask?
    private var restartTimer: Timer?
    private var lastTrigger = Date.distantPast
    /// キャンセルした古いタスクのコールバックを無視するための世代番号
    private var generation = 0
    private var tapInstalled = false
    /// 指示の聞き取り
    private var command = ""
    private var captureStarted = Date.distantPast
    private var captureTimer: Timer?
    /// 手拍子で始めた聞き取り（合図の言葉が無いので、聞き取った文がまるごと指示になる）
    private var captureWhole = false
    private let clap = ClapDetector()
    private var cancellables: Set<AnyCancellable> = []

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: HUDConfig.wakePhraseLocale))
        clap.onDoubleClap = { [weak self] in
            Task { @MainActor in self?.handleClap() }
        }
        HUDSettings.shared.$clapSensitivity
            .sink { [clap] level in clap.set(sensitivity: level) }
            .store(in: &cancellables)
        enabled = UserDefaults.standard.bool(forKey: Self.preferenceKey)
        if enabled { start() }
    }

    // MARK: - 開始と停止

    private func start() {
        // 素の実行ファイルだと用途説明を読めず、許可を求めた瞬間にOSがプロセスを落とす
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            message = "音声起動は Orrery.app から起動したときだけ使えます（ORRERYを起動.command を実行してください）"
            enabled = false
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            message = "この端末では音声認識が使えません"
            enabled = false
            return
        }

        // 許可のコールバックは任意のスレッドで来るので、必ずメインへ渡す
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard status == .authorized else {
                    self.message = "音声認識が許可されていません（システム設定 › プライバシーとセキュリティ › 音声認識）"
                    self.enabled = false
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard granted else {
                            self.message = "マイクが許可されていません（システム設定 › プライバシーとセキュリティ › マイク）"
                            self.enabled = false
                            return
                        }
                        self.beginListening()
                    }
                }
            }
        }
    }

    private func beginListening() {
        guard !isListening else { return }
        do {
            if !tapInstalled {
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0 else {
                    message = "マイクが見つかりません"
                    enabled = false
                    return
                }
                AudioSpectrum.log("wake: input format \(format.sampleRate)Hz \(format.channelCount)ch")
                box.prepare(from: format)
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { [box, clap] buffer, _ in
                    box.append(buffer)
                    clap.process(buffer)
                }
                tapInstalled = true
            }
            engine.prepare()
            try engine.start()
        } catch {
            message = "マイクを開けませんでした"
            enabled = false
            return
        }

        isListening = true
        message = nil
        AudioSpectrum.log("wake: engine started, onDevice=\(recognizer?.supportsOnDeviceRecognition ?? false)")
        restartTask()

        // 認識タスクには時間の上限があるので、定期的に貼り替える
        let timer = Timer(timeInterval: 50, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.isCapturing { self.finishCapture() } else { self.restartTask() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        restartTimer = timer
    }

    private func stop() {
        cancelCapture()
        restartTimer?.invalidate()
        restartTimer = nil
        task?.cancel()
        task = nil
        box.finish()
        if engine.isRunning { engine.stop() }
        isListening = false
        heard = ""
    }

    // MARK: - 認識

    private func restartTask() {
        guard isListening, let recognizer else { return }
        generation += 1
        let current = generation
        task?.cancel()
        task = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        box.set(request)

        task = recognizer.recognitionTask(with: request) { result, error in
            Task { @MainActor [weak self] in
                // 古い世代のタスクからの通知は捨てる（これが無いと再起動が連鎖して暴走する）
                guard let self, current == self.generation else { return }
                if let result {
                    // 聞き取った内容はログに残さない（画面に一時表示するだけ）
                    self.consider(result.bestTranscription.formattedString)
                    if result.isFinal {
                        if self.isCapturing { self.finishCapture() } else { self.restartTask() }
                    }
                } else if error != nil {
                    if self.isCapturing {
                        self.finishCapture()
                        return
                    }
                    // 無音が続くと終了するので、間を置いてから貼り替える
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard current == self.generation else { return }
                    self.restartTask()
                }
            }
        }
    }

    private func consider(_ transcript: String) {
        if isCapturing {
            updateCapture(transcript)
            return
        }
        heard = String(transcript.suffix(40))
        guard !isSuppressed(),
              Date().timeIntervalSince(lastTrigger) > Self.cooldown else { return }

        guard Self.textAfterWakePhrase(in: transcript) != nil else { return }

        AudioSpectrum.log("wake: 合図に一致しました")
        lastTrigger = Date()

        // Codexは向こうの音声ライブで話すので、合図だけで起動する
        guard HUDConfig.agentTarget.acceptsSpokenCommand else {
            heard = ""
            restartTask()
            guard !HUDConfig.wakeDryRun else { return }
            onTrigger?("")
            return
        }

        // Claude系は合図に続けて話した内容を指示として受け取る。
        // 同じ認識タスクを使い続け、話し終わる（無音が続く）のを待つ。
        isCapturing = true
        captureStarted = Date()
        updateCapture(transcript)
    }

    // MARK: - 手拍子

    /// 「パンパン」と2回叩いたとき。合図の言葉を言ったのと同じ扱いにする。
    private func handleClap() {
        guard HUDSettings.shared.clapEnabled, isListening, !isCapturing, !isSuppressed(),
              Date().timeIntervalSince(lastTrigger) > Self.cooldown else { return }
        AudioSpectrum.log("wake: 手拍子を検出しました")
        lastTrigger = Date()

        guard HUDConfig.agentTarget.acceptsSpokenCommand else {
            restartTask()
            guard !HUDConfig.wakeDryRun else { return }
            onTrigger?("")
            return
        }

        // 手拍子のあとに話した内容を指示として受け取る。認識を貼り替えて、ここから先だけを聞く。
        isCapturing = true
        captureWhole = true
        captureStarted = Date()
        command = ""
        restartTask()
        heard = "▶ 指示をどうぞ…"
        scheduleCaptureEnd()
    }

    // MARK: - 指示の聞き取り

    private func updateCapture(_ transcript: String) {
        if captureWhole {
            command = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let rest = Self.textAfterWakePhrase(in: transcript) {
            command = rest
        }
        heard = command.isEmpty ? "▶ 指示をどうぞ…" : "▶ \(command.suffix(38))"
        scheduleCaptureEnd()
    }

    private func scheduleCaptureEnd() {
        captureTimer?.invalidate()
        let elapsed = Date().timeIntervalSince(captureStarted)
        let wait: TimeInterval
        if elapsed >= Self.commandLimit {
            wait = 0
        } else if command.isEmpty {
            wait = max(Self.commandSilence, Self.commandWait - elapsed)
        } else {
            wait = Self.commandSilence
        }
        let timer = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishCapture() }
        }
        RunLoop.main.add(timer, forMode: .common)
        captureTimer = timer
    }

    private func finishCapture() {
        guard isCapturing else { return }
        let spoken = command
        cancelCapture()
        heard = ""
        lastTrigger = Date()
        restartTask()
        AudioSpectrum.log("wake: 指示の聞き取りを終えました（\(spoken.count)文字）")
        guard !HUDConfig.wakeDryRun else { return }
        onTrigger?(spoken)
    }

    private func cancelCapture() {
        captureTimer?.invalidate()
        captureTimer = nil
        isCapturing = false
        captureWhole = false
        command = ""
    }

    /// 文の中に合図があれば、その後ろの部分（指示）を返す。合図が無ければ nil。
    /// 比較は flatten した文字で行い、切り出しは元の文から行う（指示の表記を崩さないため）。
    private static func textAfterWakePhrase(in transcript: String) -> String? {
        // 元の文の各文字が flatten 後のどこまでに当たるかを記録しておく
        var flat: [Character] = []
        var ends: [String.Index] = []   // flat[i] の直後に当たる元の文の位置
        var index = transcript.startIndex
        while index < transcript.endIndex {
            let next = transcript.index(after: index)
            for character in flatten(String(transcript[index..<next])) {
                flat.append(character)
                ends.append(next)
            }
            index = next
        }

        // いちばん手前で終わる合図を採用する（指示の中に「クロード」などの語が出てきても切れないように）
        var best: Int?
        for phrase in HUDConfig.wakePhrases {
            let needle = Array(flatten(phrase))
            guard !needle.isEmpty, needle.count <= flat.count else { continue }
            for start in 0...(flat.count - needle.count) where Array(flat[start..<start + needle.count]) == needle {
                let end = start + needle.count - 1
                if best == nil || end < best! { best = end }
                break
            }
        }
        guard let best else { return nil }

        // 合図の直後の伸ばし棒や読点（「オレリー、」の「ー、」）だけを落とす
        let leading = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(CharacterSet(charactersIn: "ーｰ〜~、。，．・!！?？"))
        let rest = transcript[ends[best]...]
            .drop { $0.unicodeScalars.allSatisfy { leading.contains($0) } }
        return String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 空白・記号・全角半角・ひらがなカタカナの違いを吸収して比べる
    private static func flatten(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
                                  locale: Locale(identifier: "ja_JP"))
        let kana = folded.applyingTransform(.hiraganaToKatakana, reverse: false) ?? folded
        return kana.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .reduce(into: "") { $0.append(Character($1)) }
    }
}

/// オーディオスレッドと認識リクエストの受け渡し。
/// 認識器は16kHzモノラルを期待するので、入力形式が違えばここで変換する。
private final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var converter: AVAudioConverter?
    private var appended = 0

    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16_000, channels: 1, interleaved: false)!

    func prepare(from format: AVAudioFormat) {
        lock.lock()
        converter = format == target ? nil : AVAudioConverter(from: format, to: target)
        lock.unlock()
        AudioSpectrum.log("wake: converter=\(format == target ? "不要" : "作成")")
    }

    func set(_ newRequest: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        request?.endAudio()
        request = newRequest
        converter?.reset()
        lock.unlock()
    }

    func finish() {
        set(nil)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = request
        let converter = self.converter
        appended += 1
        let count = appended
        lock.unlock()

        guard let current else { return }
        _ = count

        guard let converter else {
            current.append(buffer)
            return
        }
        guard let converted = Self.convert(buffer, with: converter, to: target) else { return }
        current.append(converted)
    }

    private static func convert(_ buffer: AVAudioPCMBuffer,
                                with converter: AVAudioConverter,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }
}
