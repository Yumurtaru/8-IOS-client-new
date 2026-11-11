import Foundation
import os

/// Лёгкий фасад аналитики. Единая точка для событий: пишет в unified log (в отладке) и,
/// если в Info.plist задан ключ AppMetricaAPIKey, дублирует события в AppMetrica (Core/Metrica.swift).
/// Не влияет на API-контракт — чисто клиентская телеметрия.
enum Track {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ru.marketplace.client",
                                    category: "analytics")

    /// Общий примитив логирования события.
    static func event(_ name: String, _ params: [String: Any] = [:]) {
        #if DEBUG
        let payload = params.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        log.debug("event=\(name, privacy: .public) \(payload, privacy: .public)")
        #endif
        Metrica.report(name, params)
    }

    /// Товар добавлен в корзину.
    static func addToCart(id: Int, name: String?, price: Double?, qty: Double) {
        event("add_to_cart", [
            "id": id,
            "name": name ?? "",
            "price": price ?? 0,
            "qty": qty
        ])
    }

    // MARK: - Воронка

    /// Открыто заведение.
    static func shopOpened(slug: String, name: String?) {
        event("shop_open", ["slug": slug, "name": name ?? ""])
    }

    /// Открыт товар.
    static func productOpened(id: Int, name: String?) {
        event("product_open", ["id": id, "name": name ?? ""])
    }

    /// Открыто оформление заказа.
    static func checkoutStarted(items: Int) {
        event("checkout_start", ["items": items])
    }

    /// Заказ создан.
    static func orderCreated(id: Int) {
        event("order_created", ["id": id])
    }
}
