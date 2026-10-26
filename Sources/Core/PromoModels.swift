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
