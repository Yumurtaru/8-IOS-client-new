import Foundation
import os

/// Лёгкий фасад аналитики. Единая точка для событий — сейчас пишет в unified log,
/// позже сюда можно подключить реальный провайдер (Firebase/AppMetrica/свой endpoint),
/// не трогая места вызова. Не влияет на API-контракт — чисто клиентская телеметрия.
enum Track {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ru.marketplace.client",
                                    category: "analytics")

    /// Общий примитив логирования события.
    static func event(_ name: String, _ params: [String: Any] = [:]) {
        #if DEBUG
        let payload = params.map { "\($0)=\($1)" }.sorted().joined(separator: " ")
        log.debug("event=\(name, privacy: .public) \(payload, privacy: .public)")
        #endif
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
}
