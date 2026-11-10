import Foundation

/* ============================================================================
 *  PromoModels.swift — модели движка акций и баллов (аддитивно).
 *  ВАЖНО: API.shared использует keyEncodingStrategy = .convertToSnakeCase и
 *  keyDecodingStrategy = .convertFromSnakeCase. Поэтому здесь НЕ задаём явные
 *  CodingKeys — имена свойств в camelCase автоматически маппятся на snake_case
 *  сервера (spendPoints ↔ spend_points, freeDelivery ↔ free_delivery и т.д.).
 *
 *  POST /api/v1/cart/promo-preview  → PromoPreview
 *  Ответ POST /api/v1/orders дополнен полями promotions/gifts/points*.
 * ========================================================================== */

struct PromoCartItem: Encodable {
    let productId: Int
    let qty: Double
    let modifiers: [Int]
}

struct PromoPreviewRequest: Encodable {
    let shopId: Int
    let items: [PromoCartItem]
    let deliveryType: String
    let deliveryPrice: Double
    let promoCode: String?
    let spendPoints: Double
    // Тумблер «оплатить баллами» (spend_points_all): сервер сам спишет min(баланс, потолок).
    var spendPointsAll: Bool = false
}

// Числа и флаги — через @Lenient*: сервер отдаёт DECIMAL строками ("0.00"), флаги 0/1.
struct PromoGift: Codable, Identifiable {
    @LenientInt var productId: Int?
    let name: String?
    @LenientDouble var qty: Double?
    @LenientDouble var price: Double?
    var id: String { "\(productId ?? 0)-\(name ?? "")" }
}

struct AppliedPromo: Codable, Identifiable {
    let id: Int
    /// Нет названия в ответе — безопасная подпись вместо падения разбора.
    let name: String
    let description: String?
    @LenientDouble var discount: Double?
    @LenientDouble var points: Double?
    @LenientBool var freeDelivery: Bool?
    let gifts: [PromoGift]?

    enum CodingKeys: String, CodingKey {
        case id, name, description, discount, points, freeDelivery, gifts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try c.decode(LenientInt.self, forKey: .id)).wrappedValue ?? 0
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Акция"
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        _discount = try c.decode(LenientDouble.self, forKey: .discount)
        _points = try c.decode(LenientDouble.self, forKey: .points)
        _freeDelivery = try c.decode(LenientBool.self, forKey: .freeDelivery)
        gifts = try? c.decodeIfPresent([PromoGift].self, forKey: .gifts)
    }
}

struct PromoPreview: Codable {
    let applied: [AppliedPromo]?
    @LenientDouble var discount: Double?
    @LenientBool var freeDelivery: Bool?
    let gifts: [PromoGift]?
    @LenientDouble var pointsEarned: Double?
    @LenientDouble var pointsSpendMax: Double?
    @LenientDouble var pointsSpent: Double?
    @LenientDouble var subtotal: Double?
    @LenientDouble var deliveryPrice: Double?
    @LenientDouble var total: Double?
    /// А113: в корзине есть строки, которые нельзя заказать (нет в наличии,
    /// добавки недоступны) — subtotal тогда без них. Старый сервер — nil.
    @LenientBool var cartHasIssues: Bool?
    /// А719: чем доставка стала бесплатной — "plus" | "code" | nil. Нет поля — старый сервер.
    let deliveryFreeBy: String?
    /// O1: подсказки «до опта осталось немного» (показывать только near == true).
    @LossyList var wholesaleHints: [WholesaleHint]?
}

/* AT-2: POST /api/cart/validate (routes/cart.php → cartRecompute, конверт сайта
 * {ok,data}). Строки ответа — с номером строки запроса (row): один товар бывает
 * в корзине несколькими строками с разными добавками. Цены — по базе магазина
 * на сейчас; linePrice — цена единицы вместе с добавками. */
struct CartValidateBody: Encodable {
    let shopId: Int
    let items: [PromoCartItem]
}
struct CartValidateMod: Decodable {
    @LenientInt var id: Int?
    @LenientDouble var price: Double?
}
struct CartValidateLine: Decodable {
    @LenientInt var row: Int?
    @LenientInt var productId: Int?
    @LenientDouble var basePrice: Double?
    @LenientDouble var linePrice: Double?
    @LenientDouble var qty: Double?
    let modifiers: [CartValidateMod]?
    @LenientBool var available: Bool?
    /// O1: строка по оптовой цене; linePrice уже по опту, retailLinePrice — розница единицы с добавками.
    @LenientBool var wholesale: Bool?
    @LenientDouble var tierMinQty: Double?
    @LenientDouble var retailLinePrice: Double?
}
struct CartValidateResult: Decodable {
    let items: [CartValidateLine]?
    @LenientDouble var subtotal: Double?
    @LenientBool var hasIssues: Bool?
    @LossyList var wholesaleHints: [WholesaleHint]?
}
