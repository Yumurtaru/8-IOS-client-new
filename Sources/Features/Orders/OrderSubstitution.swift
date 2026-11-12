import SwiftUI

//
//  OrderSubstitution.swift — замены товаров при сборке (П-72 п.4).
//
//  Контракт (ОТВЕТЫ-САЙТА «ответ на П-72 п.4»), декодер клиента — convertFromSnakeCase:
//   • GET api/v1/orders/{id}: substitution_default, substitution_deadline_at,
//     substitution_timeout_min, items[].substitution, items[].comment,
//     items[].substitute {product_id, name, photo, qty:"2.000", price:"60.00", sum:"120.00",
//     status: pending|accepted|declined|auto, outcome: replaced|removed|null, deadline_at,
//     needs_call, original:{name, qty, price}}, substitutions[] (+ item_id);
//   • POST api/v1/orders/{id}/items/{item_id}/substitute {accept: bool} →
//     {item_id, substitute, total, refund_due, items, substitution_deadline_at};
//     404, 409 already_decided, 422 (would_empty).
//  Все поля необязательные: старый сервер их не знает, число-строка и число читаются одинаково.
//

/// Строка, которую сервер иногда шлёт числом (substitution_default на сайте — целое).
/// Число/булево превращаем в текст, чтобы поле не роняло разбор всего заказа.
@propertyWrapper
struct LenientText: Codable, Hashable {
    var wrappedValue: String?
    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let s = try? c.decode(String.self) { wrappedValue = s }
        else if let i = try? c.decode(Int.self) { wrappedValue = String(i) }
        else if let d = try? c.decode(Double.self) { wrappedValue = String(d) }
        else if let b = try? c.decode(Bool.self) { wrappedValue = b ? "1" : "0" }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: LenientText.Type, forKey key: Key) throws -> LenientText {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientText(wrappedValue: nil)
    }
}

/// Вложенный объект, который не должен ронять весь заказ: не тот тип (PHP `[]` вместо
/// null) или битое содержимое дают nil.
@propertyWrapper
struct LenientObject<T: Codable>: Codable {
    var wrappedValue: T?
    init(wrappedValue: T?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        wrappedValue = try? T(from: decoder)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Список вложенных объектов: битый элемент пропускается, не-массив даёт nil.
@propertyWrapper
struct LenientList<T: Codable>: Codable {
    var wrappedValue: [T]?
    init(wrappedValue: [T]?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        if let arr = try? [LossyElement<T>](from: decoder) { wrappedValue = arr.compactMap { $0.value } }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: LenientObject<T>.Type, forKey key: Key) throws -> LenientObject<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientObject(wrappedValue: nil)
    }
    func decode<T>(_ type: LenientList<T>.Type, forKey key: Key) throws -> LenientList<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientList(wrappedValue: nil)
    }
}

/// Исходная строка, которую заменяют.
struct OrderSubstituteOriginal: Codable, Hashable {
    @LenientText var name: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
}

/// Замена, предложенная магазином (или принятая / автозамена).
struct OrderSubstitute: Codable, Identifiable {
    @LenientInt var itemId: Int?
    @LenientInt var productId: Int?
    @LenientText var name: String?
    @LenientText var photo: String?
    @LenientDecimal var qty: Decimal?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var sum: Decimal?
    /// pending | accepted | declined | auto
    @LenientText var status: String?
    /// replaced | removed | nil
    @LenientText var outcome: String?
    @LenientText var deadlineAt: String?
    @LenientBool var needsCall: Bool?
    @LenientObject var original: OrderSubstituteOriginal?

    var id: Int { itemId ?? ((productId ?? 0) &* 31) }
    var isPending: Bool { status == "pending" }
    var isRemoved: Bool { outcome == "removed" }
    var isReplaced: Bool { outcome == "replaced" || status == "accepted" || status == "auto" }

    /// Дедлайн ответа: "YYYY-MM-DD HH:MM:SS" по Москве или ISO-8601 со смещением.
    var deadline: Date? { OrderSubstitute.parseDate(deadlineAt) }

    static func parseDate(_ s: String?) -> Date? {
        guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return d }
        }
        return nil
    }
}

/// Ответ POST …/items/{item_id}/substitute.
struct SubstituteReply: Decodable {
    @LenientInt var itemId: Int?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var refundDue: Decimal?
    @LenientText var substitutionDeadlineAt: String?
}

enum OrderSubstitutionAPI {
    /// Ответ клиента. Bool уходит настоящим JSON-true/false (postJSON), а не строкой.
    static func answer(orderId: Int, itemId: Int, accept: Bool) async throws -> SubstituteReply {
        try await API.shared.postJSON("api/v1/orders/\(orderId)/items/\(itemId)/substitute", json: ["accept": accept])
    }
}

