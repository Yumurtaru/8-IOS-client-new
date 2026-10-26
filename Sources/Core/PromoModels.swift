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

struct PromoGift: Codable, Identifiable {
    let productId: Int?
    let name: String?
    let qty: Double?
    let price: Double?
    var id: String { "\(productId ?? 0)-\(name ?? "")" }
}

struct AppliedPromo: Codable, Identifiable {
    let id: Int
    let name: String
    let description: String?
    let discount: Double?
    let points: Double?
    let freeDelivery: Bool?
    let gifts: [PromoGift]?
}

struct PromoPreview: Codable {
    let applied: [AppliedPromo]?
    let discount: Double?
    let freeDelivery: Bool?
    let gifts: [PromoGift]?
    let pointsEarned: Double?
    let pointsSpendMax: Double?
    let pointsSpent: Double?
    let subtotal: Double?
    let deliveryPrice: Double?
    let total: Double?
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
    let id: Int?
    let price: Double?
}
struct CartValidateLine: Decodable {
    let row: Int?
    let productId: Int?
    let basePrice: Double?
    let linePrice: Double?
    let qty: Double?
    let modifiers: [CartValidateMod]?
    let available: Bool?
}
struct CartValidateResult: Decodable {
    let items: [CartValidateLine]?
    let subtotal: Double?
    let hasIssues: Bool?
}
