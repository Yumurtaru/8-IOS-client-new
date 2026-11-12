import Foundation

//
//  GroupCartModels.swift — «Общий заказ» (П-72 п.3): модели и вызовы API.
//
//  Контракт (ОТВЕТЫ-САЙТА, «п.3 Общий заказ»), декодер клиента — convertFromSnakeCase:
//    POST   api/v1/group-carts {shop_id}              → {code, share_url}
//    GET    api/v1/group-carts/{code}                 → GroupCart
//    POST   api/v1/group-carts/{code}/join            (идемпотентно)
//    PUT    api/v1/group-carts/{code}/items {items:[{product_id, qty, modifiers:[id]}]}
//    POST   api/v1/group-carts/{code}/lock | unlock   (владелец)
//    POST   api/v1/group-carts/{code}/checkout {тело обычного оформления}  (владелец)
//    DELETE api/v1/group-carts/{code}                 → {result: cancelled|left}
//  Всё необязательное и терпимое: qty — число-строка ("2"), деньги — строки "330.00".
//

struct GroupCartCreated: Decodable {
    let code: String?
    let shareUrl: String?
}

struct GroupCartShop: Decodable {
    @LenientInt var id: Int?
    let slug: String?
    let name: String?
    let logo: String?
}

struct GroupCartOwner: Decodable {
    let name: String?
    @LenientBool var isMe: Bool?
}

struct GroupCartModifier: Decodable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    @LenientDecimal var price: Decimal?
    /// Для ForEach: у мусорной записи без id берём имя.
    var rowId: String { "\(id ?? 0)|\(name ?? "")" }
}

struct GroupCartItem: Decodable, Identifiable {
    @LenientInt var productId: Int?
    let name: String?
    /// qty приходит число-строкой ("2", "0.500") — точный Decimal.
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
    let modifiers: [GroupCartModifier]?
    @LenientDecimal var lineTotal: Decimal?
    @LenientBool var available: Bool?

    var modifierIds: [Int] { (modifiers ?? []).compactMap { $0.id } }
    /// Стабильный ключ строки: товар + набор добавок (как ключ строки корзины).
    var key: String { "\(productId ?? 0)-\(modifierIds.sorted().map(String.init).joined(separator: ","))" }
    var id: String { key }
    var isAvailable: Bool { available ?? true }
    var qtyDouble: Double { NSDecimalNumber(decimal: qty ?? 0).doubleValue }
    /// Сумма строки: line_total сервера, иначе цена × количество.
    var sum: Decimal { lineTotal ?? ((price ?? 0) * (qty ?? 0)) }
}

struct GroupCartMember: Decodable, Identifiable {
    @LenientInt var userId: Int?
    let name: String?
    @LenientBool var isMe: Bool?
    let items: [GroupCartItem]?
    @LenientDecimal var subtotal: Decimal?
    var id: String { "\(userId ?? 0)|\(name ?? "")" }
    var itemList: [GroupCartItem] { items ?? [] }
}

struct GroupCart: Decodable {
    let code: String?
    /// open | locked | ordered | cancelled
    let status: String?
    let shop: GroupCartShop?
    let owner: GroupCartOwner?
    let deadlineAt: String?
    let members: [GroupCartMember]?
    @LenientDecimal var total: Decimal?
    /// Номер заказа — только владельцу.
    @LenientInt var orderId: Int?
    @LenientBool var isMember: Bool?
    @LenientInt var memberCount: Int?
    let shareUrl: String?

    var memberList: [GroupCartMember] { members ?? [] }
    var isOwner: Bool { owner?.isMe ?? false }
    var joined: Bool { isMember ?? memberList.contains { $0.isMe ?? false } }
    var isOpen: Bool { status == "open" }
    var isLocked: Bool { status == "locked" }
    /// Заказ оформлен или отменён — править уже нечего.
    var isFinished: Bool { status == "ordered" || status == "cancelled" }
    var me: GroupCartMember? { memberList.first { $0.isMe ?? false } }
}

// ── Тела запросов (кодировщик API — convertToSnakeCase) ──
struct GroupCartCreateBody: Encodable { let shopId: Int }
struct GroupCartLineBody: Encodable {
    let productId: Int
    let qty: Double
    let modifiers: [Int]
}
struct GroupCartItemsBody: Encodable { let items: [GroupCartLineBody] }

/// Тексты ошибок по `error.code` (APIError.errorCode); нет кода — текст сервера.
enum GroupCartText {
    static func message(_ error: Error) -> String {
        if let api = error as? APIError {
            switch api.errorCode {
            case "not_open":   return "Общий заказ уже закрыт для правок"
            case "full":       return "В общем заказе уже максимум участников"
            case "too_many":   return "Слишком много открытых общих заказов — завершите один из них"
            case "wrong_shop": return "В общем заказе другое заведение"
            case "empty":      return "В общем заказе пока нет позиций"
            case "not_owner":  return "Это действие доступно только владельцу"
            case "not_member": return "Вы не участвуете в этом общем заказе"
            case "not_found":  return "Общий заказ не найден или уже удалён"
            case "too_many_items": return "Слишком много позиций в общем заказе"
            case "bad_modifier":   return "Одна из добавок недоступна — обновите корзину"
            default: break
            }
        }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

/// Вызовы API общего заказа.
enum GroupCartAPI {
    private static func path(_ code: String, _ tail: String = "") -> String {
        // Код — 9 символов A-Z2-9; из ссылки/push приходит извне, чужое в путь не пускаем.
        "api/v1/group-carts/\(code)\(tail)"
    }

    /// Допустимый код: латиница/цифры (регистр приводим к верхнему).
    static func clean(_ raw: String) -> String? {
        let c = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard c.range(of: "^[A-Z0-9]{4,20}$", options: .regularExpression) != nil else { return nil }
        return c
    }

    static func create(shopId: Int) async throws -> GroupCartCreated {
        try await API.shared.post("api/v1/group-carts", body: GroupCartCreateBody(shopId: shopId))
    }
    static func get(_ code: String) async throws -> GroupCart {
        try await API.shared.get(path(code), fresh: true)
    }
    static func join(_ code: String) async throws {
        try await API.shared.postVoid(path(code, "/join"))
    }
    static func putItems(_ code: String, lines: [GroupCartLineBody]) async throws {
        _ = try await API.shared.put(path(code, "/items"), body: GroupCartItemsBody(items: lines)) as EmptyResp
    }
    static func lock(_ code: String) async throws { try await API.shared.postVoid(path(code, "/lock")) }
    static func unlock(_ code: String) async throws { try await API.shared.postVoid(path(code, "/unlock")) }
    /// Владелец отменяет, участник выходит (сервер решает по роли).
    static func leaveOrCancel(_ code: String) async throws { try await API.shared.deleteVoid(path(code)) }

    /// Лимиты сервера (как на Android): ≤ 30 строк, qty ≤ 99. Текст ошибки до отправки или nil.
    static func limitError(_ lines: [GroupCartLineBody]) -> String? {
        if lines.count > 30 { return "В общем заказе не больше 30 позиций — уберите лишние из корзины" }
        if lines.contains(where: { $0.qty > 99 }) { return "Количество одной позиции — не больше 99" }
        return nil
    }

    /// Позиции текущей корзины (только если она этого магазина) → тело PUT items.
    static func lines(fromCart cart: Cart, shopId: Int) -> [GroupCartLineBody] {
        guard cart.shopId == shopId else { return [] }
        return cart.lines.map { GroupCartLineBody(productId: $0.productId, qty: $0.qty, modifiers: $0.modifierIds) }
    }
}
