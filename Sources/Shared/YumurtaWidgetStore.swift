import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

//  Общее хранилище виджетов рабочего стола. Основное приложение пишет снимок в
//  App Group, виджеты (расширение YumurtaWidgets) читают. Без App Group
//  (расширение не включено, у App ID нет группы) запись никому не видна и
//  ничего не ломает.

struct YumurtaWidgetSnapshot: Codable, Equatable {
    /// Незавершённый заказ (самый свежий).
    var orderId: Int?
    var orderNumber: String?
    var shopName: String?
    var statusText: String?
    var step: String?
    var etaMinutes: Int?
    /// Последний заказ вообще (для «Повторить заказ», когда активного нет).
    var lastOrderId: Int?
    var lastShopName: String?
    /// Баланс баллов уже отформатированной строкой («1 250 ₽»): деньги не float.
    var bonusText: String?
    var updatedAt: Double

    static let empty = YumurtaWidgetSnapshot(updatedAt: 0)

    var hasActiveOrder: Bool { orderId != nil }
}

enum YumurtaWidgetStore {
    static let appGroup = "group.ru.marketplace.client.premium"
    private static let key = "ym.widget.snapshot.v1"
    private static let lock = NSLock()

    private static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }

    static func load() -> YumurtaWidgetSnapshot {
        lock.lock(); defer { lock.unlock() }
        return read()
    }

    /// Меняет снимок и просит систему обновить виджеты, если что-то изменилось.
    static func update(_ change: (inout YumurtaWidgetSnapshot) -> Void) {
        lock.lock()
        let old = read()
        var next = old
        change(&next)
        next.updatedAt = Date().timeIntervalSince1970
        let changed = next.withoutStamp != old.withoutStamp
        if changed, let data = try? JSONEncoder().encode(next) {
            defaults?.set(data, forKey: key)
        }
        lock.unlock()
        if changed { reloadWidgets() }
    }

    /// Выход из аккаунта: чужие заказы и баланс на экране не оставляем.
    static func clear() {
        lock.lock()
        defaults?.removeObject(forKey: key)
        lock.unlock()
        reloadWidgets()
    }

    private static func read() -> YumurtaWidgetSnapshot {
        guard let data = defaults?.data(forKey: key),
              let s = try? JSONDecoder().decode(YumurtaWidgetSnapshot.self, from: data) else { return .empty }
        return s
    }

    private static func reloadWidgets() {
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}

private extension YumurtaWidgetSnapshot {
    /// Сравнение без метки времени: иначе «изменилось» было бы всегда.
    var withoutStamp: YumurtaWidgetSnapshot {
        var c = self
        c.updatedAt = 0
        return c
    }
}

/// Диплинки виджетов и Live Activity (разбирает DeepLinkRouter).
enum YumurtaLinks {
    static func order(_ id: Int, repeatOrder: Bool = false) -> URL {
        let s = repeatOrder ? "yumurta://order/\(id)?repeat=1" : "yumurta://order/\(id)"
        return URL(string: s) ?? URL(string: "yumurta://orders") ?? URL(fileURLWithPath: "/")
    }
    static var orders: URL { URL(string: "yumurta://orders") ?? URL(fileURLWithPath: "/") }
    static var bonuses: URL { URL(string: "yumurta://bonuses") ?? URL(fileURLWithPath: "/") }
}
