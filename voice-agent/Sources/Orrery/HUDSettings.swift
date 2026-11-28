import Combine
import SwiftUI

/// 設定画面（⌘,）で変えられる項目。UserDefaultsに保存する。
/// 同名の環境変数（HUD_CITY など）が指定されているときはそちらが優先される（HUDConfig側で解決）。
@MainActor
final class HUDSettings: ObservableObject {
    static let shared = HUDSettings()

    private let store = UserDefaults.standard

    // MARK: 一般

    /// 空文字は「既定のまま」の意味
    @Published var cityName: String { didSet { store.set(cityName, forKey: "cityName"); bumpData() } }
    @Published var latitude: Double { didSet { store.set(latitude, forKey: "latitude"); bumpData() } }
    @Published var longitude: Double { didSet { store.set(longitude, forKey: "longitude"); bumpData() } }
    /// 1行に「シンボル:表示名」。空なら既定の銘柄
    @Published var tickersText: String { didSet { store.set(tickersText, forKey: "tickers"); bumpData() } }
    /// カンマ区切り。キーはHUDConfigが昔から読んでいる "wakePhrases" を使い続ける
    @Published var wakePhrasesText: String { didSet { store.set(wakePhrasesText, forKey: "wakePhrases") } }
    /// 「パンパン」と2回手を叩いて起動する
    @Published var clapEnabled: Bool { didSet { store.set(clapEnabled, forKey: "clapEnabled") } }
    @Published var clapSensitivity: ClapDetector.Sensitivity {
        didSet { store.set(clapSensitivity.rawValue, forKey: "clapSensitivity") }
    }
    /// 声やボタンで起動するAI
    @Published var agentTarget: AgentTarget { didSet { store.set(agentTarget.rawValue, forKey: "agentTarget") } }
    /// Claude Code を起動するフォルダ。空文字はホーム
    @Published var claudeCodeDirectory: String {
        didSet { store.set(claudeCodeDirectory, forKey: "claudeCodeDirectory") }
    }

    // MARK: テーマ

    @Published var theme: HUDTheme { didSet { store.set(theme.rawValue, forKey: "theme"); applyPalette() } }
    @Published var customAccentHex: String { didSet { store.set(customAccentHex, forKey: "customAccent"); applyPalette() } }

    // MARK: パネルの表示

    @Published var showSystem: Bool { didSet { store.set(showSystem, forKey: "showSystem") } }
    @Published var showNetwork: Bool { didSet { store.set(showNetwork, forKey: "showNetwork") } }
    @Published var showUsage: Bool { didSet { store.set(showUsage, forKey: "showUsage") } }
    @Published var showWeather: Bool { didSet { store.set(showWeather, forKey: "showWeather") } }
    @Published var showMarket: Bool { didSet { store.set(showMarket, forKey: "showMarket") } }
    @Published var showSand: Bool { didSet { store.set(showSand, forKey: "showSand") } }
    @Published var showLesson: Bool { didSet { store.set(showLesson, forKey: "showLesson") } }
    @Published var showBreak: Bool { didSet { store.set(showBreak, forKey: "showBreak") } }
    @Published var showCalendar: Bool { didSet { store.set(showCalendar, forKey: "showCalendar") } }
    @Published var showCommands: Bool { didSet { store.set(showCommands, forKey: "showCommands") } }

    // MARK: アシスタント

    /// 1行に「ボタン名|AIへの指示」。空なら既定
    @Published var quickCommandsText: String { didSet { store.set(quickCommandsText, forKey: "quickCommands") } }
    /// 何分続けて作業したら休憩を促すか
    @Published var breakMinutes: Double { didSet { store.set(breakMinutes, forKey: "breakMinutes") } }
    /// 読み上げの速さ（0.4〜0.7くらい。Apple の標準は0.5）
    @Published var speechRate: Double { didSet { store.set(speechRate, forKey: "speechRate") } }
    /// 「マッスルと会話」で使うモデル（haiku / sonnet / opus）
    @Published var assistantModel: String { didSet { store.set(assistantModel, forKey: "assistantModel") } }
    /// 休憩の時間になったら通知を出すか
    @Published var breakNotify: Bool { didSet { store.set(breakNotify, forKey: "breakNotify") } }

    // MARK: 負荷

    @Published var grainCount: Double { didSet { store.set(Int(grainCount), forKey: "grainCount") } }
    @Published var activeFPS: Double { didSet { store.set(activeFPS, forKey: "activeFPS") } }
    @Published var idleFPS: Double { didSet { store.set(idleFPS, forKey: "idleFPS") } }

