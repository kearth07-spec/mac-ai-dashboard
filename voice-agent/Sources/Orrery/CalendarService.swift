import EventKit
import SwiftUI

/// 今日・明日の予定1件ぶん
struct AgendaItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let color: Color
}

/// Macの「カレンダー」アプリの予定を読む（Googleカレンダーなど、カレンダーに追加済みのアカウントも含む）。
/// 読むだけで、予定を書き換えたり外へ送ったりはしない。
@MainActor
final class CalendarService: ObservableObject {
    enum Access { case unknown, granted, denied, unavailable }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var today: [AgendaItem] = []
    @Published private(set) var tomorrow: [AgendaItem] = []

    private let store = EKEventStore()
    private var ticker: Timer?
    private var observer: NSObjectProtocol?

    func start() {
        guard ticker == nil else { return }
        // 素の実行ファイルだと用途説明を読めず、許可を求めた瞬間にOSがプロセスを落とす
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            access = .unavailable
            return
        }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        observer = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged,
                                                          object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        Task { await requestAccess() }
    }

    private func requestAccess() async {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            access = .granted
        case .notDetermined:
            let granted = (try? await store.requestFullAccessToEvents()) ?? false
            access = granted ? .granted : .denied
        default:
            access = .denied
        }
        reload()
    }

    func reload() {
        guard access == .granted else { return }
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        guard let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
              let end = calendar.date(byAdding: .day, value: 2, to: startOfToday) else { return }

        let predicate = store.predicateForEvents(withStart: startOfToday, end: end, calendars: nil)
        let items: [AgendaItem] = store.events(matching: predicate)
            .compactMap { event in
                guard let start = event.startDate, let finish = event.endDate else { return nil }
                // 繰り返しの予定は同じIDになるので、開始時刻もつけて区別する
                let identifier = (event.eventIdentifier ?? UUID().uuidString) + "-\(start.timeIntervalSince1970)"
                return AgendaItem(id: identifier,
                                  title: event.title ?? "（無題）",
                                  start: start,
                                  end: finish,
                                  allDay: event.isAllDay,
                                  color: Color(nsColor: event.calendar?.color ?? .systemBlue))
            }
            .sorted { $0.start < $1.start }

        // 今日はまだ終わっていない予定だけ
        today = items.filter { $0.start < startOfTomorrow && ($0.allDay || $0.end > now) }
        tomorrow = items.filter { $0.start >= startOfTomorrow }
    }
}
