import Foundation

//  ShoppingListModels.swift
//  «Купить снова» и списки покупок (ответ сайта на П-83, пп. 3 и 10).
//  Декодер клиента — convertFromSnakeCase: свойства camelCase. Всё необязательное, числа-строки
//  ("0.00", "0.000") и флаги 0/1 разбираются терпимо; деньги — Decimal.

/// GET /api/v1/buy-again[?shop_id] → data[] (до 50; только доступное к заказу).
struct BuyAgainItem: Decodable, Identifiable, Hashable {
    @LenientInt var productId: Int?
    let name: String?
    let photo: String?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var oldPrice: Decimal?
    let unit: String?
    @LenientBool var available: Bool?
    @LenientInt var times: Int?
    let lastAt: String?
    @LenientInt var shopId: Int?
    let shopName: String?
    let shopSlug: String?
    @LenientBool var qtyFractional: Bool?
    @LenientDouble var qtyStep: Double?

    var id: String { "\(shopId ?? 0)-\(productId ?? 0)" }
}

struct ShoppingListShop: Decodable, Hashable {
    @LenientInt var id: Int?
    let name: String?
    let slug: String?
}

/// Строка GET /api/v1/shopping-lists.
struct ShoppingListSummary: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let shop: ShoppingListShop?
    @LenientInt var itemsCount: Int?
    let updatedAt: String?
}

/// Добавка позиции (items[].modifiers, с 16.11): только заказываемые сейчас; price — "0.00".
struct ShoppingListModifier: Codable, Hashable {
    @LenientInt var id: Int?
    let name: String?
    @LenientDecimal var price: Decimal?
}

/// Позиция списка. price — "0.00" (сейчас), qty — "0.000".
/// unitPrice / modifiers / modifiersLabel — с 16.11; старый сервер их не шлёт (nil).
struct ShoppingListItem: Codable, Hashable {
    @LenientInt var productId: Int?
    let name: String?
    let photo: String?
    @LenientDecimal var price: Decimal?
    @LenientDouble var qty: Double?
    @LenientBool var available: Bool?
    let modifierIds: [Int]?
    let unit: String?
    @LenientBool var qtyFractional: Bool?
    @LenientDouble var qtyStep: Double?
    @LenientDecimal var unitPrice: Decimal?
    @LossyList var modifiers: [ShoppingListModifier]?
    let modifiersLabel: String?
}

/// Карточка списка: ответ GET /{id}, POST, PUT, from-order.
struct ShoppingListCard: Decodable, Identifiable {
    let id: Int
    let name: String?
    let shop: ShoppingListShop?
    @LenientInt var itemsCount: Int?
    let updatedAt: String?
    @LossyList var items: [ShoppingListItem]?
}

// MARK: - Тела запросов (кодер — convertToSnakeCase: productId → product_id и т.д.)

struct ShoppingListItemBody: Encodable {
    let productId: Int
    let qty: Double
    let modifierIds: [Int]
}

struct ShoppingListCreateBody: Encodable {
    let shopId: Int
    let name: String
    let items: [ShoppingListItemBody]
}

/// PUT: name и/или items (items — замена целиком). nil в тело не попадает — сервер поле не трогает.
struct ShoppingListUpdateBody: Encodable {
    let name: String?
    let items: [ShoppingListItemBody]?
}

struct ShoppingListFromOrderBody: Encodable {
    let name: String?
}
