import SwiftUI

//
//  PurchasesModels.swift — «Профиль → Покупки» (П-84): модели и чистая логика.
//  Канон: ОТВЕТЫ-САЙТА.md «ответ на П-84». Декодер проекта — convertFromSnakeCase:
//  поля camelCase, всё необязательное (старый сервер полей не шлёт), числа приходят
//  строками ("0.00", "0.000") — разбор толерантный, деньги — Decimal.
//

/// Строка, которую сервер может прислать и строкой, и числом (ФН, ФПД, РН ККТ).
@propertyWrapper
struct PurchaseText: Codable, Hashable {
    var wrappedValue: String?
    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let s = try? c.decode(String.self) { wrappedValue = s }
        else if let i = try? c.decode(Int.self) { wrappedValue = String(i) }
        else if let d = try? c.decode(Double.self) { wrappedValue = d.isFinite ? String(d) : nil }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: PurchaseText.Type, forKey key: Key) throws -> PurchaseText {
        (try? decodeIfPresent(type, forKey: key)) ?? PurchaseText(wrappedValue: nil)
    }
}

struct PurchaseShop: Codable, Hashable {
    @LenientInt var id: Int?
    var name: String?
    var slug: String?
    var logo: String?
}

struct PurchaseItem: Codable, Hashable {
    @LenientInt var id: Int?
    @LenientInt var productId: Int?
    var name: String?
    @LenientDecimal var qty: Decimal?
    var unit: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var total: Decimal?
    var modifiersLabel: String?
    @LenientDecimal var discount: Decimal?
    @LenientDecimal var returnQty: Decimal?
}

struct PurchaseDiscount: Codable, Hashable {
    var kind: String?
    var name: String?
    @LenientDecimal var amount: Decimal?
}

struct PurchaseBonus: Codable, Hashable {
    @LenientDecimal var earned: Decimal?
    @LenientDecimal var spent: Decimal?
    @LenientDecimal var clawed: Decimal?
}

struct PurchasePayment: Codable, Hashable {
    var method: String?
    var title: String?
    @LenientDecimal var amount: Decimal?
}

/// Фискальные реквизиты чека (кассовый чек / чек возврата).
struct PurchaseFiscal: Codable, Hashable {
    @PurchaseText var kktRn: String?
    @PurchaseText var fn: String?
    @LenientInt var fd: Int?
    @PurchaseText var fpd: String?
    /// "YYYY-MM-DDTHH:MM:SS"
    var datetime: String?
    @LenientInt var n: Int?
    @LenientDecimal var sum: Decimal?
}

struct PurchaseReturn: Codable, Hashable {
    @LenientInt var id: Int?
    var type: String?
    var status: String?
    @LenientDecimal var amount: Decimal?
    var createdAt: String?
    var fiscal: PurchaseFiscal?
    var receiptQr: String?
}

/// Покупка: строка списка (первые поля) и карточка (остальные; в списке их нет — nil).
struct Purchase: Decodable {
    @LenientInt var id: Int?
    @LenientInt var number: Int?
    var channel: String?
    var shop: PurchaseShop?
    var createdAt: String?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var bonusEarned: Decimal?
    @LenientDecimal var bonusSpent: Decimal?
    @LenientDecimal var refundTotal: Decimal?
    @LenientInt var itemsCount: Int?
    var paymentMethod: String?
    var paymentMethodTitle: String?
    var status: String?
    var statusTitle: String?
    @LenientBool var refunded: Bool?
    // ── только карточка ──
    @LenientDecimal var subtotal: Decimal?
    @LenientDecimal var discountTotal: Decimal?
    @LossyList var items: [PurchaseItem]?
    @LossyList var discounts: [PurchaseDiscount]?
    var bonus: PurchaseBonus?
    @LossyList var payments: [PurchasePayment]?
    var fiscal: PurchaseFiscal?
    var receiptQr: String?
    var ofdUrl: String?
    @LossyList var returns: [PurchaseReturn]?
    @LenientBool var canRepeat: Bool?
    @LenientBool var canReview: Bool?
    @LenientBool var hasReview: Bool?
    @LenientInt var reviewId: Int?

    var rowId: Int { id ?? 0 }
}

/// POST api/v1/profile/purchases/claim → {purchase}. id на верхнем уровне — запасной путь.
struct PurchaseClaimResponse: Decodable {
    var purchase: Purchase?
    @LenientInt var id: Int?
}

