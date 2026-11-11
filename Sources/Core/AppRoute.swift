import Foundation
import UIKit

/// Единая точка «открыть экран» для быстрых действий иконки, Siri/«Команд» и Spotlight.
/// Использует ту же маршрутизацию, что и push: NavCoordinator, DeepLinkRouter.requestedTab,
/// ProfilePushIntent. Холодный старт: пока интерфейс не показан, маршрут ждёт.
enum AppRoute: Equatable {
    case orders
    case order(Int)
    case lastOrder
    case sendParcel
    case search
    case cart
    case org(slug: String)
    case product(Int)

    /// Интерфейс уже на экране (ставит YumurtaApp). До этого маршрут ждёт в pending.
    private static var uiReady = false
    private static var pending: AppRoute?

    /// Открыть экран (можно звать из любого потока).
    static func perform(_ route: AppRoute) {
        DispatchQueue.main.async {
            if uiReady {
                run(route)
            } else {
                pending = route
            }
        }
    }

    /// Интерфейс показан: выполняем отложенный маршрут (с паузой, чтобы экраны успели смонтироваться).
    static func markReady() {
        guard !uiReady else { return }
        uiReady = true
        if let route = pending {
            pending = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { run(route) }
        }
    }

    private static func run(_ route: AppRoute) {
        let nav = NavCoordinator.shared
        let router = DeepLinkRouter.shared
        let logged = Session.shared.isLoggedIn
        switch route {
        case .orders:
            nav.revealForPush(closeAll: true) { router.requestedTab = 3 }
        case .order(let id):
            nav.revealForPush(closeAll: true) {
                if logged { nav.pendingOrderDetail = id } else { router.requestedTab = 3 }
            }
        case .lastOrder:
            guard logged else {
                nav.revealForPush(closeAll: true) { router.requestedTab = 3 }
                return
            }
            Task {
                let id = await latestOrderId()
                await MainActor.run {
                    if let id = id { run(.order(id)) } else { run(.orders) }
                }
            }
        case .sendParcel:
            nav.revealForPush(closeAll: true) {
                router.requestedTab = 0
                nav.profileOpen = true
                // Гостю откроется профиль с кнопкой «Войти».
                if logged { ProfilePushIntent.open(.parcelNew) }
            }
        case .search:
            nav.revealForPush(closeAll: true) { router.requestedTab = 1 }
        case .cart:
            nav.revealForPush(closeAll: true) { router.requestedTab = 2 }
        case .org(let slug):
            nav.openOrg(slug: slug)
        case .product(let id):
            nav.revealForPush(closeAll: true) {
                router.requestedTab = 0
                nav.pendingProductId = id
            }
        }
    }

    /// Самый новый заказ человека (не запись на услугу). nil — нет заказов или нет сети.
    private static func latestOrderId() async -> Int? {
        guard let page: Page<Order> = try? await API.shared.page("api/v1/orders") else { return nil }
        let list = page.items.filter { $0.isAppointment != true }
        return list.map { $0.id }.max()
    }
}