/// Оставшееся время до дедлайна: «4 мин 12 с».
enum SubstituteTimer {
    static func text(until deadline: Date, now: Date) -> String? {
        let left = Int(deadline.timeIntervalSince(now).rounded(.up))
        guard left > 0 else { return nil }
        return left >= 60 ? "\(left / 60) мин \(left % 60) с" : "\(left) с"
    }
}

/// Карточки замен в заказе: «Нет в наличии: …», таймер, «Принять» / «Отказаться»;
/// принятые и автозамены — строкой «Замена: было …». onChanged — перечитать заказ.
struct OrderSubstitutionsSection: View {
    let order: OrderDetail
    let orderId: Int
    var onChanged: () async -> Void

    @State private var busyItem: Int?
    @State private var errorText: String?
    @State private var refundNote: [Int: Decimal] = [:]

    /// Все замены заказа: общий список или из строк (что есть, то и берём).
    private var all: [OrderSubstitute] {
        var out: [OrderSubstitute] = order.substitutions ?? []
        for it in order.items ?? [] {
            guard var s = it.substitute else { continue }
            if s.itemId == nil { s.itemId = it.lineId }
            if !out.contains(where: { $0.itemId == s.itemId && $0.productId == s.productId }) { out.append(s) }
        }
        return out
    }

    var body: some View {
        let list = all.filter { $0.isPending || ($0.needsCall == true && !$0.isReplaced && !$0.isRemoved) }
        if !list.isEmpty || errorText != nil {
            // Таймер тикает раз в секунду только пока есть что подтверждать.
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: YMSpace.md) {
                    ForEach(list) { s in card(s, now: ctx.date) }
                    if let e = errorText {
                        Text(e).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func card(_ s: OrderSubstitute, now: Date) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Нет в наличии: \(s.original?.name ?? "товар")")
                .font(YMFont.headline).foregroundStyle(YMColor.text)
            if s.needsCall == true {
                Text("Продавец позвонит вам").font(YMFont.callout).foregroundStyle(YMColor.accent)
            }
            if s.isPending, !s.isRemoved, let name = s.name, !name.isEmpty {
                Text("Замена: \(name) × \(qtyText(s.qty)) — \(Money.format(s.sum ?? ((s.price ?? 0) * (s.qty ?? 1))))")
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                if let d = s.deadline {
                    if let left = SubstituteTimer.text(until: d, now: now) {
                        Text("Ответьте за \(left)").font(YMFont.caption).foregroundStyle(YMColor.muted)
                    } else {
                        Text("Время на ответ вышло — применим ваш выбор «Если товара нет»")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                }
                HStack(spacing: YMSpace.md) {
                    Button("Принять") { answer(s, accept: true) }
                        .buttonStyle(YMPrimaryButtonStyle())
                    Button("Отказаться") { answer(s, accept: false) }
                        .buttonStyle(YMSecondaryButtonStyle())
                }
                .disabled(busyItem != nil)
            }
            if let id = s.itemId, let refund = refundNote[id], refund > 0 {
                Text("Разницу \(Money.format(refund)) вернёт продавец")
                    .font(YMFont.callout).foregroundStyle(YMColor.statusDone)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func qtyText(_ q: Decimal?) -> String { "\(q ?? 1)".replacingOccurrences(of: ".", with: ",") }

    private func answer(_ s: OrderSubstitute, accept: Bool) {
        guard let item = s.itemId else { return }
        busyItem = item; errorText = nil
        Task {
            do {
                let r = try await OrderSubstitutionAPI.answer(orderId: orderId, itemId: item, accept: accept)
                await MainActor.run {
                    if let due = r.refundDue, due > 0 { refundNote[item] = due }
                    busyItem = nil
                }
                await onChanged()
            } catch {
                let already = (error as? APIError)?.errorCode == "already_decided"
                await MainActor.run {
                    busyItem = nil
                    // 409: ответ уже есть (например, сработал таймер) — просто перечитываем заказ.
                    errorText = already ? "Выбор уже принят — обновляем заказ"
                        : ((error as? LocalizedError)?.errorDescription ?? "Не удалось отправить ответ")
                }
                await onChanged()
            }
        }
    }
}

/// Строки под позицией состава: комментарий к блюду и «Замена: было …» (принятая / автозамена).
struct OrderItemExtras: View {
    let item: OrderItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let c = item.comment, !c.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Комментарий: \(c)").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            if let s = item.substitute {
                if s.isRemoved {
                    Text("Убрано из заказа: \(s.original?.name ?? "товар") — нет в наличии")
                        .font(YMFont.caption).foregroundStyle(YMColor.accent)
                } else if !s.isPending, s.isReplaced {
                    Text("Замена: было \(s.original?.name ?? "товар")")
                        .font(YMFont.caption).foregroundStyle(YMColor.accent)
                }
            }
        }
    }
}
