import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

//  Live Activity «Статус заказа» (экран блокировки и Dynamic Island, iOS 16.1+).
//  Интерфейс рисует расширение YumurtaWidgets (Extensions/Widgets). Пока
//  расширения в сборке нет, Activity.request бросает ошибку — мы её молча
//  глотаем: приложение работает как раньше.
//
//  Когда обновляется:
//   - оформление заказа (доставка / самовывоз, не предзаказ) — start;
//   - открытие приложения и загрузка списка заказов — refreshAll;
//   - push order_status / order_changed: в фоне только если у push есть
//     content-available (UIBackgroundModes: remote-notification уже включён),
//     на экране — по .ymOrderPushed;
//   - done / cancelled — завершение активности.
//
//  Серверный push-to-update (APNs liveactivity) выключен: ручки токена на
//  сервере ещё нет. Включить: serverPushEnabled = true.

enum OrderLiveActivity {
    /// Отправлять push-токен активности на сервер. Ручки POST /api/v1/push/live-activity
    /// {order_id, token} на сервере пока нет — выключено.
    static let serverPushEnabled = false
    static let tokenPath = "api/v1/push/live-activity"

    // MARK: - Вход для остального приложения

    /// После успешного создания заказа. Всё, что не доставка/самовывоз, молча пропускаем.
    static func startAfterCheckout(result: OrderCreateResult, shopName: String?, deliveryType: String, isService: Bool) {
        guard !isService, result.preorderAt == nil, let id = result.resolvedId, id > 0 else { return }
        let type = result.deliveryType ?? deliveryType
        guard type == "delivery" || type == "pickup" else { return }
        let number = result.dailyNumber ?? id
        guard #available(iOS 16.1, *) else { return }
        #if canImport(ActivityKit)
        OrderActivityController.start(orderId: id, number: "№\(number)",
                                      shopName: shopName ?? "Заказ", isPickup: type == "pickup",
                                      eta: result.etaMax ?? result.etaMin)
        #endif
    }

    /// Обновить все идущие активности по свежим данным сервера. Зовём при
    /// открытии приложения / загрузке списка заказов.
    static func refreshAll() {
        guard #available(iOS 16.1, *) else { return }
        #if canImport(ActivityKit)
        OrderActivityController.refreshAll()
        #endif
    }

    /// Обновить активность одного заказа (push, возврат на экран заказа).
    static func refresh(orderId: Int) async {
        guard #available(iOS 16.1, *) else { return }
        #if canImport(ActivityKit)
        await OrderActivityController.refresh(orderId: orderId)
        #endif
    }

    /// Выход из аккаунта: активности чужого заказа не оставляем.
    static func endAll() {
        guard #available(iOS 16.1, *) else { return }
        #if canImport(ActivityKit)
        OrderActivityController.endAll()
        #endif
    }

    /// id заказа из push order_status / order_changed; иначе nil.
    static func orderId(fromPush userInfo: [AnyHashable: Any]) -> Int? {
        let type = (userInfo["type"] as? String) ?? ""
        guard type == "order_status" || type == "order_changed" else { return nil }
        if let i = userInfo["order_id"] as? Int, i > 0 { return i }
        if let s = userInfo["order_id"] as? String, let i = Int(s), i > 0 { return i }
        return nil
    }

    // MARK: - Сопоставление статуса сервера и шага шкалы

    static func step(for status: String?) -> OrderStep {
        switch OrderFlow.normalize(status) {
        case "cancelled":            return .cancelled
        case "done":                 return .done
        case "in_delivery", "ready": return .onWay
        case "preparing":            return .preparing
        default:                     return .placed
        }
    }

    static func isFinished(_ status: String?) -> Bool {
        !OrderFlow.isActive(status)
    }

    /// Тело запроса токена активности (ключи уйдут snake_case: order_id).
    struct TokenBody: Encodable {
        let orderId: Int
        let token: String
    }

    static func sendToken(orderId: Int, token: String) async {
        guard serverPushEnabled else { return }
        try? await API.shared.postVoid(tokenPath, body: TokenBody(orderId: orderId, token: token))
    }
}

#if canImport(ActivityKit)
@available(iOS 16.1, *)
enum OrderActivityController {
    private static let lock = NSLock()
    private static var observedTokens = Set<String>()
    private static var observingPush = false

    // MARK: Запуск

