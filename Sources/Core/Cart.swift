import Foundation
import Combine

struct CartLine: Codable, Identifiable {
    let key: String
    let productId: Int
    var name: String
    /// Деньги — Decimal. С диска читаются терпимо (см. extension CartLine ниже):
    /// старые сохранения хранили Double-числа (490.0, 150.65).
    var unitPrice: Decimal
    var qty: Double
    let modifierIds: [Int]
    let modsLabel: String
    var photo: String?
    var unit: String? = nil
    var qtyFractional: Bool? = nil
    var qtyPresets: String? = nil
    /// Шаг количества товара (qty_step). Корзина раньше его не знала и для
    /// дробного товара без размеров шагала по 0,1: в карточке 0,3 → 0,6 кг, а в
    /// корзине «+» давал 0,4 кг, который сервер пересчитывал по своей сетке
    /// шага, — сумма в корзине и в заказе расходилась. nil у старых строк.
    var qtyStep: Double? = nil
    /// O1: оптовые ступени товара; розница без добавок и с добавками (unitPrice после
    /// ответа сервера может быть оптовой, поэтому розница хранится отдельно); флаг
    /// «по опту» из прошлого ответа сервера (только для строк без ступеней).
    /// nil у старых сохранений — читаются как раньше.
    var priceTiers: [PriceTier]? = nil
    var retailBase: Decimal? = nil
    var retailUnit: Decimal? = nil
    var serverWholesale: Bool? = nil
    var id: String { key }

