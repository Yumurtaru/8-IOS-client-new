import Foundation

// Редизайн, этап 4 (ТЗ 12.11.2026, раздел 5.4): «+» у товара БЕЗ обязательного выбора кладёт в
// корзину сразу, у товара с выбором (размер, сок, состав набора) — открывает карточку.
//
// Меню заведения признака не отдаёт, поэтому:
//  1) если сервер прислал `has_required_modifiers` (заявка П-75) — берём его;
//  2) иначе спрашиваем карточку товара ТЕМ ЖЕ запросом, что и экран товара
//     (`api/v1/products/{id}`), и запоминаем ответ на время работы приложения;
//  3) ошибка/неясность → nil → открываем карточку (прежнее поведение).
// Паритет с Android: ui/screens/org/QuickAdd.kt.

@MainActor
enum QuickAdd {
    private static var needsCardCache: [Int: (at: Date, needs: Bool)] = [:]
    private static let needsTTL: TimeInterval = 600
    private static var detailCache: [Int: (at: Date, detail: ProductDetail)] = [:]
    private static let detailTTL: TimeInterval = 60

    /// true - нужна карточка; false - можно класть сразу; nil - неизвестно (открыть карточку).
    /// Флаг сервера `true` - быстрый ответ "нужна карточка"; `false` не окончателен (пока сайт не
    /// подтвердил, что флаг учитывает наборы, П-75) - проверяем карточку. Весовой товар - всегда карточка.
    static func needsCard(_ p: Product) async -> Bool? {
        if p.hasRequiredModifiers == true { return true }
        if let c = needsCardCache[p.id], Date().timeIntervalSince(c.at) < needsTTL { return c.needs }
        guard let d = await detail(p.id) else { return nil }
        let presets = (d.qtyPresets ?? "").split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }
        let weighed = (d.qtyFractional ?? 0) == 1 || presets.count >= 2
        let needs = weighed
            || !(d.comboItems ?? []).isEmpty
            || (d.modifierGroups ?? []).contains { $0.isRequired == true || ($0.minQty ?? 0) > 0 }
        needsCardCache[p.id] = (Date(), needs)
        return needs
    }

    /// Карточка товара тем же вызовом API, что у ProductView. Короткий кэш (цены не «стареют»).
    static func detail(_ id: Int) async -> ProductDetail? {
        if let c = detailCache[id], Date().timeIntervalSince(c.at) < detailTTL { return c.detail }
        guard let d: ProductDetail = try? await API.shared.get("api/v1/products/\(id)") else { return nil }
        detailCache[id] = (Date(), d)
        return d
    }
}

// MARK: - Терпимые поля меню

/// 0/1, true/false или «0»/«1»/«true»/«false»; всё остальное — nil (в отличие от LenientBool).
@propertyWrapper
struct LenientFlag: Codable, Hashable {
    var wrappedValue: Bool?
    init(wrappedValue: Bool?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.singleValueContainer() else { wrappedValue = nil; return }
        if let b = try? c.decode(Bool.self) { wrappedValue = b }
        else if let i = try? c.decode(Int.self) { wrappedValue = i > 0 }
        else if let s = try? c.decode(String.self) {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true": wrappedValue = true
            case "0", "false": wrappedValue = false
            default: wrappedValue = nil
            }
        } else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

/// Теги продавца: массив строк или объектов {name|title|label|text}; одиночная строка — один тег.
@propertyWrapper
struct LenientTags: Codable, Hashable {
    var wrappedValue: [String]?
    init(wrappedValue: [String]?) { self.wrappedValue = wrappedValue }

    private struct Item: Decodable {
        let text: String?
        private enum K: String, CodingKey { case name, title, label, text }
        init(from decoder: Decoder) throws {
            if let c = try? decoder.singleValueContainer(), let s = try? c.decode(String.self) { text = s; return }
            if let k = try? decoder.container(keyedBy: K.self) {
                text = (try? k.decodeIfPresent(String.self, forKey: .name))
                    ?? (try? k.decodeIfPresent(String.self, forKey: .title))
                    ?? (try? k.decodeIfPresent(String.self, forKey: .label))
                    ?? (try? k.decodeIfPresent(String.self, forKey: .text))
                return
            }
            text = nil
        }
    }

    init(from decoder: Decoder) throws {
        guard let c = try? decoder.singleValueContainer() else { wrappedValue = nil; return }
        if let arr = try? c.decode([Item].self) { wrappedValue = arr.compactMap { $0.text } }
        else if let s = try? c.decode(String.self) { wrappedValue = [s] }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Отсутствующий ключ или мусор дают nil, а не ошибку.
    func decode(_ type: LenientFlag.Type, forKey key: Key) throws -> LenientFlag {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientFlag(wrappedValue: nil)
    }
    func decode(_ type: LenientTags.Type, forKey key: Key) throws -> LenientTags {
        (try? decodeIfPresent(type, forKey: key)) ?? LenientTags(wrappedValue: nil)
    }
}
