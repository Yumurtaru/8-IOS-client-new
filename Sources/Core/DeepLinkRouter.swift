import Combine
import Foundation

/// Связывает Siri/Shortcuts и внешние ссылки (Universal Links / custom scheme) с навигацией.
final class DeepLinkRouter: ObservableObject {
    static let shared = DeepLinkRouter()
    @Published var requestedTab: Int?     // 0 главная, 2 корзина, 3 заказы
    @Published var referralCode: String?  // код из ссылки .../r/КОД
    private init() {}

    /// Разбирает входящую ссылку:
    ///   https://yumurta.ru/r/КОД   / yumurta://r/КОД      — приглашение
    ///   https://yumurta.ru/shop/СЛАГ / yumurta://shop/СЛАГ — организация
    /// true — ссылку узнали и открыли внутри приложения (сторис по false
    /// открывают её в браузере, чтобы «Подробнее» не молчало).
    @discardableResult
    func handle(url: URL) -> Bool {
        let parts = url.pathComponents.filter { $0 != "/" }
        // Виджеты и Live Activity: yumurta://order/<id>[?repeat=1], yumurta://orders,
        // yumurta://bonuses. Отдельно, чтобы не мешать ссылкам на заведения и коды.
        if url.scheme == "yumurta", let host = url.host, ["order", "orders", "bonuses"].contains(host) {
            return handleOrderWidgetLink(host: host, parts: parts, url: url)
        }
        // Организация: тот же экран, что открывается по тапу на уведомление
        // «новое заведение в городе».
        var shopSlug: String?
        if url.host == "shop", let first = parts.first {                       // yumurta://shop/СЛАГ
            shopSlug = first
        } else if let idx = parts.firstIndex(of: "shop"), idx + 1 < parts.count { // https://.../shop/СЛАГ
            shopSlug = parts[idx + 1]
        }
        // Слаг идёт прямо в путь запроса к API — пускаем только «правильные»
        // (латиница, цифры, дефис). Ссылка из письма или QR с %3F, %2F или
        // пробелом раньше меняла адрес запроса или роняла приложение.
        if let slug = shopSlug, slug.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil {
            DispatchQueue.main.async { NavCoordinator.shared.openOrg(slug: slug) }
            return true
        }
        if shopSlug != nil { return false }
        var code: String?
        if url.host == "r", let first = parts.first {            // yumurta://r/КОД
            code = first
        } else if let idx = parts.firstIndex(of: "r"), idx + 1 < parts.count { // https://.../r/КОД
            code = parts[idx + 1]
        }
        if let code = code, !code.isEmpty {
            let value = code.uppercased()
            DispatchQueue.main.async { self.referralCode = value }
            return true
        }
        return false
    }

    /// Ссылки виджетов: заказ (с повтором или без), список заказов, бонусы.
    private func handleOrderWidgetLink(host: String, parts: [String], url: URL) -> Bool {
        let nav = NavCoordinator.shared
        if host == "bonuses" {
            DispatchQueue.main.async {
                nav.revealForPush(closeAll: true) {
                    DeepLinkRouter.shared.requestedTab = 0
                    nav.profileOpen = true
                    ProfilePushIntent.open(.bonuses)
                }
            }
            return true
        }
        if host == "orders" {
            DispatchQueue.main.async { nav.revealForPush(closeAll: true) { DeepLinkRouter.shared.requestedTab = 3 } }
            return true
        }
        guard let raw = parts.first, let id = Int(raw), id > 0 else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let again = items.contains { $0.name == "repeat" && $0.value == "1" }
        DispatchQueue.main.async { OrderRepeatIntent.open(id, repeatOrder: again) }
        return true
    }
}