    static func start(orderId: Int, number: String, shopName: String, isPickup: Bool, eta: Int?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        observePushNotifications()
        if find(orderId) != nil { Task { await refresh(orderId: orderId) }; return }
        let state = OrderActivityAttributes.ContentState(
            step: .placed, statusText: OrderStep.placed.title(isPickup: isPickup),
            etaMinutes: eta, etaAt: etaAt(eta))
        let attrs = OrderActivityAttributes(orderId: orderId, orderNumber: number, shopName: shopName, isPickup: isPickup)
        let pushType: PushType? = OrderLiveActivity.serverPushEnabled ? .token : nil
        do {
            let activity: Activity<OrderActivityAttributes>
            if #available(iOS 16.2, *) {
                activity = try Activity<OrderActivityAttributes>.request(
                    attributes: attrs, content: ActivityContent(state: state, staleDate: nil), pushType: pushType)
            } else {
                activity = try Activity<OrderActivityAttributes>.request(
                    attributes: attrs, contentState: state, pushType: pushType)
            }
            observeToken(activity)
        } catch {
            // Расширения нет / активности выключены / лимит — молчим.
        }
    }

    // MARK: Обновление

    static func refreshAll() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let ids = Activity<OrderActivityAttributes>.activities.map { $0.attributes.orderId }
        guard !ids.isEmpty else { return }
        observePushNotifications()
        for id in ids { Task { await refresh(orderId: id) } }
    }

    static func refresh(orderId: Int) async {
        guard let activity = find(orderId) else { return }
        observeToken(activity)
        guard let o: OrderDetail = try? await API.shared.get("api/v1/orders/\(orderId)") else { return }
        let isPickup = activity.attributes.isPickup
        let step = OrderLiveActivity.step(for: o.status)
        var eta: Int?
        var courier: String?
        if step != .done && step != .cancelled {
            let t: TrackData? = try? await API.shared.get("api/v1/orders/\(orderId)/track")
            eta = t?.etaMinutes
            let name = t?.courier?.name?.trimmingCharacters(in: .whitespaces) ?? ""
            courier = name.isEmpty ? nil : name
        }
        let title = (o.statusTitle ?? "").trimmingCharacters(in: .whitespaces)
        let state = OrderActivityAttributes.ContentState(
            step: step, statusText: title.isEmpty ? step.title(isPickup: isPickup) : title,
            etaMinutes: eta, etaAt: etaAt(eta), courierName: courier)
        if OrderLiveActivity.isFinished(o.status) {
            await finish(activity, state)
        } else {
            await apply(activity, state)
        }
    }

    static func endAll() {
        for a in Activity<OrderActivityAttributes>.activities {
            let state = a.contentState
            Task { await finish(a, state, immediately: true) }
        }
    }

    // MARK: Внутреннее

    private static func find(_ orderId: Int) -> Activity<OrderActivityAttributes>? {
        Activity<OrderActivityAttributes>.activities.first { $0.attributes.orderId == orderId }
    }

    private static func etaAt(_ minutes: Int?) -> Int? {
        guard let m = minutes, m > 0 else { return nil }
        return Int(Date().timeIntervalSince1970) + m * 60
    }

    private static func apply(_ a: Activity<OrderActivityAttributes>, _ state: OrderActivityAttributes.ContentState) async {
        if #available(iOS 16.2, *) {
            await a.update(ActivityContent(state: state, staleDate: nil))
        } else {
            await a.update(using: state)
        }
    }

    private static func finish(_ a: Activity<OrderActivityAttributes>, _ state: OrderActivityAttributes.ContentState,
                               immediately: Bool = false) async {
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .after(Date().addingTimeInterval(30 * 60))
        if #available(iOS 16.2, *) {
            await a.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: policy)
        } else {
            await a.end(using: state, dismissalPolicy: policy)
        }
    }

    /// Push-токен активности — на сервер (пока выключено флагом).
    private static func observeToken(_ a: Activity<OrderActivityAttributes>) {
        guard OrderLiveActivity.serverPushEnabled else { return }
        lock.lock()
        let fresh = observedTokens.insert(a.id).inserted
        lock.unlock()
        guard fresh else { return }
        let orderId = a.attributes.orderId
        Task {
            for await data in a.pushTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                await OrderLiveActivity.sendToken(orderId: orderId, token: hex)
            }
        }
    }

    /// Push о заказе, пока приложение открыто (AppDelegate постит .ymOrderPushed).
    private static func observePushNotifications() {
        lock.lock()
        let already = observingPush
        observingPush = true
        lock.unlock()
        guard !already else { return }
        NotificationCenter.default.addObserver(forName: .ymOrderPushed, object: nil, queue: nil) { n in
            guard let id = n.object as? Int else { return }
            Task { await refresh(orderId: id) }
        }
    }
}
#endif
