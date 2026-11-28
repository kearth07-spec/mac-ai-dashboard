import AppKit
import AVFoundation
import Foundation

/// 話しかけた内容を Claude Code に渡し、返ってきた答えを画面に出して読み上げる。
/// Claude の有料プランにログイン済みの Claude Code を使うので、APIキーや追加料金は要らない。
///
/// 速さのための工夫:
/// - Claude Code を1回だけ起動して開いたままにし（--input-format stream-json）、質問ごとの起動待ちをなくす
/// - 答えを1文字ずつ受け取り（--include-partial-messages）、1文できるたびにすぐ読み上げ始める
/// - claude の場所はアプリ起動時に1度だけ調べておく
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

    /// 最後の質問からこれだけ空いたら、新しい会話として始め直す
    private static let freshConversationAfter: TimeInterval = 10 * 60
    /// 返事が始まらないときに打ち切る秒数
    private static let timeout: TimeInterval = 90

    private static let persona = """
    あなたは音声アシスタント「マッスル」です。答えはそのまま音声で読み上げられます。
    日本語の話し言葉で、まず結論を1〜3文で短く答えてください。前置きやあいさつは不要です。
    箇条書き・見出し・記号・Markdown・URL・絵文字は使わないでください。
    調べないとわからないこと（天気・ニュースなど）だけ、ウェブ検索を使ってください。
    """

    private let synthesizer = AVSpeechSynthesizer()
    private var session: ClaudeSession?
    private var lastAsked = Date.distantPast

    /// 送った質問の数と、答え終わった数。いま流れてきている答えが何番目の質問のものかを知るのに使う
    private var sentTurns = 0
    private var finishedTurns = 0
    /// 画面と読み上げに出す質問の番号（止めたら0にして、残りの答えは捨てる）
    private var activeTurn = 0
    /// まだ読み上げていない、文の途中までの答え
    private var pendingSpeech = ""
    private var spokeAnything = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// アプリ起動時に呼ぶ。claude の場所を調べ、会話の準備をしておく（最初の質問が速くなる）
    func warmUp() {
        ClaudeLocator.shared.resolve { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, HUDConfig.agentTarget == .voiceChat else { return }
                _ = self.ensureSession()
            }
        }
    }

    // MARK: - 質問

    func ask(_ text: String) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        stopSpeaking()
        guard !prompt.isEmpty else {
            question = ""
            answer = "聞き取れませんでした。もう一度話しかけてください。"
            phase = .idle
            speak("聞き取れませんでした")
            return
        }

        // しばらく話していなければ、新しい会話にする（前の話題を引きずらないように）。
        // 起動時に用意しただけでまだ使っていない会話は、そのまま使う
        if sentTurns > 0, Date().timeIntervalSince(lastAsked) > Self.freshConversationAfter {
            restartSession()
        }
        lastAsked = Date()

        question = prompt
        answer = ""
        pendingSpeech = ""
        spokeAnything = false
        phase = .thinking

        guard let session = ensureSession() else { return }
        submit(prompt, to: session)
    }

    private func submit(_ prompt: String, to session: ClaudeSession) {
        sentTurns += 1
        activeTurn = sentTurns
        AudioSpectrum.log("assistant: 質問を送りました（\(prompt.count)文字）")
        session.send(prompt)

        let turn = activeTurn
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activeTurn == turn, self.phase == .thinking else { return }
                // 返事が来ないので、会話を作り直す
                self.restartSession()
                self.fail("時間がかかりすぎたので止めました。もう一度話しかけてください。", spoken: "")
            }
        }
    }

    /// 考え中・読み上げ中をやめる（残りの答えは捨てる）
    func stop() {
        activeTurn = 0
        pendingSpeech = ""
        stopSpeaking()
        if isBusy { phase = .idle }
    }

    // MARK: - Claude Code の会話

    private func ensureSession() -> ClaudeSession? {
        if let session, session.isRunning { return session }
        guard let location = ClaudeLocator.shared.cached else {
            // まだ場所を調べていなければ、調べてからもう一度
            ClaudeLocator.shared.resolve { [weak self] found in
                MainActor.assumeIsolated {
                    guard let self, self.phase == .thinking else { return }
                    if found == nil {
                        self.fail("Claude Code が見つかりません。ターミナルで Claude Code をインストールしてください。",
                                  spoken: "クロードコードが見つかりませんでした")
                    } else if let session = self.ensureSession() {
                        self.submit(self.question, to: session)
                    }
                }
            }
            return nil
        }
        let newSession = ClaudeSession(location: location, persona: Self.persona, model: HUDConfig.assistantModel)
        newSession.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        do {
            try newSession.start()
        } catch {
            fail("Claude Code を起動できませんでした。", spoken: "")
            return nil
        }
        // 古い会話の続きが流れてこないよう、数え直す
        sentTurns = 0
        finishedTurns = 0
        session = newSession
        return newSession
    }

    private func restartSession() {
        session?.stop()
        session = nil
    }

    private func handle(_ event: ClaudeSession.Event) {
        // いま流れてきている答えが、最新の（止めていない）質問のものか
        let current = finishedTurns + 1 == activeTurn
        switch event {
        case .text(let chunk):
            guard current else { return }
            answer += chunk
            pendingSpeech += chunk
            speakCompleteSentences()
        case .finished(let fullText, let isError):
            finishedTurns += 1
            guard current else { return }
            if answer.isEmpty, !fullText.isEmpty, !isError {
                // 途中経過が来なかったときは、まとめて受け取った答えを使う
                answer = fullText
                pendingSpeech = fullText
            }
            if isError, answer.isEmpty {
                fail("答えを取得できませんでした。\(fullText.suffix(120))", spoken: "答えを取得できませんでした")
                return
            }
            flushSpeech()
            if !synthesizer.isSpeaking, phase != .speaking { phase = .idle }
        case .exited(let detail):
            session = nil
            guard phase == .thinking, activeTurn != 0 else { return }
            let lowered = detail.lowercased()
            let needsLogin: Bool = lowered.contains("login") || lowered.contains("auth")
            let message: String = needsLogin
                ? "Claude Code にログインしていません。ターミナルで claude を一度起動して、ログインしてください。"
                : "Claude Code が止まりました。もう一度話しかけてください。\(detail.suffix(120))"
            fail(message, spoken: "答えを取得できませんでした")
        }
    }

    private func fail(_ message: String, spoken: String) {
        AudioSpectrum.log("assistant: 失敗 \(message)")
        activeTurn = 0
        phase = .failed(message)
        if !spoken.isEmpty { speak(spoken) }
    }

    // MARK: - 読み上げ

    /// 文の終わり（。！？や改行）まで来た部分から、順に読み上げる
    private func speakCompleteSentences() {
        let enders: Set<Character> = ["。", "！", "？", "!", "?", "\n"]
        guard let last = pendingSpeech.lastIndex(where: { enders.contains($0) }) else { return }
        let ready = String(pendingSpeech[...last])
        pendingSpeech = String(pendingSpeech[pendingSpeech.index(after: last)...])
        speak(Self.speakable(ready))
    }

    private func flushSpeech() {
        let rest = Self.speakable(pendingSpeech)
        pendingSpeech = ""
        if !rest.isEmpty { speak(rest) }
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.japaneseVoice
        utterance.rate = Float(HUDSettings.shared.speechRate)
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        if case .failed = phase {} else { phase = .speaking }
        spokeAnything = true
        synthesizer.speak(utterance)
    }

    private func stopSpeaking() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
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

    fileprivate func speechEnded() {
        // 答えをまだ受け取っている途中なら「考え中」に戻し、全部読み終えたら待機に戻る
        guard phase == .speaking, !synthesizer.isSpeaking else { return }
        let stillAnswering = activeTurn != 0 && finishedTurns < activeTurn
        phase = stillAnswering ? .thinking : .idle
    }
}

