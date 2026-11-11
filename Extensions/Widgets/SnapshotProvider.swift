import WidgetKit

//  Общий источник данных виджетов: снимок из App Group (его пишет основное приложение).

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: YumurtaWidgetSnapshot
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        var s = YumurtaWidgetSnapshot.empty
        s.orderId = 1
        s.orderNumber = "№12"
        s.shopName = "Yumurta"
        s.statusText = "Готовится"
        s.step = OrderStep.preparing.rawValue
        s.bonusText = "250 ₽"
        return SnapshotEntry(date: Date(), snapshot: s)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: Date(), snapshot: YumurtaWidgetStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: Date(), snapshot: YumurtaWidgetStore.load())
        // Приложение само просит обновление (reloadAllTimelines); на всякий случай - раз в 30 минут.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}