/// Тело «Добавить чек» (уйдёт как {"qr": "..."}).
struct PurchaseClaimBody: Encodable { let qr: String }

/// Тело PUT api/v1/profile {e_receipts} (convertToSnakeCase: eReceipts → e_receipts).
struct EReceiptsBody: Encodable { let eReceipts: Bool }

enum PurchaseChannel: String, CaseIterable, Hashable {
    case store, online, all
    var title: String {
        switch self {
        case .store: return "В магазине"
        case .online: return "Онлайн"
        case .all: return "Все"
        }
    }
}

// MARK: - Чистая логика

/// Разовая подсказка для карточки покупки («Чек добавлен»): карточка забирает её один раз.
enum PurchaseFlash {
    static var text: String?
    static func take() -> String? {
        let t = text
        text = nil
        return t
    }
}

enum PurchasesLogic {
    /// Слияние страниц: новые в конец, дубли по id отбрасываются, порядок сервера сохраняется.
    static func merge(_ current: [Purchase], _ incoming: [Purchase]) -> [Purchase] {
        var seen = Set<Int>()
        var out: [Purchase] = []
        for x in current + incoming where x.rowId > 0 && seen.insert(x.rowId).inserted { out.append(x) }
        return out
    }

    /// Локальная проверка QR кассового чека: есть t, s, fn, i, fp, n (значения не пустые).
    /// Строка уходит на сервер как есть — здесь только отсев чужих QR до запроса.
    static func isReceiptQr(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.count > 500 { return false }
        var found = Set<String>()
        for part in s.split(separator: "&", omittingEmptySubsequences: false) {
            let kv = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            // Часть без «ключ=» — не QR чека (как на Android); ключи без учёта регистра.
            guard kv.count == 2, !kv[0].isEmpty else { return false }
            if !kv[1].isEmpty { found.insert(String(kv[0]).lowercased()) }
        }
        return ["t", "s", "fn", "i", "fp", "n"].allSatisfy { found.contains($0) }
    }

    /// "2026-11-17 14:05:09" / "2026-11-17T14:05:09" → "17.11.2026, 14:05". Не разобралось — как пришло.
    static func whenLabel(_ raw: String?) -> String {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "" }
        var day: String?
        if let r = s.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let p = s[r].split(separator: "-")
            if p.count == 3 { day = "\(p[2]).\(p[1]).\(p[0])" }
        }
        let time = s.range(of: #"\d{2}:\d{2}"#, options: .regularExpression).map { String(s[$0]) }
        let joined = [day, time].compactMap { $0 }.joined(separator: ", ")
        return joined.isEmpty ? s : joined
    }

    /// Округление Decimal (своё: `Decimal.rounded(_:)` в MoneyFormat.swift — private, из этого файла недоступно).
    private static func roundDec(_ d: Decimal, _ scale: Int) -> Decimal {
        var src = d, out = Decimal()
        NSDecimalRound(&out, &src, scale, .plain)
        return out
    }

    /// Баллы: целые без дроби, дробные с запятой («1,5»).
    static func points(_ d: Decimal) -> String {
        let v = roundDec(d, 2)
        let whole = roundDec(v, 0)
        if v == whole { return "\((whole as NSDecimalNumber).intValue)" }
        return "\(v)".replacingOccurrences(of: ".", with: ",")
    }

    /// Количество «2.000» → «2», «0.350» → «0,35»; с единицей: «0,35 кг».
    static func qtyLabel(_ q: Decimal?, unit: String?) -> String {
        guard let q = q else { return "" }
        let n = "\(q)".replacingOccurrences(of: ".", with: ",")
        let u = (unit ?? "").trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? n : "\(n) \(u)"
    }

    /// Секунды ожидания (details.retry_after) → «через N мин».
    static func retryText(_ raw: String?) -> String {
        guard let s = raw, let sec = Double(s), sec > 0 else { return "" }
        let min = Int((sec / 60).rounded(.up))
        return min <= 1 ? "Попробуйте через минуту." : "Попробуйте через \(min) мин."
    }

    /// Только https-ссылка на чек ОФД.
    static func httpsURL(_ raw: String?) -> URL? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), s.lowercased().hasPrefix("https://"),
              let u = URL(string: s), u.host != nil else { return nil }
        return u
    }
}
