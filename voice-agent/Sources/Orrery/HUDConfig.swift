import Foundation

struct Ticker: Identifiable, Hashable {
    let symbol: String
    let label: String
    var id: String { symbol }
}

/// 「よく使う指示」パネルのボタン1つぶん
struct QuickCommand: Identifiable, Hashable {
    let id: Int
    let label: String
    let prompt: String
}

/// 表示内容の設定。優先順は 環境変数 > 設定画面（UserDefaults） > 既定値。
enum HUDConfig {
    /// 天気を出す地点（既定は東京）
    static var cityName: String { value(for: "HUD_CITY") ?? stored("cityName") ?? "TOKYO" }
    static var latitude: Double {
        value(for: "HUD_LAT").flatMap(Double.init) ?? storedDouble("latitude") ?? 35.6812
    }
    static var longitude: Double {
        value(for: "HUD_LON").flatMap(Double.init) ?? storedDouble("longitude") ?? 139.7671
    }

    /// 株価・為替の銘柄（Yahoo Financeのシンボル）
    static let defaultTickers: [Ticker] = [
        Ticker(symbol: "^N225", label: "NIKKEI 225"),
        Ticker(symbol: "USDJPY=X", label: "USD / JPY"),
        Ticker(symbol: "^GSPC", label: "S&P 500"),
        Ticker(symbol: "NVDA", label: "NVIDIA"),
        Ticker(symbol: "AAPL", label: "APPLE"),
        Ticker(symbol: "BTC-USD", label: "BITCOIN")
    ]

    /// 「シンボル:表示名」を改行かカンマで並べる。表示名を省くとシンボルがそのまま出る。
    /// 例: HUD_TICKERS="^N225:NIKKEI 225,BTC-USD:BITCOIN"
    static var tickers: [Ticker] {
        guard let raw = value(for: "HUD_TICKERS") ?? stored("tickers") else { return defaultTickers }
        let parsed = raw
            .split(whereSeparator: { $0 == "\n" || $0 == "," })
            .compactMap { entry -> Ticker? in
                let parts = entry.split(separator: ":", maxSplits: 1)
                guard let symbol = parts.first?.trimmingCharacters(in: .whitespaces),
                      !symbol.isEmpty else { return nil }
                let label = parts.count > 1
                    ? parts[1].trimmingCharacters(in: .whitespaces) : symbol
                return Ticker(symbol: symbol, label: label.isEmpty ? symbol : label)
            }
        return parsed.isEmpty ? defaultTickers : parsed
    }

    /// 声やボタンで起動するAI。HUD_AGENT=claude / claude-code / codex か設定画面で選ぶ。
    static var agentTarget: AgentTarget {
        if let raw = value(for: "HUD_AGENT"), let target = AgentTarget(loose: raw) { return target }
        if let raw = stored("agentTarget"), let target = AgentTarget(rawValue: raw) { return target }
        return .voiceChat
    }

    /// Claude Code を起動するフォルダ。HUD_CLAUDE_CODE_DIR か設定画面で変えられる（既定はホーム）。
    static var claudeCodeDirectory: String {
        let raw = value(for: "HUD_CLAUDE_CODE_DIR") ?? stored("claudeCodeDirectory") ?? "~"
        return (raw as NSString).expandingTildeInPath
    }

