import Foundation

/*
 П-72 п.2: сохранённые карты и выбор способа оплаты (ЮKassa).
   GET    api/v1/payment-methods              -> [{id, type, title "Visa •• 4242", expiry "12/28"|null, is_default}]
   DELETE api/v1/payment-methods/{id}         -> {deleted:true}
   POST   api/v1/payment-methods/{id}/default -> {default_id}
 POST api/v1/wallet/topup: method (sbp|sberbank|tinkoff_bank|bank_card), save_card,
 payment_method_id, return_url "yumurta://pay/return".
 Ответ: status "confirmed" + balance — успех сразу; "pending" — опрос GET wallet/topup/{id};
 confirmation_url — страница оплаты (3-D Secure и обычный путь).
 Ошибки 409 saved_method_failed / duplicate_payment — текст сервера (error.message).
*/

struct SavedPayMethod: Codable, Identifiable, Hashable {
    @LenientInt var id: Int?
    let type: String?
    let title: String?
    let expiry: String?
    @LenientBool var isDefault: Bool?

    var methodId: Int { id ?? 0 }
    var displayTitle: String { (title?.isEmpty == false ? title! : "Карта") }
}

/// Способ оплаты нового платежа: значение поля `method`.
enum TopupMethod: String, CaseIterable, Identifiable {
    case sbp = "sbp"
    case sberpay = "sberbank"
    case tpay = "tinkoff_bank"
    case card = "bank_card"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sbp: return "СБП"
        case .sberpay: return "SberPay"
        case .tpay: return "T-Pay"
        case .card: return "Банковская карта"
        }
    }
}

/// Что выбрал человек в листе пополнения.
struct TopupChoice {
    let amount: Decimal
    let method: TopupMethod
    let saveCard: Bool
    /// Наш id сохранённого способа (автоплатёж) или nil.
    let savedId: Int?
}

enum PayReturn {
    static let url = "yumurta://pay/return"
}