    /// 天気・株価の再取得が必要な変更があったことを知らせる印
    @Published private(set) var dataStamp = UUID()

    /// テキスト入力のたびにAPIを叩かないよう、少し待ってから再取得する
    var dataRefresh: AnyPublisher<UUID, Never> {
        $dataStamp
            .dropFirst()
            .debounce(for: .seconds(1.2), scheduler: RunLoop.main)
            .eraseToAnyPublisher()
    }

    /// テーマやFPSなど、描画ツリーを作り直して反映する設定の指紋
    var rebuildFingerprint: String {
        "\(theme.rawValue)|\(customAccentHex)|\(activeFPS)|\(idleFPS)"
    }

    var customAccent: Color {
        get { Color(hexString: customAccentHex) ?? Color(red: 0.36, green: 0.86, blue: 1.0) }
        set { customAccentHex = newValue.hexString }
    }

    private init() {
        cityName = store.string(forKey: "cityName") ?? ""
        latitude = store.object(forKey: "latitude") as? Double ?? 35.6812
        longitude = store.object(forKey: "longitude") as? Double ?? 139.7671
        tickersText = store.string(forKey: "tickers") ?? ""
        wakePhrasesText = store.string(forKey: "wakePhrases") ?? ""
        agentTarget = AgentTarget(rawValue: store.string(forKey: "agentTarget") ?? "") ?? .voiceChat
        clapEnabled = store.object(forKey: "clapEnabled") as? Bool ?? true
        clapSensitivity = ClapDetector.Sensitivity(rawValue: store.string(forKey: "clapSensitivity") ?? "") ?? .medium
        claudeCodeDirectory = store.string(forKey: "claudeCodeDirectory") ?? ""
        theme = HUDTheme(rawValue: store.string(forKey: "theme") ?? "") ?? .arc
        customAccentHex = store.string(forKey: "customAccent") ?? "#5CDBFF"
        showSystem = store.object(forKey: "showSystem") as? Bool ?? true
        showNetwork = store.object(forKey: "showNetwork") as? Bool ?? false
        showUsage = store.object(forKey: "showUsage") as? Bool ?? true
        showWeather = store.object(forKey: "showWeather") as? Bool ?? true
        showMarket = store.object(forKey: "showMarket") as? Bool ?? false
        showSand = store.object(forKey: "showSand") as? Bool ?? true
        showLesson = store.object(forKey: "showLesson") as? Bool ?? true
        showBreak = store.object(forKey: "showBreak") as? Bool ?? true
        showCalendar = store.object(forKey: "showCalendar") as? Bool ?? true
        showCommands = store.object(forKey: "showCommands") as? Bool ?? true
        quickCommandsText = store.string(forKey: "quickCommands") ?? ""
        breakMinutes = store.object(forKey: "breakMinutes") as? Double ?? 50
        breakNotify = store.object(forKey: "breakNotify") as? Bool ?? true
        speechRate = store.object(forKey: "speechRate") as? Double ?? 0.58
        assistantModel = store.string(forKey: "assistantModel") ?? "haiku"
        // 「最速に」の指定に合わせて、以前の既定（sonnet）から一度だけ haiku に切り替える
        if !store.bool(forKey: "assistantModelFastest") {
            store.set(true, forKey: "assistantModelFastest")
            assistantModel = "haiku"
        }
        grainCount = Double(store.object(forKey: "grainCount") as? Int ?? 1100)
        activeFPS = store.object(forKey: "activeFPS") as? Double ?? 30
        idleFPS = store.object(forKey: "idleFPS") as? Double ?? 12
        applyPalette()
    }

    func applyPalette() {
        HUD.palette = theme.palette(customAccent: customAccent)
    }

    func resetAll() {
        cityName = ""
        latitude = 35.6812
        longitude = 139.7671
        tickersText = ""
        wakePhrasesText = ""
        agentTarget = .voiceChat
        clapEnabled = true
        clapSensitivity = .medium
        claudeCodeDirectory = ""
        theme = .arc
        customAccentHex = "#5CDBFF"
        showSystem = true
        showNetwork = false
        showUsage = true
        showWeather = true
        showMarket = false
        showSand = true
        showLesson = true
        showBreak = true
        showCalendar = true
        showCommands = true
        quickCommandsText = ""
        breakMinutes = 50
        breakNotify = true
        speechRate = 0.58
        assistantModel = "haiku"
        grainCount = 1100
        activeFPS = 30
        idleFPS = 12
    }

    private func bumpData() {
        dataStamp = UUID()
    }
}
