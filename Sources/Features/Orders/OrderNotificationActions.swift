import Foundation
import UserNotifications

//  Кнопки в push о заказе и диплинки yumurta://order/<id>[?repeat=1].
//  Работает без расширений. Сервер выбирает набор кнопок полем aps.category:
//    "ORDER_DELIVERED" — «Оценить» и «Повторить» (заказ доставлен).
//  Тап по кнопке открывает приложение: «Оценить» — деталь заказа (там форма
//  отзыва), «Повторить» — деталь заказа и сразу повтор состава в корзину.

enum OrderNotificationCategories {
    static let delivered = "ORDER_DELIVERED"
    static let rateAction = "ORDER_RATE"
    static let repeatAction = "ORDER_REPEAT"

    /// Один раз на запуск (AppDelegate). Других категорий в приложении нет.
    static func register() {
        let rate = UNNotificationAction(identifier: rateAction, title: "Оценить", options: [.foreground])
        let again = UNNotificationAction(identifier: repeatAction, title: "Повторить", options: [.foreground])
        let category = UNNotificationCategory(identifier: delivered, actions: [rate, again],
                                              intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// true — нажатие на кнопку разобрано здесь (обычный переход по тапу не нужен).
    /// `foreign` — push прежнего аккаунта: кнопки ничего не делают.
    static func handle(_ response: UNNotificationResponse, foreign: Bool) -> Bool {
        let action = response.actionIdentifier
        guard action == rateAction || action == repeatAction else { return false }
        let info = response.notification.request.content.userInfo
        if foreign { return true }
        var id = 0
        if let i = info["order_id"] as? Int { id = i }
        if let s = info["order_id"] as? String, let i = Int(s) { id = i }
        guard id > 0 else { return false }
        DispatchQueue.main.async { OrderRepeatIntent.open(id, repeatOrder: action == repeatAction) }
        return true
    }
}

/// Открыть заказ (и, если нужно, повторить его). Экран заказа забирает просьбу
/// через take(_:) после загрузки.
enum OrderRepeatIntent {
    private static var pending: (id: Int, at: Date)?

    static func open(_ id: Int, repeatOrder: Bool) {
        let nav = NavCoordinator.shared
        let logged = Session.shared.isLoggedIn
        if repeatOrder && logged { pending = (id, Date()) }
        nav.revealForPush(closeAll: true) {
            if logged { nav.pendingOrderDetail = id } else { DeepLinkRouter.shared.requestedTab = 3 }
        }
    }

    /// Просьба «повторить» именно для этого заказа; старше 20 с — не исполняется.
    static func take(_ id: Int) -> Bool {
        guard let p = pending, p.id == id else { return false }
        pending = nil
        return Date().timeIntervalSince(p.at) < 20
    }
}
