import Foundation

//  Данные для виджетов рабочего стола (расширение YumurtaWidgets). Пишем снимок
//  в App Group через YumurtaWidgetStore; без расширения запись никому не видна.

enum OrderWidgetBridge {
    private static var lastBonusFetch: Date?

    /// Список заказов загружен: самый свежий незавершённый — «Активный заказ»,
    /// самый свежий вообще — для «Повторить заказ».
    static func update(orders: [Order]) {
        let active = orders.first { OrderFlow.isActive($0.status) }
        let last = orders.first
        YumurtaWidgetStore.update { s in
            s.lastOrderId = last?.id
            s.lastShopName = last?.shopName
            if let a = active {
                s.orderId = a.id
                s.orderNumber = "№\(a.dailyNumber ?? a.id)"
                s.shopName = a.shopName
                let title = (a.statusTitle ?? "").trimmingCharacters(in: .whitespaces)
                let step = OrderLiveActivity.step(for: a.status)
                s.statusText = title.isEmpty ? step.title(isPickup: a.deliveryType == "pickup") : title
                s.step = step.rawValue
            } else {
                s.orderId = nil
                s.orderNumber = nil
                s.shopName = nil
                s.statusText = nil
                s.step = nil
                s.etaMinutes = nil
            }
        }
    }

    /// Приложение стало активным: виджеты и Live Activity берут свежие данные.
    /// Не вошли в аккаунт — ничего не делаем.
    static func syncOnActive() async {
        guard Session.shared.isLoggedIn else { return }
        OrderLiveActivity.refreshAll()
        if let first: Page<Order> = try? await API.shared.page("api/v1/orders") {
            update(orders: first.items.filter { $0.isAppointment != true })
        }
        await refreshBonuses()
    }

    /// Баланс баллов для виджета «Бонусы»: сумма по заведениям, как в «Бонусах»
    /// профиля. Не чаще раза в 10 минут.
    static func refreshBonuses(force: Bool = false) async {
        if !force, let t = lastBonusFetch, Date().timeIntervalSince(t) < 600 { return }
        guard let list: [BonusShopBalance] = try? await API.shared.list("api/v1/profile/bonuses") else { return }
        lastBonusFetch = Date()
        var total: Decimal = 0
        for b in list { total += Money.dec(b.balance) }
        let text = Money.format(total)
        YumurtaWidgetStore.update { $0.bonusText = text }
    }

    /// Выход из аккаунта: виджеты и экран блокировки очищаем.
    static func clear() {
        lastBonusFetch = nil
        YumurtaWidgetStore.clear()
        OrderLiveActivity.endAll()
    }
}
