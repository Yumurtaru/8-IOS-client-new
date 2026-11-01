import Foundation

/// Чем доставка стала бесплатной в предпросмотре корзины (сервер А719,
/// POST /api/v1/cart/promo-preview → delivery_free_by: "plus" | "code" | null).
/// Сервер обнуляет доставку при Plus и при промокоде на бесплатную доставку — как заказ,
/// поэтому итог на экране должен считать доставку нулевой. Нет поля / неизвестное значение → nil.
/// Паритет с Android (core/DeliveryFree.kt).
enum DeliveryFree {
    /// "plus" | "code" → нормализованное значение; остальное → nil.
    static func by(_ raw: String?) -> String? {
        switch raw?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "plus": return "plus"
        case "code": return "code"
        default: return nil
        }
    }

    /// Подпись строки «Доставка»; nil — подписи нет (оставляем прежнюю).
    static func label(_ raw: String?) -> String? {
        switch by(raw) {
        case "plus": return "Бесплатно — Plus"
        case "code": return "Бесплатно по промокоду"
        default: return nil
        }
    }
}
