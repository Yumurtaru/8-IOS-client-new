import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// Spotlight: заведения и товары, которые человек открывал, и его заказы.
/// В индекс попадают только название и короткая подпись: без сумм и телефонов.
/// Открытие из поиска iOS приходит как NSUserActivity (CSSearchableItemActionType),
/// разбор — handle(activity:). При выходе из аккаунта индекс стирается целиком.
enum SpotlightIndex {
    /// Тип активности, который присылает iOS при открытии результата из Spotlight.
    static let activityType = CSSearchableItemActionType

    private static let domainOrg = "ru.marketplace.client.premium.org"
    private static let domainProduct = "ru.marketplace.client.premium.product"
    private static let domainOrder = "ru.marketplace.client.premium.order"
    private static let ttl: TimeInterval = 60 * 60 * 24 * 60   // 60 дней

    // MARK: - Индексация

    /// Заведение, которое человек открыл.
    static func indexOrg(slug: String?, name: String?, about: String?) {
        guard let slug = slug, !slug.isEmpty, let name = name, !name.isEmpty else { return }
        let text = (about ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = text.isEmpty ? "Заведение в Yumurta" : String(text.prefix(120))
        add(id: "org:\(slug)", domain: domainOrg, title: name, subtitle: sub)
    }

    /// Товар, который человек открыл.
    static func indexProduct(id: Int, name: String?, shopName: String?) {
        guard let name = name, !name.isEmpty else { return }
        let shop = (shopName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sub = shop.isEmpty ? "Товар в Yumurta" : "Товар · \(shop)"
        add(id: "product:\(id)", domain: domainProduct, title: name, subtitle: sub)
    }

    /// Заказы человека (последние 20): «Заказ №12 · Название заведения».
    static func indexOrders(_ orders: [Order]) {
        let items = orders.prefix(20).map { o -> CSSearchableItem in
            let number = o.dailyNumber ?? o.id
            let shop = (o.shopName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let title = shop.isEmpty ? "Заказ №\(number)" : "Заказ №\(number) · \(shop)"
            return makeItem(id: "order:\(o.id)", domain: domainOrder, title: title, subtitle: "Заказ в Yumurta")
        }
        guard !items.isEmpty else { return }
        CSSearchableIndex.default().indexSearchableItems(Array(items)) { _ in }
    }

    /// Выход из аккаунта: стираем весь индекс приложения.
    static func clearAll() {
        CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainOrg, domainProduct, domainOrder]) { _ in }
    }

    // MARK: - Открытие из Spotlight

    /// Маршрут по активности Spotlight; nil — не наша.
    static func route(for activity: NSUserActivity) -> AppRoute? {
        guard let key = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return nil }
        if key.hasPrefix("org:") {
            let slug = String(key.dropFirst(4))
            return slug.isEmpty ? nil : AppRoute.org(slug: slug)
        }
        if key.hasPrefix("product:"), let id = Int(key.dropFirst(8)), id > 0 { return AppRoute.product(id) }
        if key.hasPrefix("order:"), let id = Int(key.dropFirst(6)), id > 0 { return AppRoute.order(id) }
        return nil
    }

    /// Открыть экран по результату Spotlight.
    static func handle(activity: NSUserActivity) {
        if let r = route(for: activity) { AppRoute.perform(r) }
    }

    // MARK: - Внутреннее

    private static func makeItem(id: String, domain: String, title: String, subtitle: String) -> CSSearchableItem {
        let attrs = CSSearchableItemAttributeSet(contentType: UTType.content)
        attrs.title = title
        attrs.contentDescription = subtitle
        let item = CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attrs)
        item.expirationDate = Date(timeIntervalSinceNow: ttl)
        return item
    }

    private static func add(id: String, domain: String, title: String, subtitle: String) {
        let item = makeItem(id: id, domain: domain, title: title, subtitle: subtitle)
        CSSearchableIndex.default().indexSearchableItems([item]) { _ in }
    }
}
