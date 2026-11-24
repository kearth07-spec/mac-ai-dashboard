import SwiftUI

// MARK: - 共通の小さなボタン

private struct PanelButton: View {
    let title: String
    var icon: String?
    var tint: Color = HUD.cyan
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .bold)) }
                Text(title).font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(hovering ? 0.18 : 0.08)))
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 今日のMac・AIレッスン

extension Lessons {
    /// index.html と同じ開始日（日本時間 2025/6/1）から数えて、毎日1つずつ進む。最後まで行ったら最初に戻る。
    private static let tokyo: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo") ?? .current
        return calendar
    }()

    private static let startDate: Date = {
        tokyo.date(from: DateComponents(year: 2025, month: 6, day: 1)) ?? Date()
    }()

    static func today(offset: Int = 0, now: Date = Date()) -> Lesson {
        let days = tokyo.dateComponents([.day], from: startDate, to: tokyo.startOfDay(for: now)).day ?? 0
        let count = all.count
        let index = ((days + offset) % count + count) % count
        return all[index]
    }

    static func tagLabel(_ tag: String) -> String {
        switch tag {
        case "trackpad": return "トラックパッド"
        case "spotlight": return "Spotlight"
        case "dock": return "Dock・UI"
        case "ai": return "AI活用"
        case "finder": return "Finder"
        default: return tag
        }
    }
}

struct LessonPanel: View {
    /// ◀ ▶ で前後のレッスンを見る（0が今日）
    @State private var offset = 0

    private var dayLabel: String {
        if offset == 0 { return "今日のレッスン" }
        return offset < 0 ? "\(-offset)日前" : "\(offset)日後"
    }

    var body: some View {
        let lesson = Lessons.today(offset: offset)
        HUDPanel(title: "MAC & AI LESSON", trailing: "DAY \(lesson.day) / \(Lessons.all.count)") {
            HStack(spacing: 6) {
                Text(Lessons.tagLabel(lesson.tag))
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(HUD.cyan)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(HUD.cyan.opacity(0.12)))
                Text(dayLabel)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                PanelButton(title: "◀") { offset -= 1 }
                if offset != 0 { PanelButton(title: "今日") { offset = 0 } }
                PanelButton(title: "▶") { offset += 1 }
            }

            Text(lesson.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(lesson.body)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(lesson.tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: 6) {
                        Text("▸").foregroundStyle(HUD.cyan)
                        Text(tip).foregroundStyle(.white.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 10.5))
                }
            }

            HStack(spacing: 5) {
                ForEach(lesson.shortcuts, id: \.self) { key in
                    Text(key)
                        .font(HUD.mono(10, .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.2), lineWidth: 1))
                }
                Spacer()
                PanelButton(title: "Claudeにくわしく聞く", icon: "sparkles") {
                    HUDWindowState.shared.requestVoiceSession(
                        command: "Macの「\(lesson.title)」について、Mac初心者向けに手順つきでくわしく教えてください。")
                }
            }
        }
    }
}

// MARK: - 休憩・姿勢リマインダー

struct BreakPanel: View {
    @ObservedObject var reminder: BreakReminder
    @ObservedObject private var settings = HUDSettings.shared

    var body: some View {
        let limit: Double = max(1.0, settings.breakMinutes) * 60.0
        let ratio: Double = min(1.0, reminder.workedSeconds / limit)
        let tint: Color = reminder.isDue ? HUD.warn : HUD.up
        let glow: CGFloat = reminder.isDue ? 1 : 0
        let minutes: Int = Int(reminder.workedSeconds / 60)
        HUDPanel(title: "MUSCLE BREAK", trailing: "\(Int(settings.breakMinutes))分ごと",
                 glow: glow) {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(String(minutes))
                    .font(HUD.mono(28, .bold))
                    .foregroundStyle(.white)
                Text("分 連続で作業中")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                if reminder.isDue {
                    Text("休憩しよう！")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HUD.warn)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(tint).frame(width: proxy.size.width * CGFloat(ratio))
                }
            }
            .frame(height: 5)

            VStack(alignment: .leading, spacing: 3) {
                Text("おすすめストレッチ ▸ \(reminder.stretch.name)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HUD.cyan)
                Text(reminder.stretch.how)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                PanelButton(title: "休憩した", icon: "checkmark", tint: HUD.up) { reminder.tookBreak() }
                PanelButton(title: "別のストレッチ", icon: "arrow.triangle.2.circlepath") { reminder.nextStretch() }
                Spacer()
            }
        }
    }
}

// MARK: - 今日の予定

struct CalendarPanel: View {
    @ObservedObject var calendar: CalendarService

    var body: some View {
        HUDPanel(title: "SCHEDULE", trailing: Self.day.string(from: Date())) {
            switch calendar.access {
            case .granted:
                if calendar.today.isEmpty && calendar.tomorrow.isEmpty {
                    note("今日・明日の予定はありません")
                } else {
                    section("今日", items: calendar.today)
                    if !calendar.tomorrow.isEmpty {
                        section("明日", items: calendar.tomorrow)
                    }
                }
            case .denied:
                note("カレンダーを見る許可がありません")
                PanelButton(title: "許可の設定を開く", icon: "lock.open") {
                    PrivacySettings.open(.calendars)
                }
            case .unknown:
                note("読み込み中…")
            case .unavailable:
                note("Muscle.app から起動すると表示されます")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(HUD.cyan.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section(_ title: String, items: [AgendaItem]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(HUD.cyan.opacity(0.7))
            if items.isEmpty {
                Text("予定なし")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
            ForEach(items.prefix(4)) { item in
                HStack(spacing: 7) {
                    Circle().fill(item.color).frame(width: 6, height: 6)
                    Text(item.allDay ? "終日" : Self.time.string(from: item.start))
                        .font(HUD.mono(10, .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 38, alignment: .leading)
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
            }
            if items.count > 4 {
                Text("ほか \(items.count - 4) 件")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
    }

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d (E)"
        return formatter
    }()
}

// MARK: - よく使う指示

struct QuickCommandsPanel: View {
    @ObservedObject private var settings = HUDSettings.shared
    @ObservedObject private var windowState = HUDWindowState.shared

    var body: some View {
        HUDPanel(title: "QUICK COMMANDS", trailing: "▸ \(HUDConfig.agentTarget.shortName)") {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                      spacing: 8) {
                ForEach(HUDConfig.quickCommands) { command in
                    CommandTile(command: command, disabled: windowState.starting) {
                        windowState.requestVoiceSession(command: command.prompt)
                    }
                }
            }
            Text("ボタンの中身は 設定（⌘,）› パネル で変えられます")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.35))
        }
    }
}

private struct CommandTile: View {
    let command: QuickCommand
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(command.label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 34)
                .padding(.horizontal, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(HUD.cyan.opacity(hovering ? 0.2 : 0.08)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(HUD.cyan.opacity(hovering ? 0.7 : 0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(command.prompt)
    }
}
