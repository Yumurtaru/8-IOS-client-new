import UIKit
import UserNotifications

// AppDelegate premium-клиента. Push регистрируется напрямую через APNs (без Firebase):
// device-токен уходит на POST /api/v1/push/register (Core/Push.swift), platform: "ios".
// Обработка уведомлений (тап → заказ/чат, foreground-баннер, бейдж) — здесь.
// Примечание: для реальной доставки нужен канал (FCM или прямой APNs на сервере) —
// это конфигурируется отдельно; на устройстве всё готово.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Кэш картинок. AsyncImage ходит через общий URLCache, а у него по
        // умолчанию ~0,5 МБ памяти и 10 МБ диска: фото каталога вытесняли друг
        // друга, и при прокрутке те же картинки качались заново. API-запросы
        // этот кэш не используют (.reloadIgnoringLocalCacheData).
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        // Сбрасываем бейдж на иконке при запуске.
        application.applicationIconBadgeNumber = 0
        // Запрос разрешения на пуш — ГАРАНТИРОВАННО при старте (не зависит от .task/онбординга,
        // которые могут не сработать под fullScreenCover). iOS покажет окно один раз.
        requestPushAuth()
        // Холодный старт по тапу на уведомление: разбираем payload и маршрутизируем.
        if let remote = launchOptions?[.remoteNotification] as? [AnyHashable: Any] {
            handleNotification(remote)
        }
        return true
    }

    func requestPushAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
        }
    }

    // APNs-токен → hex-строка → на бэкенд.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Push.shared.fcmToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await Push.shared.registerIfPossible() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Тихо игнорируем: push не критичен для работы приложения.
    }

    // Показ уведомления, когда приложение открыто (баннер + звук).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // П-24 №6 (А62): push прежнего аккаунта на этом телефоне не показываем.
        let info = notification.request.content.userInfo
        if Self.isForeign(info) { completionHandler([]); return }
        // Волна 4313: открытые деталь заказа / чат по нему перечитываются сразу,
        // а не ждут своего опроса.
        if let id = Self.buyerOrderId(info) { NotificationCenter.default.post(name: .ymOrderPushed, object: id) }
        // А79: открытые карточка и список посылок перечитываются сразу.
        if let id = Self.parcelId(info) { NotificationCenter.default.post(name: .ymParcelPushed, object: id) }
        // А97: решение по заявке курьера — открытый экран «Стать курьером» и профиль перечитают /pool/me.
        // А98: и блокировка / разблокировка (event block|unblock). Баннер — текст сервера.
        if (info["type"] as? String) == "pool_account" { NotificationCenter.default.post(name: .ymCourierPushed, object: nil) }
        // А102: ответ поддержки — открытые «Мои обращения» и переписка перечитаются сразу.
        if (info["type"] as? String) == "support" { NotificationCenter.default.post(name: .ymSupportPushed, object: Self.ticketId(info)) }
        completionHandler([.banner, .sound, .badge])
    }

    /// П-24 №6 (А62): у всех push сервера в data есть user_id получателя. Есть и
    /// не равен вошедшему — уведомление чужое (токен остался от прежнего
    /// аккаунта). Нет user_id (старый сервер) или никто не вошёл — как раньше.
    private static func isForeign(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let uid = intValue(userInfo["user_id"]), uid > 0 else { return false }
        let me = UserDefaults.standard.integer(forKey: AuthLastUser.key)
        // Волна 4313: никто не вошёл. Явный выход забывает id (me == 0) — push
        // прежнего аккаунта (отвязка токена не дошла без сети) раньше показывался
        // следующему человеку баннером. Сессия кончилась сама (401) — id помним,
        // и свои push человек видит, как раньше.
        if !Session.shared.isLoggedIn { return me == 0 || me != uid }
        return me > 0 && me != uid
    }

    // Тап по уведомлению (приложение в фоне/закрыто) → переход к заказу/чату.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        handleNotification(response.notification.request.content.userInfo)
        completionHandler()
    }

    // Тихий/фоновый data-push (обновление статуса) — просто подтверждаем.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        completionHandler(.newData)
    }

    // MARK: - Маршрутизация из payload уведомления
    // Сервер кладёт в data: type ("order_chat" | "order_status" | …) и order_id (строкой).
    // Чат по заказу → NavCoordinator.openChat; иначе с order_id → таб «Заказы» + деталь.
    /// Последний разобранный push и когда. При запуске тапом по уведомлению iOS
    /// отдаёт его дважды: в launchOptions и в didReceive. Переход выполнялся два
    /// раза — дважды перечитывался список заказов, дважды закрывались окна.
    private var lastHandled: (key: String, at: Date)?

    private func handleNotification(_ userInfo: [AnyHashable: Any]) {
        // П-24 №6: чужой push (прежний аккаунт) — просто открываем приложение,
        // без перехода к чужому заказу или чату.
        if Self.isForeign(userInfo) { return }
        // Текст уведомления тоже в ключе: два разных сообщения чата по одному
        // заказу за 5 с раньше склеивались в одно. Дубль одного push совпадает.
        let alert = (userInfo["aps"] as? [String: Any])?["alert"]
        let alertDict = alert as? [String: Any]
        let alertTitle = (alertDict?["title"] as? String) ?? ""
        let alertBody = (alertDict?["body"] as? String) ?? (alert as? String) ?? ""
        let dedupKey = ["type", "order_id", "status", "product_id", "slug", "screen", "ad_id", "booking_id", "ticket_id", "title", "body", "call_id", "event"]
            .map { k -> String in "\(k)=" + (userInfo[k].map { v in "\(v)" } ?? "") }.joined(separator: "&")
            + "&aps_title=" + alertTitle + "&aps_body=" + alertBody
        if let last = lastHandled, last.key == dedupKey, Date().timeIntervalSince(last.at) < 5 { return }
        lastHandled = (dedupKey, Date())
        DispatchQueue.main.async {
            let opened = Self.openNotification(userInfo)
            // Волна 4313: push без экрана (бронь стола, рассылка, тест) — раньше
            // тап просто открывал приложение; теперь ведём в ленту «Уведомления»
            // в профиле. Push продавцу и гостя это не касается.
            let type = (userInfo["type"] as? String) ?? ""
            // А104: «Вы выиграли в розыгрыше» (type=giveaway, giveaway_id; core/Giveaway.php) —
            // своего экрана нет, текст — в ленте (запись giveaway_win): ведём в неё и после
            // истёкшей сессии (профиль попросит войти и откроет ленту — consumePushIntent).
            let giveaway = type == "giveaway"
            if !opened, Session.shared.isLoggedIn || giveaway, !Self.isSellerSide(type, userInfo) {
                NavCoordinator.shared.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    NavCoordinator.shared.profileOpen = true
                    ProfilePushIntent.open(.notifications)
                }
            }
            // Открытые деталь / чат этого заказа перечитываются сразу.
            if let id = Self.buyerOrderId(userInfo) { NotificationCenter.default.post(name: .ymOrderPushed, object: id) }
            if let id = Self.parcelId(userInfo) { NotificationCenter.default.post(name: .ymParcelPushed, object: id) }
            if (userInfo["type"] as? String) == "support" { NotificationCenter.default.post(name: .ymSupportPushed, object: Self.ticketId(userInfo)) }
            UIApplication.shared.applicationIconBadgeNumber = 0
        }
    }

    /// Волна 4313: id заказа покупателя из push (не продавца) — для .ymOrderPushed.
    private static func buyerOrderId(_ userInfo: [AnyHashable: Any]) -> Int? {
        let type = (userInfo["type"] as? String) ?? ""
        if isSellerSide(type, userInfo) { return nil }
        guard let id = intValue(userInfo["order_id"]), id > 0 else { return nil }
        return id
    }

    /// А102: номер обращения из push ответа поддержки (type=support, ticket_id строкой).
    static func ticketId(_ userInfo: [AnyHashable: Any]) -> Int? {
        guard (userInfo["type"] as? String) == "support",
              let id = intValue(userInfo["ticket_id"]), id > 0 else { return nil }
        return id
    }

    /// А79: id посылки из push pool_parcel (call_id строкой) — карточка «Посылка №…».
    private static func parcelId(_ userInfo: [AnyHashable: Any]) -> Int? {
        guard (userInfo["type"] as? String) == "pool_parcel",
              let id = intValue(userInfo["call_id"]), id > 0 else { return nil }
        return id
    }

    /// Волна 4313: переход по данным уведомления — общий для push и строки ленты
    /// «Уведомления» (data_json, см. AppNotification.notifPayload), чтобы строка
    /// вела туда же, куда push. Только на главном потоке. false — вести некуда.
    @discardableResult
    static func openNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let go = notificationAction(userInfo) else { return false }
        go()
        return true
    }

    /// Есть ли у уведомления экран для перехода (стрелка у строки ленты).
    static func canOpenNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        notificationAction(userInfo) != nil
    }

    /// Волна 4313: push ПРОДАВЦУ. Сервер шлёт их на все устройства владельца,
    /// и если он вошёл тем же аккаунтом в это приложение, тап открывал заказ
    /// покупателя по чужому order_id — «Заказ не найден». Чат продавцу сервер
    /// шлёт с shop_id, покупателю — без него (routes/api_v1.php, seller.php).
    private static let sellerTypes: Set<String> = [
        "new_order", "order_cancelled", "new_return", "order_returned",
        "pos_failed", "pos_rejected", "pos_dropped",
        "audit", "org_document", "product_hidden", "shop_published", "shop_publish_returned"
    ]
    private static func isSellerSide(_ type: String, _ userInfo: [AnyHashable: Any]) -> Bool {
        if sellerTypes.contains(type) { return true }
        // Крупная операция на кассе и брони жилья владельцу — тоже продавцу:
        // иначе тап уводил бы владельца в ленту покупателя.
        if (userInfo["kind"] as? String) == "approval" { return true }
        if (userInfo["screen"] as? String) == "lodging_bookings" { return true }
        // Чат и бронь стола продавцу приходят с shop_id, покупателю — без него.
        if type == "order_chat" || type == "reservation" { return userInfo["shop_id"] != nil }
        return false
    }

    /// Что сделать по данным уведомления; nil — просто открыть приложение.
    private static func notificationAction(_ userInfo: [AnyHashable: Any]) -> (() -> Void)? {
        let type = (userInfo["type"] as? String) ?? ""
        let orderId = intValue(userInfo["order_id"])
        // П-21.1: «цена снизилась / снова в наличии» — только product_id без type.
        let productId = intValue(userInfo["product_id"])
        // Новое заведение в городе: сервер присылает slug — это ключ экрана
        // организации (OrgView(shopSlug:)). RootTabView покажет её поверх
        // активного таба.
        let orgSlug = (userInfo["slug"] as? String) ?? ""
        // П-21.1: push без type (бронь жилья, объявление) — переход по ключам.
        // Новые ключи order_status (shop_id, shop_type, status_title,
        // is_appointment) на переход не влияют: он по-прежнему по order_id.
        // Неизвестный type без ключей — просто открываем приложение.
        let screen = (userInfo["screen"] as? String) ?? ""
        let adId = intValue(userInfo["ad_id"])
        let nav = NavCoordinator.shared
        // П-24 №5 (А62): shop_reopened несёт slug, как new_shop, — открываем заведение.
        if type == "new_shop" || type == "shop_reopened", !orgSlug.isEmpty {
            return { nav.openOrg(slug: orgSlug) }
        }
        // Push продавцу (владелец вошёл тем же аккаунтом) — заказ не его как
        // покупателя: просто открываем приложение.
        if isSellerSide(type, userInfo) { return nil }
        // А79: посылка (accepted, arrived, picked, delivered, failed, released,
        // expired, cancelled) — карточка посылки в профиле («Мои посылки»).
        // А101: event no_courier_yet («Курьера пока нет» за 30 мин до забора) и любой будущий
        // event — так же: баннер с текстом сервера, тап — карточка; открытая — перечитывается.
        if let pid = parcelId(userInfo) {
            return {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    nav.profileOpen = true
                    ProfilePushIntent.open(.parcel(pid))
                }
            }
        }
        // А97: решение по заявке курьера (pool_account + event approve|reject) — сервер шлёт его
        // в клиентское приложение, если приложения курьера нет. Тап — «Профиль → Стать курьером».
        // А98 (П-50 №2): так же event block|unblock — экран перечитает статус («заблокирован» / «вы курьер»).
        // Другие и будущие event — тот же экран: он лишь перечитывает статус, вреда нет (как в А97).
        if type == "pool_account" {
            return {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    nav.profileOpen = true
                    ProfilePushIntent.open(.courier)
                }
            }
        }
        if type == "order_chat", let id = orderId, id > 0 {
            // Открытые корзина/«Жильё» не дали бы показать чат — сначала закрываем.
            return { nav.revealForPush(closeAll: false) { nav.openChat(orderId: id) } }
        }
        if let id = orderId, id > 0 {
            return {
                // Вышли из аккаунта, а push о заказе пришёл: раньше открывалась
                // деталь заказа без входа — «Сессия истекла» вместо экрана. Ведём
                // на вкладку «Заказы»: там «Войдите в аккаунт» с кнопкой входа.
                // Иначе OrdersView наблюдает pendingOrderDetail и открывает деталь;
                // окна поверх вкладок закрываем, чтобы вкладка не сменилась под ними.
                let logged = Session.shared.isLoggedIn
                nav.revealForPush(closeAll: true) {
                    if logged { nav.pendingOrderDetail = id } else { DeepLinkRouter.shared.requestedTab = 3 }
                }
            }
        }
        if type.isEmpty, let pid = productId, pid > 0 {
            // П-21.1: товар подешевел / снова в наличии — карточка товара на Главной.
            return {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    nav.pendingProductId = pid
                }
            }
        }
        // А102: ответ поддержки с номером обращения — сразу его переписка (профиль →
        // SupportTicketView). Гость — профиль с «Войти», как у посылок (consumePushIntent).
        if let tid = ticketId(userInfo) {
            return {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    nav.profileOpen = true
                    ProfilePushIntent.open(.ticket(tid))
                }
            }
        }
        // П-21.1: кошелёк (screen=wallet) и ответ поддержки (type=support) — оба
        // раздела в профиле (А102: support без ticket_id — «Поддержка», как раньше).
        // Волна 4313: «баллы сгорают» (bonus_expiring, только
        // type) — «Бонусы» тоже в профиле; раньше тап просто открывал приложение.
        if screen == "wallet" || type == "support" || type == "bonus_expiring" {
            // Волна 4313: сразу нужный раздел профиля (его открывает ProfileView).
            let part: ProfilePushIntent.Screen = screen == "wallet" ? .wallet
                : (type == "support" ? .support : .bonuses)
            return {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    nav.profileOpen = true
                    ProfilePushIntent.open(part)
                }
            }
        }
        // Волна 4313: «вы кое-что забыли в корзине» (abandoned_cart, только type) —
        // вкладка «Корзина»; раньше тап просто открывал приложение.
        if type == "abandoned_cart" {
            return { nav.revealForPush(closeAll: true) { DeepLinkRouter.shared.requestedTab = 2 } }
        }
        if screen == "trips" {
            // П-21.1: бронь жилья (screen=trips + booking_id) — раздел «Жильё»,
            // оттуда «Мои поездки».
            // Волна 4313: сразу «Мои поездки» (их открывает LodgingSearchView).
            return {
                nav.revealForPush(closeAll: true) {
                    LodgingPushIntent.openTrips()
                    nav.openLodging()
                }
            }
        }
        if let a = adId, a > 0 {
            // П-21.1: объявление истекает/заблокировано — вкладка «Объявления».
            // Волна 4313: объявление своё — сразу «Мои» (их открывает AdsBoardView).
            return {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 4
                    AdsPushIntent.openMyAds()
                }
            }
        }
        return nil
    }

    /// Толерантно достаёт Int из payload (сервер шлёт order_id строкой).
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let s = v as? String { return Int(s) }
        return nil
    }
}
