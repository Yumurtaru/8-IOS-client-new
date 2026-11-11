import Foundation

/*
  O1: оптовая цена от количества. Чистая логика + модели + тексты.
  Формула одна на все платформы (только для показа до ответа сервера, итог — сервера):
    eff   = ступени с minQty > 0 и 0 < price < розница, по возрастанию minQty
    qtyTotal = сумма qty всех строк корзины с этим product_id
    tier  = последняя ступень с minQty <= qtyTotal + 1e-9
    unit  = (tier.price или розница) + добавки;  строка = round(unit × qty, 2, HALF_UP)
  Деньги — только Decimal. Клиент декодирует с convertFromSnakeCase: CodingKeys не нужны.
*/

/// Ступень оптовой цены: {"min_qty": 25, "price": "37.00"}.
struct PriceTier: Codable, Hashable {
    @LenientDouble var minQty: Double?
    @LenientDecimal var price: Decimal?
}

/// Подсказка сервера «до опта осталось чуть-чуть» (data.wholesale_hints[]).
struct WholesaleHint: Codable, Hashable, Identifiable {
    @LenientInt var productId: Int?
    let name: String?
    let unit: String?
    @LenientDouble var qty: Double?
    @LenientDouble var minQty: Double?
    @LenientDouble var addQty: Double?
    @LenientDecimal var price: Decimal?
    @LenientDecimal var saving: Decimal?
    @LenientBool var near: Bool?
    var id: Int { productId ?? 0 }
}

/// Список, в котором битый элемент (или не-массив) не роняет разбор всего объекта.
/// Нет ключа / null / мусор — nil (у старого сервера поля нет).
@propertyWrapper
struct LossyList<T: Codable & Hashable>: Codable, Hashable {
    var wrappedValue: [T]?
    init(wrappedValue: [T]?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { wrappedValue = nil }
        else if let arr = try? c.decode([LossyElement<T>].self) { wrappedValue = arr.compactMap { $0.value } }
        else { wrappedValue = nil }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Отсутствующий ключ (старый сервер) даёт nil, а не keyNotFound.
    func decode<T: Codable & Hashable>(_ type: LossyList<T>.Type, forKey key: Key) throws -> LossyList<T> {
        (try? decodeIfPresent(type, forKey: key)) ?? LossyList<T>(wrappedValue: nil)
    }
}

enum Wholesale {
    /// Применимая ступень: цена и порог уже проверены.
    struct Step: Hashable {
        let minQty: Double
        let price: Decimal
    }

    static let eps = 1e-9

    // MARK: Формула

    /// eff: ступени с minQty > 0, 0 < price < розница; по возрастанию minQty.
    static func steps(_ tiers: [PriceTier]?, retail: Decimal) -> [Step] {
        var out: [Step] = []
        for t in tiers ?? [] {
            guard let q = t.minQty, let p = t.price, q > 0, p > 0, p < retail else { continue }
            out.append(Step(minQty: q, price: p))
        }
        return out.sorted { $0.minQty < $1.minQty }
    }

    /// Достигнутая ступень: последняя с minQty <= qtyTotal.
    static func tier(_ steps: [Step], qtyTotal: Double) -> Step? {
        steps.last(where: { $0.minQty <= qtyTotal + eps })
    }

    /// Следующая недостигнутая ступень.
    static func next(_ steps: [Step], qtyTotal: Double) -> Step? {
        steps.first(where: { $0.minQty > qtyTotal + eps })
    }

    /// Количество в Decimal без Double-хвостов (до 3 знаков, как в корзине).
    static func dec(_ q: Double) -> Decimal {
        Decimal(string: String((q * 1000).rounded() / 1000)) ?? 0
    }

    /// round(v, 2, HALF_UP).
    static func round2(_ v: Decimal) -> Decimal {
        var x = v
        var r = Decimal()
        NSDecimalRound(&r, &x, 2, .plain)
        return r
    }

    /// Цена единицы: (цена ступени или розница) + добавки.
    static func unit(retail: Decimal, addons: Decimal, steps: [Step], qtyTotal: Double) -> Decimal {
        (tier(steps, qtyTotal: qtyTotal)?.price ?? retail) + addons
    }

    /// Сумма строки: round(unit × qty, 2).
    static func lineTotal(unit: Decimal, qty: Double) -> Decimal {
        round2(unit * dec(qty))
    }

    /// Скидка ступени в процентах (целое, HALF_UP); 0 — не показывать.
    static func percent(retail: Decimal, tierPrice: Decimal) -> Int {
        guard retail > 0, tierPrice < retail else { return 0 }
        var x = (retail - tierPrice) / retail * 100
        var r = Decimal()
        NSDecimalRound(&r, &x, 0, .plain)
        return NSDecimalNumber(decimal: r).intValue
    }

    // MARK: Корзина

    /// Σ qty всех строк с этим товаром (разные добавки — один товар).
    static func qtyTotal(_ lines: [CartLine], productId: Int) -> Double {
        lines.filter { $0.productId == productId }.reduce(0.0) { $0 + $1.qty }
    }

    /// Применимые ступени строки; пусто — опта нет (или корзину сохранила старая версия).
    static func steps(for line: CartLine) -> [Step] {
        guard let base = line.retailBase else { return [] }
        return steps(line.priceTiers, retail: Money.parse(base))
    }

    /// Розничная цена единицы с добавками.
    static func retailUnit(_ line: CartLine) -> Decimal {
        Money.parse(line.retailUnit ?? line.unitPrice)
    }