    var presets: [Double] {
        (qtyPresets ?? "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.filter { $0 > 0 }.sorted()
    }
    var isFractional: Bool {
        // Как на сервере (snapOrderQty): только флаг товара/категории или ≥2 размера.
        // Единица «кг» сама по себе не дробит: сервер округлил бы 0,9 кг до 1 кг.
        (qtyFractional ?? false) || presets.count >= 2
    }
    var step: Double {
        // Тот же порядок, что у карточки товара (ProductView.stepValue).
        if let p = presets.first { return p }
        guard isFractional else { return 1.0 }
        if let s = qtyStep, s > 0 { return s }
        return 0.1
    }
}

/// Хранение корзины на диске (UserDefaults "cart_lines", JSON). Деньги читаются через
/// LenientDecimal: старые сохранения (Double-числа 490.0 / 150.65) и новые (строка
/// "150.65") дают точный Decimal — у числа с дробью берётся кратчайшая строковая запись
/// Double (150.65, а не 150.6499999…). Пишем деньги СТРОКОЙ ("150.65"): строка читается
/// без потерь. Остальные поля — те же ключи, что у прежнего синтезированного кодека,
/// так что корзина после обновления не теряется.
extension CartLine {
    enum CodingKeys: String, CodingKey {
        case key, productId, name, unitPrice, qty, modifierIds, modsLabel, photo, unit,
             qtyFractional, qtyPresets, qtyStep, priceTiers, retailBase, retailUnit, serverWholesale
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func money(_ k: CodingKeys) -> Decimal? {
            (try? c.decodeIfPresent(LenientDecimal.self, forKey: k))?.wrappedValue
        }
        self.key = try c.decode(String.self, forKey: .key)
        self.productId = try c.decode(Int.self, forKey: .productId)
        self.name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        self.unitPrice = money(.unitPrice) ?? 0
        self.qty = (try? c.decode(Double.self, forKey: .qty)) ?? 1
        self.modifierIds = (try? c.decodeIfPresent([Int].self, forKey: .modifierIds)) ?? []
        self.modsLabel = (try? c.decodeIfPresent(String.self, forKey: .modsLabel)) ?? ""
        self.photo = try? c.decodeIfPresent(String.self, forKey: .photo)
        self.unit = try? c.decodeIfPresent(String.self, forKey: .unit)
        self.qtyFractional = try? c.decodeIfPresent(Bool.self, forKey: .qtyFractional)
        self.qtyPresets = try? c.decodeIfPresent(String.self, forKey: .qtyPresets)
        self.qtyStep = try? c.decodeIfPresent(Double.self, forKey: .qtyStep)
        self.priceTiers = try? c.decodeIfPresent([PriceTier].self, forKey: .priceTiers)
        self.retailBase = money(.retailBase)
        self.retailUnit = money(.retailUnit)
        self.serverWholesale = try? c.decodeIfPresent(Bool.self, forKey: .serverWholesale)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(productId, forKey: .productId)
        try c.encode(name, forKey: .name)
        try c.encode(LenientDecimal(wrappedValue: unitPrice), forKey: .unitPrice)
        try c.encode(qty, forKey: .qty)
        try c.encode(modifierIds, forKey: .modifierIds)
        try c.encode(modsLabel, forKey: .modsLabel)
        try c.encodeIfPresent(photo, forKey: .photo)
        try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(qtyFractional, forKey: .qtyFractional)
        try c.encodeIfPresent(qtyPresets, forKey: .qtyPresets)
        try c.encodeIfPresent(qtyStep, forKey: .qtyStep)
        try c.encodeIfPresent(priceTiers, forKey: .priceTiers)
        if let v = retailBase { try c.encode(LenientDecimal(wrappedValue: v), forKey: .retailBase) }
        if let v = retailUnit { try c.encode(LenientDecimal(wrappedValue: v), forKey: .retailUnit) }
        try c.encodeIfPresent(serverWholesale, forKey: .serverWholesale)
    }
}

/// Количество с запятой и единицей: 0.3 → "0,3 кг".
func fmtQty(_ q: Double, _ unit: String? = nil) -> String {
    let n = (q * 1000).rounded() / 1000
    let s = (n == n.rounded() ? String(Int(n)) : String(n)).replacingOccurrences(of: ".", with: ",")
    if let u = unit, !u.isEmpty { return "\(s) \(u)" }
    return s
}

func snapCartQty(_ line: CartLine, _ q: Double) -> Double {
    func r3(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
    if !line.isFractional { return max(1, q.rounded()) }
    let ps = line.presets
    if ps.count >= 2 { return max(ps.first ?? 0.001, r3(q)) }        // размеры суммируются → свободно
    if ps.count == 1 { let s = ps[0]; return max(s, (q / s).rounded() * s) }
    // Дробный товар с шагом продавца — по сетке шага, как карточка товара и сервер.
    if let s = line.qtyStep, s > 0 { return max(s, r3((q / s).rounded() * s)) }
    return max(0.001, r3(q))
}


/// AT-1/AT-3: заказ отправлен, окончательного ответа нет. Хранит ТО ЖЕ тело
/// запроса (JSON, с ключом повтора), что ушло на сервер, и состав, который видел
/// человек. unknown — ответ не пришёл (обрыв связи, таймаут, 5xx, выгрузка
/// приложения): заказ мог создаться. Пока запись есть, корзина и форма
/// оформления не меняются, повтор идёт тем же ключом и тем же телом.
struct PendingOrder: Codable {
    let body: Data
    let key: String
    let lines: [CartLine]
    let shopName: String?
    /// Строки «что отправлено»: способ, адрес, время, оплата, промокод…
    let summary: [String]
    /// Итог, который человек видел на кнопке.
    let shownTotal: String
    var unknown: Bool
    let at: TimeInterval
}

/// O1: цена строки из ответа cart/validate. wholesale == true — unit уже по опту,
/// retail — retail_line_price (розница единицы с добавками, может быть nil).
struct ServerLinePrice {
    let unit: Decimal
    let retail: Decimal?
    let wholesale: Bool?
}

final class Cart: ObservableObject {
    static let shared = Cart()
    @Published private(set) var lines: [CartLine] = []
    @Published private(set) var shopId: Int?
    @Published private(set) var shopName: String?
    @Published private(set) var shopSlug: String?

    var count: Int { lines.reduce(0) { $0 + ($1.qty < 1 ? 1 : Int($1.qty.rounded())) } }
    /// Итог корзины. Округляем КАЖДУЮ строку до копеек и складываем
    /// округлённые — ровно так считает сервер (round(unit*qty, 2) по строке).
    /// Раньше складывались неокруглённые: на дробных количествах кнопка
    /// обещала 150,65 ₽, а в заказе оказывалось 150,66 ₽.
    var total: Decimal {
        // O1: по формуле опта (qtyTotal по товару), каждая строка округляется до копейки.
        Wholesale.cartTotal(lines)
    }
    var isEmpty: Bool { lines.isEmpty }
    private var snapshotTask: Task<Void, Never>?
    /// Ключ повтора оформления: один, пока корзина не меняется.
    /// Любое изменение состава (save()) выдаёт новый ключ — сервер сравнивает
    /// только ключ (orders.idempotency_key), поэтому повтор с другой корзиной
    /// не должен прийти со старым. Ключ пишется на диск вместе с корзиной:
    /// раньше он жил только в памяти, и после таймаута + выгрузки приложения
    /// повторное «Оформить» шло с новым ключом — второй заказ (как Android Cart.kt).
    private(set) var checkoutKey = Cart.makeKey()
    /// AT-3: неотвеченное оформление (см. PendingOrder).
    @Published private(set) var pendingOrder: PendingOrder?
    /// AT-3: неотвеченное оформление старше суток снято при открытии — корзина
    /// показывает «проверьте „Мои заказы“» (CartView), пока человек не закроет.
    @Published var pendingExpired = false
    /// 0,005 ₽ — порог «цена изменилась» (Decimal без Double-литерала).
    private static let halfCent = Decimal(sign: .plus, exponent: -3, significand: 5)
    private static let pendingStore = "cart_pending_order"
    /// Срок записи — как у ключа корзины.
    static let pendingTTL: TimeInterval = 24 * 60 * 60
    private static func makeKey() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    private static let checkoutKeyStore = "cart_checkout_key"
    /// Когда ключ выдан (секунды с 1970). Сервер ищет дубль по shop_id + ключ
    /// без срока давности: ключ недельной давности на той же корзине вернул бы
    /// старый заказ (duplicate) вместо нового. Защита нужна на минуты/часы.
    private static let checkoutKeyAtStore = "cart_checkout_key_at"
    static let checkoutKeyTTL: TimeInterval = 24 * 60 * 60

    private init() { load() }

    /// true — менять корзину сейчас нельзя (экран сам говорит почему: плашка
    /// корзины, тост карточки товара, текст «Повторить заказ»).
    func checkLocked() -> Bool {
        expireStalePending()
        return pendingOrder != nil
    }

    /// Неотвеченное оформление старше суток: сервер его давно обработал или нет —
    /// держать корзину запертой дальше нельзя. Снимаем и просим проверить заказы.
    func expireStalePending() {
        guard let p = pendingOrder, abs(Date().timeIntervalSince1970 - p.at) > Cart.pendingTTL else { return }
        pendingOrder = nil
        storePending()
        pendingExpired = true
    }

    /// Перед отправкой заказа: тело и ключ — на диск до запроса.
    func beginOrder(_ p: PendingOrder) { pendingOrder = p; pendingExpired = false; storePending() }
    /// Ответа нет — исход неизвестен. Только для СВОЕГО запроса (ключ совпал):
    /// поздний ответ старого запроса чужую запись не трогает.
    func markOrderUnknown(key: String) {
        guard pendingOrder?.key == key else { return }
        pendingOrder?.unknown = true
        storePending()
    }
    /// Окончательный отказ сервера (4xx): заказа нет, форма и корзина снова правятся.
    func dropPendingOrder(key: String) {
        guard pendingOrder?.key == key else { return }
        pendingOrder = nil
        storePending()
    }
    /// Человек сам отказался от повтора (предупреждён, что прежний заказ мог
    /// создаться). Новый ключ: изменённый заказ не вернёт прежний как «дубль».
    func abandonPendingOrder() {
        pendingOrder = nil
        storePending()
        checkoutKey = Cart.makeKey()
        if !lines.isEmpty { storeKey(at: Date().timeIntervalSince1970) }
    }
    /// А113: 422 idempotency_key_reused — этим ключом уже оформлен заказ с другим
    /// составом. Следующее оформление — с новым ключом (только если ключ ещё тот же:
    /// корзину могли поменять, и ключ уже новый). Неотвеченное оформление не трогаем.
    func renewCheckoutKey(ifCurrent key: String) {
        guard checkoutKey == key, pendingOrder == nil else { return }
        checkoutKey = Cart.makeKey()
        if !lines.isEmpty { storeKey(at: Date().timeIntervalSince1970) }
    }
    private func storePending() {
        if let p = pendingOrder, let d = try? JSONEncoder().encode(p) {
            UserDefaults.standard.set(d, forKey: Cart.pendingStore)
        } else {
            UserDefaults.standard.removeObject(forKey: Cart.pendingStore)
        }
    }

    /// AT-2: цены строк по ответу сервера (ключ строки → цена за единицу с добавками).
    /// true — что-то поменялось. При неотвеченном оформлении не трогаем.
    /// O1: у строки со ступенями розницу берём из retail_line_price (если сервер
    /// прислал), цену по опту всегда считает формула от количества.
    @discardableResult
    func applyPrices(_ prices: [String: ServerLinePrice]) -> Bool {
        guard pendingOrder == nil, !prices.isEmpty else { return false }
        var changed = false
        let fresh: [CartLine] = lines.map { old in
            guard let sp = prices[old.key] else { return old }
            var line = old
            let hasTiers = !Wholesale.steps(for: old).isEmpty
            // Розничная цена единицы: при опте — retail_line_price, иначе сама цена.
            var retail: Decimal? = sp.retail
            if retail == nil && sp.wholesale != true { retail = sp.unit }
            if hasTiers {
                if let r = retail {
                    let oldR: Decimal = old.retailUnit ?? old.unitPrice
                    line.retailUnit = r
                    if let b = old.retailBase { line.retailBase = b + (r - oldR) }
                    line.unitPrice = r
                }
            } else {
                line.unitPrice = sp.unit
                if let r = retail { line.retailUnit = r }
            }
            line.serverWholesale = sp.wholesale
            if abs(line.unitPrice - old.unitPrice) >= Cart.halfCent
                || abs((line.retailUnit ?? 0) - (old.retailUnit ?? 0)) >= Cart.halfCent
                || line.serverWholesale != old.serverWholesale { changed = true }
            return line
        }
        guard changed else { return false }
        lines = fresh
        save()
        return true
    }

    /// O1: подсказка «Добавить N кг» — в первую строку товара без добавок, иначе в первую
    /// строку товара. N уже округлено вверх до шага. false — корзина заперта или строки нет.
    @discardableResult
    func addWholesale(productId: Int, qty: Double) -> Bool {
        if checkLocked() || qty <= 0 { return false }
        let idx = lines.firstIndex(where: { $0.productId == productId && $0.modifierIds.isEmpty })
            ?? lines.firstIndex(where: { $0.productId == productId })
        guard let i = idx else { return false }
        lines[i].qty = snapCartQty(lines[i], lines[i].qty + qty)
        lines[i].serverWholesale = nil
        save()
        return true
    }

    /// Заменить корзину набором позиций (для «Заказать снова»).
    /// false — корзина заблокирована неотвеченным оформлением.
    @discardableResult
    func setLines(_ newLines: [CartLine], shopId: Int, shopName: String?, shopSlug: String?) -> Bool {
        if checkLocked() { return false }
        lines = newLines
        self.shopId = shopId; self.shopName = shopName; self.shopSlug = shopSlug
        save()
        return true
    }

    /// false — не добавлено: корзина заблокирована неотвеченным оформлением.
    @discardableResult
    func add(product: ProductDetail, modifierIds: [Int], options: [ModifierOption], shopId: Int, shopName: String?, qty: Double = 1) -> Bool {
        if checkLocked() { return false }
        if self.shopId != nil && self.shopId != shopId { lines = [] } // корзина из одного заведения
        self.shopId = shopId; self.shopName = shopName; self.shopSlug = product.shopSlug
        let chosen = options.filter { modifierIds.contains($0.id) }
        let modPrice: Decimal = chosen.reduce(Decimal(0)) { $0 + ($1.price ?? 0) }
        let key = "\(product.id)-\(modifierIds.sorted().map(String.init).joined(separator: ","))"
        if let idx = lines.firstIndex(where: { $0.key == key }) {
            // Паритет с Android: количество суммируем, а цену, название и фото
            // берём из свежей карточки. Корзина живёт на диске днями, и повторное
            // добавление оставляло старую цену — итог расходился с сервером.
            let old = lines[idx]
            let newQty: Double = ((old.qty + qty) * 1000).rounded() / 1000   // суммируем
            var freshPrice: Decimal = old.unitPrice
            if let p = product.price { freshPrice = p + modPrice }
            var line = old
            line.unitPrice = freshPrice
            line.qty = newQty
            if let n = product.name { line.name = n }
            line.photo = product.photos?.first?.pathWebp ?? old.photo
            line.serverWholesale = nil
            line.priceTiers = product.priceTiers
            line.retailBase = product.price
            line.retailUnit = freshPrice
            lines[idx] = line
        } else {
            lines.append(CartLine(key: key, productId: product.id, name: product.name ?? "",
                unitPrice: (product.price ?? 0) + modPrice, qty: qty, modifierIds: modifierIds,
                modsLabel: chosen.compactMap { $0.name }.joined(separator: ", "),
                photo: product.photos?.first?.pathWebp,
                unit: product.unit, qtyFractional: (product.qtyFractional ?? 0) == 1, qtyPresets: product.qtyPresets,
                qtyStep: product.qtyStep,
                priceTiers: product.priceTiers, retailBase: product.price,
                retailUnit: (product.price ?? 0) + modPrice))
        }
        // Аналитика (AppMetrica) — не расчёт денег: Double допустим только здесь.
        Track.addToCart(id: product.id, name: product.name, price: Money.toDouble(product.price), qty: 1)
        save()
        return true
    }
    func inc(_ key: String) {
        if checkLocked() { return }
        if let i = lines.firstIndex(where: { $0.key == key }) { lines[i].qty = snapCartQty(lines[i], lines[i].qty + lines[i].step); lines[i].serverWholesale = nil; save() }
    }
    func dec(_ key: String) {
        if checkLocked() { return }
        if let i = lines.firstIndex(where: { $0.key == key }) {
            let raw = lines[i].qty - lines[i].step
            if raw <= 0 { lines.remove(at: i) } else { lines[i].qty = snapCartQty(lines[i], raw); lines[i].serverWholesale = nil }
            if lines.isEmpty { shopId = nil; shopName = nil; shopSlug = nil }
            save()
        }
    }
    /// Заказ создан или смена/выход из аккаунта: неотвеченное оформление больше не нужно.
    func clear() {
        pendingOrder = nil; storePending()
        lines = []; shopId = nil; shopName = nil; shopSlug = nil; save()
    }

    private func save() {
        checkoutKey = Cart.makeKey()
        if let d = try? JSONEncoder().encode(lines) { UserDefaults.standard.set(d, forKey: "cart_lines") }
        UserDefaults.standard.set(shopId ?? 0, forKey: "cart_shop")
        UserDefaults.standard.set(shopName, forKey: "cart_shop_name")
        UserDefaults.standard.set(shopSlug, forKey: "cart_shop_slug")
        // Пустая корзина — ключ не нужен (после заказа clear() его и сменит).
        if lines.isEmpty {
            UserDefaults.standard.removeObject(forKey: Cart.checkoutKeyStore)
            UserDefaults.standard.removeObject(forKey: Cart.checkoutKeyAtStore)
        } else {
            storeKey(at: Date().timeIntervalSince1970)
        }
        syncSnapshot()
    }

    // Снимок корзины на сервер (для «брошенной корзины»). Дебаунс, только для залогиненных.
    private func syncSnapshot() {
        snapshotTask?.cancel()
        let body = CartSnapshotBody(shopId: shopId, shopSlug: shopSlug, shopName: shopName, itemsCount: count, subtotal: total)
        snapshotTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            guard Session.shared.isLoggedIn else { return }
            try? await API.shared.postVoid("api/v1/cart/snapshot", body: body)
        }
    }
    private func load() {
        if let d = UserDefaults.standard.data(forKey: "cart_lines"), let l = try? JSONDecoder().decode([CartLine].self, from: d) { lines = l }
        let s = UserDefaults.standard.integer(forKey: "cart_shop"); shopId = s == 0 ? nil : s
        shopName = UserDefaults.standard.string(forKey: "cart_shop_name")
        shopSlug = UserDefaults.standard.string(forKey: "cart_shop_slug")
        // AT-3: после перезапуска ответа на прошлую отправку уже не будет — исход неизвестен.
        if let d = UserDefaults.standard.data(forKey: Cart.pendingStore),
           var p = try? JSONDecoder().decode(PendingOrder.self, from: d), !p.key.isEmpty {
            p.unknown = true
            pendingOrder = p
            expireStalePending()
        }
        // Ключ повтора переживает выгрузку: таймаут → выгрузили → снова
        // «Оформить» вернёт уже созданный заказ, а не создаст второй.
        // Ключ старше суток не берём: выдаём новый и сразу пишем на диск, иначе
        // после следующей выгрузки снова получился бы другой ключ.
        guard !lines.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        if let k = UserDefaults.standard.string(forKey: Cart.checkoutKeyStore), !k.isEmpty, k.count <= 64 {
            let at = UserDefaults.standard.double(forKey: Cart.checkoutKeyAtStore)
            if at <= 0 {
                // Записан без времени (сборка до срока) — свежий, но ровно один раз.
                checkoutKey = k; storeKey(at: now)
            } else if abs(now - at) <= Cart.checkoutKeyTTL {
                checkoutKey = k
            } else {
                storeKey(at: now)   // checkoutKey уже новый (makeKey при создании)
            }
        } else {
            storeKey(at: now)
        }
    }
    private func storeKey(at t: TimeInterval) {
        UserDefaults.standard.set(checkoutKey, forKey: Cart.checkoutKeyStore)
        UserDefaults.standard.set(t, forKey: Cart.checkoutKeyAtStore)
    }
}

// Тело снимка корзины. Кодировщик API сам делает snake_case — CodingKeys не нужны.
struct CartSnapshotBody: Encodable {
    let shopId: Int?
    let shopSlug: String?
    let shopName: String?
    let itemsCount: Int
    let subtotal: Decimal
    enum CodingKeys: String, CodingKey { case shopId, shopSlug, shopName, itemsCount, subtotal }
    /// Формат на проводе прежний (JSON-число с копейками): Decimal пишем как Double
    /// от суммы, округлённой до копеек, — без хвоста вида 150.64999….
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(shopId, forKey: .shopId)
        try c.encodeIfPresent(shopSlug, forKey: .shopSlug)
        try c.encodeIfPresent(shopName, forKey: .shopName)
        try c.encode(itemsCount, forKey: .itemsCount)
        try c.encode(Money.wireNumber(subtotal), forKey: .subtotal)
    }
}

/// Расчёт сервисного сбора (как на сервере): с клиента — при любом payer, кроме "shop".
enum Fees {
    static func service(subtotal: Decimal, shop: ShopDetail?) -> Decimal {
        // Как на сервере (api_v1.php: payer === 'shop' ? 'shop' : 'client'): сбор не берётся
        // только при payer == "shop". Пустое поле раньше давало 0 в приложении, а сервер сбор брал.
        guard let shop, (shop.serviceFeePayer ?? "") != "shop" else { return 0 }
        if (shop.serviceFeeType ?? "percent") == "fixed" { return shop.serviceFeeFixed ?? 0 }
        // В Decimal: 1234,50 × 3 % в Double = 37,0349… → 37,03, сервер — 37,04.
        var v: Decimal = subtotal * Money.parse(shop.serviceFeePercent ?? 0) / 100
        var r = Decimal(); NSDecimalRound(&r, &v, 2, .plain)
        return r
    }
}
