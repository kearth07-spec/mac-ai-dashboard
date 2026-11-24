import AVFoundation
import Foundation

/// 話しかけた内容を Claude Code（`claude -p`）に渡し、返ってきた答えを画面に出して読み上げる。
/// Claude の有料プランにログイン済みの Claude Code を使うので、APIキーや追加料金は要らない。
@MainActor
final class VoiceAssistant: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case thinking
        case speaking
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var question = ""
    @Published private(set) var answer = ""

    /// 考え中・読み上げ中は、声や手拍子に反応させない（自分の声を拾わないように）
    var isBusy: Bool { phase == .thinking || phase == .speaking }

    /// 前の質問からこの秒数以内なら、会話の続きとして扱う
    private static let followUpWindow: TimeInterval = 5 * 60
    private static let timeout: TimeInterval = 120

    private static let persona = """
    あなたは音声アシスタント「マッスル」です。答えはそのまま音声で読み上げられます。
    日本語の話し言葉で、まず結論を2〜4文で短く答えてください。
    箇条書き・見出し・記号・Markdown・URL・絵文字は使わないでください。
    調べないとわからないこと（天気・ニュースなど）は、ウェブ検索を使って答えてください。
    """

    private let synthesizer = AVSpeechSynthesizer()
    private var process: Process?
    private var lastAsked = Date.distantPast
    private var generation = 0

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 質問

    func ask(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else {
            question = ""
            answer = "聞き取れませんでした。もう一度話しかけてください。"
            speak("聞き取れませんでした")
            return
        }
        stop()
        generation += 1
        let current = generation
        question = prompt
        answer = ""
        phase = .thinking

        let continues = Date().timeIntervalSince(lastAsked) < Self.followUpWindow
        lastAsked = Date()
        AudioSpectrum.log("assistant: Claude Code に質問（\(prompt.count)文字、続き=\(continues)）")

        run(prompt: prompt, continues: continues) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, current == self.generation else { return }
                self.process = nil
                switch result {
                case .success(let output):
                    self.answer = output
                    self.speak(Self.speakable(output))
                case .failure(let error):
                    AudioSpectrum.log("assistant: 失敗 \(error.message)")
                    self.answer = ""
                    self.phase = .failed(error.message)
                    self.speak(error.spoken)
                }
            }
        }
    }

    /// 考え中・読み上げ中をやめる
    func stop() {
        generation += 1
        if let process, process.isRunning { process.terminate() }
        process = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        if isBusy { phase = .idle }
    }

    // MARK: - 読み上げ

    private func speak(_ text: String) {
        guard !text.isEmpty else {
            if case .failed = phase {} else { phase = .idle }
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.japaneseVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        if case .failed = phase {} else { phase = .speaking }
        synthesizer.speak(utterance)
    }

    /// いちばん質の良い日本語の声（拡張版・プレミアム版が入っていればそちら）
    private static let japaneseVoice: AVSpeechSynthesisVoice? = {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "ja-JP" }
        return voices.max { $0.quality.rawValue < $1.quality.rawValue }
            ?? AVSpeechSynthesisVoice(language: "ja-JP")
    }()

    /// 読み上げにじゃまな記号を落とす
    private static func speakable(_ text: String) -> String {
        var result = text
        for mark in ["**", "__", "`", "#", "＊", "*", "|", ">"] {
            result = result.replacingOccurrences(of: mark, with: "")
        }
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"(?m)^\s*[-・]\s*"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Claude Code の呼び出し

    private struct RunError: Error {
        let message: String
        let spoken: String
    }

    /// Claude Code を作業用フォルダで呼ぶ。会話の続きは --continue で引き継ぐ。
    private func run(prompt: String, continues: Bool,
                     completion: @escaping @Sendable (Result<String, RunError>) -> Void) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muscle/chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var arguments = ["-p", "--append-system-prompt", Self.persona]
        if continues { arguments.append("--continue") }
        // 天気やニュースに答えられるよう、検索だけは確認なしで使ってよいことにする（最後に置く）
        arguments += ["--allowedTools", "WebSearch", "WebFetch"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // ターミナルと同じ PATH で claude を探すため、ログインシェルの設定を読んでから実行する。
        // 引数は "$@" で渡すので、話した内容に記号が入っても壊れない（内容は標準入力で渡す）。
        process.arguments = ["-lc", "source ~/.zshrc >/dev/null 2>&1; exec claude \"$@\"", "muscle"] + arguments
        process.currentDirectoryURL = folder

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // 出力が大きいとパイプが詰まるので、終わるのを待たずに読み続ける
        let collected = OutputBox()
        output.fileHandleForReading.readabilityHandler = { handle in collected.appendOut(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { handle in collected.appendErr(handle.availableData) }

        process.terminationHandler = { finished in
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            collected.appendOut(output.fileHandleForReading.readDataToEndOfFile())
            collected.appendErr(errors.fileHandleForReading.readDataToEndOfFile())
            let text = collected.out.trimmingCharacters(in: .whitespacesAndNewlines)
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                if status == 0, !text.isEmpty {
                    completion(.success(text))
                } else if status == 127 {
                    completion(.failure(RunError(
                        message: "Claude Code が見つかりません。ターミナルで Claude Code をインストールしてください。",
                        spoken: "クロードコードが見つかりませんでした")))
                } else if finished.terminationReason == .uncaughtSignal {
                    completion(.failure(RunError(message: "時間がかかりすぎたので止めました。", spoken: "")))
                } else {
                    let detail = collected.err.trimmingCharacters(in: .whitespacesAndNewlines)
                    let hint = detail.lowercased().contains("login") || detail.lowercased().contains("auth")
                        ? "ターミナルで claude を一度起動して、ログインしてください。"
                        : String(detail.suffix(160))
                    completion(.failure(RunError(message: "答えを取得できませんでした。\(hint)",
                                                 spoken: "答えを取得できませんでした")))
                }
            }
        }

        do {
            try process.run()
        } catch {
            completion(.failure(RunError(message: "Claude Code を起動できませんでした。", spoken: "")))
            return
        }
        self.process = process
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        // 返事が来ないときは打ち切る
        let current = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation, process.isRunning else { return }
                process.terminate()
            }
        }
    }
}

extension VoiceAssistant: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.phase == .speaking { self.phase = .idle }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in
            if self.phase == .speaking { self.phase = .idle }
        }
    }
}

/// 別スレッドから届く出力をためておく
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outData = Data()
    private var errData = Data()

    func appendOut(_ data: Data) {
        lock.lock(); outData.append(data); lock.unlock()
    }

    func appendErr(_ data: Data) {
        lock.lock(); errData.append(data); lock.unlock()
    }

    var out: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: outData, as: UTF8.self)
    }

    var err: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: errData, as: UTF8.self)
    }
}