extension VoiceAssistant: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechEnded() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.speechEnded() }
    }
}

// MARK: - claude の場所

/// ターミナルと同じ設定で claude の場所と PATH を1度だけ調べて覚えておく。
/// メインスレッドだけで使う（調べる処理だけ裏で行う）。
struct ClaudeLocation: Sendable {
    let executable: String
    let path: String
}

@MainActor
final class ClaudeLocator {
    static let shared = ClaudeLocator()

    private(set) var cached: ClaudeLocation?
    private var resolving = false
    private var waiters: [(ClaudeLocation?) -> Void] = []

    /// completion はメインスレッドで呼ぶ
    func resolve(_ completion: @escaping (ClaudeLocation?) -> Void) {
        if let cached {
            completion(cached)
            return
        }
        waiters.append(completion)
        guard !resolving else { return }
        resolving = true

        DispatchQueue.global(qos: .userInitiated).async {
            let found = ClaudeLocator.lookUp()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ClaudeLocator.shared.finish(found)
                }
            }
        }
    }

    private func finish(_ found: ClaudeLocation?) {
        cached = found
        resolving = false
        let pending = waiters
        waiters = []
        for waiter in pending { waiter(found) }
    }

    nonisolated static func lookUp() -> ClaudeLocation? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "source ~/.zshrc >/dev/null 2>&1; command -v claude; printf '%s' \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
        guard lines.count >= 2, lines[0].hasPrefix("/") else {
            // よくある場所を直接探す
            let home = NSHomeDirectory()
            let candidates = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude",
                              "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            guard let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                return nil
            }
            let path = "\((hit as NSString).deletingLastPathComponent):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            return ClaudeLocation(executable: hit, path: path)
        }
        return ClaudeLocation(executable: lines[0], path: lines[lines.count - 1])
    }
}