    /// Достигнутая ступень строки (по локальной формуле).
    static func tier(for line: CartLine, in lines: [CartLine]) -> Step? {
        tier(steps(for: line), qtyTotal: qtyTotal(lines, productId: line.productId))
    }

    /// Строка идёт по опту: локально по формуле, а для строк без ступеней
    /// (старое сохранение корзины) — по флагу прошлого ответа сервера.
    static func isWholesale(_ line: CartLine, in lines: [CartLine]) -> Bool {
        if !steps(for: line).isEmpty { return tier(for: line, in: lines) != nil }
        return line.serverWholesale == true
    }

    /// Цена единицы строки сейчас. Нет ступеней — как раньше (unitPrice).
    static func lineUnit(_ line: CartLine, in lines: [CartLine]) -> Decimal {
        let st = steps(for: line)
        guard !st.isEmpty, let base = line.retailBase else { return Money.parse(line.unitPrice) }
        let baseD = Money.parse(base)
        let rU = retailUnit(line)
        let addons = rU > baseD ? rU - baseD : 0
        return unit(retail: baseD, addons: addons, steps: st, qtyTotal: qtyTotal(lines, productId: line.productId))
    }

    static func lineTotal(_ line: CartLine, in lines: [CartLine]) -> Decimal {
        lineTotal(unit: lineUnit(line, in: lines), qty: line.qty)
    }

    /// Итог корзины: сумма округлённых строк.
    static func cartTotal(_ lines: [CartLine]) -> Decimal {
        lines.reduce(Decimal(0)) { $0 + lineTotal($1, in: lines) }
    }

    /// Шаг количества -> добавка N, округлённая ВВЕРХ до шага товара.
    static func roundUp(_ add: Double, step: Double) -> Double {
        guard add > 0 else { return 0 }
        guard step > 0 else { return add }
        let n = (add / step - eps).rounded(.up)
        return ((max(1, n) * step) * 1000).rounded() / 1000
    }

    // MARK: Тексты (дословно, как на Android)

    /// Единица товара; нет/пусто → nil. П-70: `unit = null` — «единица не указана», а не «шт»
    /// (товар может быть и дробным) — метка без единицы, как на сайте: «от 25 — 37 ₽».
    static func unitName(_ unit: String?) -> String? {
        let u = (unit ?? "").trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? nil : u
    }

    /// «25 кг» или просто «25», если единица не указана.
    static func qtyWithUnit(_ q: Double, _ unit: String?) -> String {
        guard let u = unitName(unit) else { return fmtQty(q) }
        return "\(fmtQty(q)) \(u)"
    }

    /// «/кг» к цене или пусто, если единица не указана.
    static func perUnit(_ unit: String?) -> String {
        guard let u = unitName(unit) else { return "" }
        return "/\(u)"
    }

    /// «от 25 кг — 37 ₽/кг (−18%)»; без единицы — «от 25 — 37 ₽ (−18%)».
    static func tierRow(_ s: Step, retail: Decimal, unit: String?) -> String {
        let price = Money.format(s.price)
        var t = "от \(qtyWithUnit(s.minQty, unit)) — \(price)\(perUnit(unit))"
        let pct = percent(retail: retail, tierPrice: s.price)
        if pct > 0 { t += " (\u{2212}\(pct)%)" }
        return t
    }

    /// Метка в списках: «от 25 кг — 37 ₽», без единицы — «от 25 — 37 ₽» (первая ступень).
    static func listLabel(_ tiers: [PriceTier]?, retail: Decimal, unit: String?) -> String? {
        guard let s = steps(tiers, retail: retail).first else { return nil }
        return "от \(qtyWithUnit(s.minQty, unit)) — \(Money.format(s.price))"
    }

    static func savingText(_ saving: Decimal) -> String { "Экономия \(Money.format(saving))" }

    /// «Ещё 3 кг до оптовой цены» (без единицы — «Ещё 3 до оптовой цены»).
    static func moreText(_ s: Step, qtyTotal: Double, unit: String?) -> String {
        let left = max(0, ((s.minQty - qtyTotal) * 1000).rounded() / 1000)
        return "Ещё \(qtyWithUnit(left, unit)) до оптовой цены"
    }

    /// «Добавьте ещё 1 кг — будет по 37 ₽/кг, экономия 200 ₽» (без единицы — «…ещё 1 — будет по 37 ₽, …»).
    static func hintText(add: Double, price: Decimal, saving: Decimal, unit: String?) -> String {
        let q = qtyWithUnit(add, unit)
        let p = Money.format(price)
        let sv = Money.format(saving)
        return "Добавьте ещё \(q) — будет по \(p)\(perUnit(unit)), экономия \(sv)"
    }

    /// «Добавить 1 кг» (без единицы — «Добавить 1»).
    static func addButtonText(add: Double, unit: String?) -> String {
        "Добавить \(qtyWithUnit(add, unit))"
    }

    static let optLabel = "оптовая цена"
    static let blockTitle = "Оптом дешевле"
}

extension Product {
    /// Метка в списках: «от 25 кг — 37 ₽» (nil — опта нет).
    var wholesaleLabel: String? {
        Wholesale.listLabel(priceTiers, retail: Money.dec(price), unit: unit)
    }
}

extension CatalogItem {
    /// П-69: /api/v1/catalog и /recommendations отдают unit (строка или null) и price_tiers.
    /// П-70: без unit — метка без единицы («от 25 — 37 ₽»), как на сайте и Android.
    var wholesaleLabel: String? {
        Wholesale.listLabel(priceTiers, retail: Money.dec(price), unit: unit)
    }
}