    /// 音を拾う対象アプリ。アプリ名かバンドルIDに含まれる文字列で指定する。
    /// 既定は起動するAIに合わせる（Claude系なら claude、Codexなら codex）。
    /// 例: HUD_AUDIO_APPS="codex,chatgpt,terminal"
    static var audioAppKeywords: [String] {
        (value(for: "HUD_AUDIO_APPS") ?? agentTarget.audioKeyword)
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    /// 音声で起動するときの合図。認識のゆらぎを拾うため語幹で持つ。
    /// 合図に続けて話した内容は、Claude系ならそのまま指示として渡す（例:「オレリー、明日の予定をまとめて」）。
    /// 設定画面か HUD_WAKE_PHRASES="オレリ,クロード" で変えられる。
    static var wakePhrases: [String] {
        let raw = value(for: "HUD_WAKE_PHRASES")
            ?? stored("wakePhrases")
            ?? "マッスル,マッスー,muscle"
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 「よく使う指示」の既定。1行に「ボタン名|AIへの指示」
    static let defaultQuickCommandsText = """
    今日の段取り|今日やることを整理して、優先順位と時間割を提案してください。
    Instagram投稿案|理学療法士・医療従事者向けのInstagram投稿ネタを5つ提案してください。それぞれ1枚目のタイトル案もつけてください。
    note記事ネタ|医療介護職向けの有料note記事のテーマ案を5つ、想定読者と一緒に提案してください。
    研修資料の骨子|新人〜中堅の理学療法士向け研修会の資料の骨子を作ってください。テーマはこれから伝えます。
    Macの小ワザ|Mac初心者がすぐ使える便利な小ワザを1つ、手順つきで教えてください。
    文章を整える|これから貼り付ける文章を、読みやすく自然な日本語に整えてください。
    """

    /// 「よく使う指示」のボタン。設定画面で書き換えられる。
    static var quickCommands: [QuickCommand] {
        let raw: String = stored("quickCommands") ?? defaultQuickCommandsText
        var commands: [QuickCommand] = []
        for piece in raw.split(separator: "\n") {
            let line: String = piece.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts: [String] = line.split(separator: "|", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let prompt: String = parts.count > 1 ? parts[1] : parts[0]
            let label: String = parts.count > 1 ? parts[0] : String(prompt.prefix(14))
            commands.append(QuickCommand(id: commands.count, label: label, prompt: prompt))
        }
        return commands
    }

    /// 一致しても起動せずログだけ出す（合図の調整用）
    static var wakeDryRun: Bool { UserDefaults.standard.bool(forKey: "wakeDryRun") }

    /// 「マッスルと会話」で Claude Code に使わせるモデル（sonnet / opus / haiku など）
    static var assistantModel: String {
        value(for: "HUD_ASSISTANT_MODEL") ?? stored("assistantModel") ?? "sonnet"
    }

    static var wakePhraseLocale: String { value(for: "HUD_WAKE_LOCALE") ?? "ja-JP" }

    /// 粒子の数。負荷が高いときに減らせる（0で粒子を描かない）
    static var grainCount: Int {
        value(for: "HUD_GRAINS").flatMap(Int.init) ?? storedInt("grainCount") ?? 1100
    }

    /// 画面の更新頻度。全画面を描き直すので、待機中は落として負荷を下げる。
    static var activeFrameRate: Double {
        value(for: "HUD_FPS").flatMap(Double.init) ?? storedDouble("activeFPS") ?? 30
    }
    static var idleFrameRate: Double {
        value(for: "HUD_IDLE_FPS").flatMap(Double.init) ?? storedDouble("idleFPS") ?? 12
    }

    /// 切り分け用: 1にすると動く描画を止める
    static var isStatic: Bool { value(for: "HUD_STATIC") == "1" }

    static func frameInterval(isLive: Bool) -> Double {
        1 / max(1, isLive ? activeFrameRate : idleFrameRate)
    }

    /// 待機中に何回に1回描くか
    static func frameDivisor(isLive: Bool) -> Int {
        isLive ? 1 : max(1, Int((activeFrameRate / max(1, idleFrameRate)).rounded()))
    }

    static let systemInterval: TimeInterval = 1
    static let weatherInterval: TimeInterval = 600
    static let marketInterval: TimeInterval = 60
    static let usageInterval: TimeInterval = 300
    /// 対象アプリが起動・終了していないか見張る間隔
    static let audioSourceInterval: TimeInterval = 6

    private static func value(for key: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[key], !raw.isEmpty else { return nil }
        return raw
    }

    /// 設定画面が保存した値。空文字は「既定のまま」とみなす。
    private static func stored(_ key: String) -> String? {
        guard let raw = UserDefaults.standard.string(forKey: key), !raw.isEmpty else { return nil }
        return raw
    }

    private static func storedDouble(_ key: String) -> Double? {
        UserDefaults.standard.object(forKey: key) as? Double
    }

    private static func storedInt(_ key: String) -> Int? {
        UserDefaults.standard.object(forKey: key) as? Int
    }
}
