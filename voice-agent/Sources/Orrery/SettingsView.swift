import AppKit
import SwiftUI

/// ⌘, で開く設定画面。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("一般", systemImage: "gearshape") }
            ThemeTab()
                .tabItem { Label("テーマ", systemImage: "paintpalette") }
            PanelsTab()
                .tabItem { Label("パネル", systemImage: "rectangle.3.group") }
            PerformanceTab()
                .tabItem { Label("負荷", systemImage: "gauge.with.dots.needle.50percent") }
        }
        .frame(width: 500)
    }
}

/// 同名の環境変数が指定されているときは、設定より環境変数が優先されることを知らせる
private struct EnvOverrideNote: View {
    let keys: [String]

    private var active: [String] {
        keys.filter { ProcessInfo.processInfo.environment[$0]?.isEmpty == false }
    }

    var body: some View {
        if !active.isEmpty {
            Label("環境変数 \(active.joined(separator: ", ")) が指定されているため、そちらが優先されます",
                  systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct GeneralTab: View {
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        Form {
            Section("起動するAI") {
                Picker("声・ボタンで起動", selection: $settings.agentTarget) {
                    ForEach(AgentTarget.allCases) { target in
                        Text(target.label).tag(target)
                    }
                }
                .pickerStyle(.radioGroup)
                Text(agentDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if settings.agentTarget == .claudeCode {
                    HStack {
                        TextField("作業フォルダ", text: $settings.claudeCodeDirectory, prompt: Text("~（ホーム）"))
                        Button("選ぶ…") { chooseFolder() }
                    }
                    EnvOverrideNote(keys: ["HUD_CLAUDE_CODE_DIR"])
                }
                EnvOverrideNote(keys: ["HUD_AGENT"])
            }

            Section("天気") {
                TextField("地名（表示用）", text: $settings.cityName, prompt: Text("TOKYO"))
                TextField("緯度", value: $settings.latitude,
                          format: .number.precision(.fractionLength(0...6)))
                TextField("経度", value: $settings.longitude,
                          format: .number.precision(.fractionLength(0...6)))
                EnvOverrideNote(keys: ["HUD_CITY", "HUD_LAT", "HUD_LON"])
            }

            Section("株価・為替") {
                TextEditor(text: $settings.tickersText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                Text("1行に「シンボル:表示名」。シンボルはYahoo Financeのもの。空欄なら既定の銘柄。\n例: ^N225:NIKKEI 225")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EnvOverrideNote(keys: ["HUD_TICKERS"])
            }

            Section("声で起動") {
                TextField("合図（カンマ区切り）", text: $settings.wakePhrasesText,
                          prompt: Text("マッスル,マッスー,muscle"))
                Text("語幹で書くと認識のゆらぎを拾いやすくなります。次の聞き取りから反映されます。\n合図に続けて話した内容がそのまま指示になります（例:「マッスル、今日のニュースを要約して」）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EnvOverrideNote(keys: ["HUD_WAKE_PHRASES"])
            }

            Section("手を叩いて起動") {
                Toggle("「パンパン」と2回手を叩いたら起動する", isOn: $settings.clapEnabled)
                if settings.clapEnabled {
                    Picker("感度", selection: $settings.clapSensitivity) {
                        ForEach(ClapDetector.Sensitivity.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }
                }
                Text("上部右の「音声起動」がONのときに使えます。叩いたあとに話した内容が指示になります。物音で誤作動するときは感度を下げ、反応しないときは上げてください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("すべて既定に戻す", role: .destructive) { settings.resetAll() }
            }
        }
        .formStyle(.grouped)
    }

    private var agentDescription: String {
        switch settings.agentTarget {
        case .voiceChat:
            return "話しかけた内容を Claude Code に聞き、答えを画面に表示して声で読み上げます。Claudeの有料プランでログイン済みの Claude Code が必要です（追加料金なし）。5分以内に続けて話すと、会話の続きとして答えます。読み上げ中に手を2回叩くと止まります。"
        case .claudeApp:
            return "Claudeデスクトップアプリで新しいチャットを開き、話した内容を送信します。キー入力にアクセシビリティの許可が必要です。"
        case .claudeCode:
            return "ターミナルを開いて作業フォルダで `claude` を起動し、話した内容を最初の指示として渡します。初回はターミナルを操作する許可（オートメーション）を求められます。Claude Code のインストールが必要です。"
        case .codex:
            return "Codexアプリで新しいチャットを作り、音声ライブ（⌃⇧V）を開きます。話している間はHUDが最前面に出ます。"
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダで起動"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.claudeCodeDirectory = url.path
    }
}

private struct ThemeTab: View {
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        Form {
            Section("配色テーマ") {
                Picker("テーマ", selection: $settings.theme) {
                    ForEach(HUDTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }

            if settings.theme == .custom {
                Section("カスタムカラー") {
                    ColorPicker("アクセントカラー", selection: $settings.customAccent,
                                supportsOpacity: false)
                    Text("選んだ色から、副色・背景・粒子の色を自動で組み立てます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ThemePreview()
            }
        }
        .formStyle(.grouped)
    }
}

/// 現在のテーマの主要色を並べて見せる
private struct ThemePreview: View {
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        let palette = settings.theme.palette(customAccent: settings.customAccent)
        HStack(spacing: 10) {
            swatch(palette.accent, "主色")
            swatch(palette.secondary, "副色")
            swatch(palette.tertiary, "強調")
            swatch(palette.background, "背景")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 6)
                .fill(color)
                .frame(width: 52, height: 34)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PanelsTab: View {
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        Form {
            Section("左の列") {
                Toggle("今日のMac・AIレッスン", isOn: $settings.showLesson)
                Toggle("休憩・姿勢リマインダー", isOn: $settings.showBreak)
                Toggle("システム（CPU・メモリ・ストレージ）", isOn: $settings.showSystem)
                Toggle("ネットワーク", isOn: $settings.showNetwork)
                Toggle("Claudeの使用量", isOn: $settings.showUsage)
            }
            Section("右の列") {
                Toggle("天気", isOn: $settings.showWeather)
                Toggle("今日の予定（カレンダー）", isOn: $settings.showCalendar)
                Toggle("よく使う指示", isOn: $settings.showCommands)
                Toggle("株価・為替", isOn: $settings.showMarket)
            }
            Section("よく使う指示") {
                TextEditor(text: Binding(
                    get: { settings.quickCommandsText.isEmpty ? HUDConfig.defaultQuickCommandsText : settings.quickCommandsText },
                    set: { settings.quickCommandsText = $0 }))
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 130)
                Text("1行に「ボタン名|AIへの指示」。押すと、設定中のAI（一般 › 起動するAI）にその指示を送ります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("既定に戻す") { settings.quickCommandsText = "" }
            }
            Section("休憩・姿勢リマインダー") {
                Stepper(value: $settings.breakMinutes, in: 15...120, step: 5) {
                    Text("\(Int(settings.breakMinutes))分 続けて作業したら知らせる")
                }
                Toggle("時間になったら通知も出す", isOn: $settings.breakNotify)
                Text("キーボードやトラックパッドを5分以上さわらなければ、休憩したとみなして数え直します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("下部") {
                Toggle("砂の帯（オーディオフロー）", isOn: $settings.showSand)
            }
            Section {
                Text("列のパネルをすべて消すと、その列ぶん中央が広がります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct PerformanceTab: View {
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        Form {
            Section("粒子") {
                Slider(value: $settings.grainCount, in: 0...3000, step: 100) {
                    Text("粒子の数")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("3000")
                }
                Text("現在: \(Int(settings.grainCount))（0で粒子なし）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                EnvOverrideNote(keys: ["HUD_GRAINS"])
            }

            Section("更新頻度") {
                Stepper(value: $settings.activeFPS, in: 10...60, step: 5) {
                    Text("音が出ている間: \(Int(settings.activeFPS)) fps")
                }
                Stepper(value: $settings.idleFPS, in: 1...30, step: 1) {
                    Text("待機中: \(Int(settings.idleFPS)) fps")
                }
                EnvOverrideNote(keys: ["HUD_FPS", "HUD_IDLE_FPS"])
            }

            Section {
                Text("それでも重い場合は、環境変数 HUD_STATIC=1 で起動すると動く描画をすべて止められます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