// MARK: - 開いたままの Claude Code

/// `claude -p --input-format stream-json` を開いたままにして、質問を1行ずつ送る。
/// 答えは JSON の行で1文字ずつ流れてくる。
final class ClaudeSession: @unchecked Sendable {
    enum Event {
        case text(String)
        case finished(String, Bool)
        case exited(String)
    }

    /// メインスレッドで呼ぶ
    var onEvent: ((Event) -> Void)?

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorText = ""

    var isRunning: Bool { process.isRunning }

    init(location: ClaudeLocation, persona: String, model: String) {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Muscle/chat", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        process.executableURL = URL(fileURLWithPath: location.executable)
        process.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            // 声のやりとりでは長く考えさせず、すぐ答え始めさせる
            "--effort", "low",
            "--append-system-prompt", persona,
            // 登録済みの外部連携（MCP）は読み込まない。起動が速くなり、勝手に外部へ触れない
            "--strict-mcp-config",
            // 使える道具は検索だけにする（ファイル操作やコマンド実行はさせない）
            "--tools", "WebSearch,WebFetch",
            "--no-session-persistence",
            "--allowedTools", "WebSearch", "WebFetch"
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = location.path
        process.environment = environment
        process.currentDirectoryURL = folder
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consume(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let text = String(decoding: handle.availableData, as: UTF8.self)
            self.lock.lock()
            self.errorText = String((self.errorText + text).suffix(2000))
            self.lock.unlock()
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.output.fileHandleForReading.readabilityHandler = nil
            self.errors.fileHandleForReading.readabilityHandler = nil
            self.lock.lock()
            let detail = self.errorText
            self.lock.unlock()
            DispatchQueue.main.async { self.onEvent?(.exited(detail)) }
        }
        try process.run()
    }

    func send(_ text: String) {
        let message: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": [["type": "text", "text": text]]]
        ]
        guard process.isRunning,
              var line = try? JSONSerialization.data(withJSONObject: message) else { return }
        line.append(0x0A)
        input.fileHandleForWriting.write(line)
    }

    func stop() {
        onEvent = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    /// 届いたデータを行に分け、1行ずつ JSON として読む
    private func consume(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()

        let events: [Event] = lines.compactMap { ClaudeSession.parse($0) }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            events.forEach { self.onEvent?($0) }
        }
    }

    private static func parse(_ line: Data) -> Event? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "stream_event":
            // 答えの文字が少しずつ届く（考え中の思考や道具の呼び出しは無視する）
            guard let event = object["event"] as? [String: Any],
                  event["type"] as? String == "content_block_delta",
                  let delta = event["delta"] as? [String: Any],
                  delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String else { return nil }
            return .text(text)
        case "result":
            let text = object["result"] as? String ?? ""
            let isError = object["is_error"] as? Bool ?? false
            return .finished(text, isError)
        default:
            return nil
        }
    }
}
