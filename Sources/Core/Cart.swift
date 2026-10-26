import Foundation
import Combine

struct CartLine: Codable, Identifiable {
    let key: String
    let productId: Int
    let name: String
    let unitPrice: Double
    var qty: Double
    let modifierIds: [Int]
    let modsLabel: String
    let photo: String?
    var unit: String? = nil
    var qtyFractional: Bool? = nil
    var qtyPresets: String? = nil
    /// Шаг количества товара (qty_step). Корзина раньше его не знала и для
    /// дробного товара без размеров шагала по 0,1: в карточке 0,3 → 0,6 кг, а в
    /// корзине «+» давал 0,4 кг, который сервер пересчитывал по своей сетке
    /// шага, — сумма в корзине и в заказе расходилась. nil у старых строк.
    var qtyStep: Double? = nil
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
    var total: Double {
        // В Decimal: 289,90 × 0,25 в Double = 72,474999… → 72,47, а сервер берёт 72,48.
        let s = lines.reduce(Decimal(0)) { acc, l in
            var v = Money.parse(l.unitPrice) * (Decimal(string: String(l.qty)) ?? 0)
            var r = Decimal(); NSDecimalRound(&r, &v, 2, .plain); return acc + r
        }
        return NSDecimalNumber(decimal: s).doubleValue
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
    private static func makeKey() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    private static let checkoutKeyStore = "cart_checkout_key"
    /// Когда ключ выдан (секунды с 1970). Сервер ищет дубль по shop_id + ключ
    /// без срока давности: ключ недельной давности на той же корзине вернул бы
    /// старый заказ (duplicate) вместо нового. Защита нужна на минуты/часы.
    private static let checkoutKeyAtStore = "cart_checkout_key_at"
    static let checkoutKeyTTL: TimeInterval = 24 * 60 * 60

    private init() { load() }

    /// Заменить корзину набором позиций (для «Заказать снова»).
    func setLines(_ newLines: [CartLine], shopId: Int, shopName: String?, shopSlug: String?) {
        lines = newLines
        self.shopId = shopId; self.shopName = shopName; self.shopSlug = shopSlug
        save()
    }

    func add(product: ProductDetail, modifierIds: [Int], options: [ModifierOption], shopId: Int, shopName: String?, qty: Double = 1) {
        if self.shopId != nil && self.shopId != shopId { lines = [] } // корзина из одного заведения
        self.shopId = shopId; self.shopName = shopName; self.shopSlug = product.shopSlug
        let chosen = options.filter { modifierIds.contains($0.id) }
        let modPrice = chosen.reduce(0) { $0 + ($1.price ?? 0) }
        let key = "\(product.id)-\(modifierIds.sorted().map(String.init).joined(separator: ","))"
        if let idx = lines.firstIndex(where: { $0.key == key }) {
            // Паритет с Android: количество суммируем, а цену, название и фото
            // берём из свежей карточки. Корзина живёт на диске днями, и повторное
            // добавление оставляло старую цену — итог расходился с сервером.
            let old = lines[idx]
            let newQty: Double = ((old.qty + qty) * 1000).rounded() / 1000   // суммируем
            var freshPrice: Double = old.unitPrice
            if let p = product.price { freshPrice = p + modPrice }
            var line = CartLine(key: key, productId: old.productId, name: product.name ?? old.name,
                                unitPrice: freshPrice, qty: newQty, modifierIds: old.modifierIds,
                                modsLabel: old.modsLabel,
                                photo: product.photos?.first?.pathWebp ?? old.photo)
            line.unit = old.unit
            line.qtyFractional = old.qtyFractional
            line.qtyPresets = old.qtyPresets
            line.qtyStep = old.qtyStep
            lines[idx] = line
        } else {
            lines.append(CartLine(key: key, productId: product.id, name: product.name ?? "",
                unitPrice: (product.price ?? 0) + modPrice, qty: qty, modifierIds: modifierIds,
                modsLabel: chosen.compactMap { $0.name }.joined(separator: ", "),
                photo: product.photos?.first?.pathWebp,
                unit: product.unit, qtyFractional: (product.qtyFractional ?? 0) == 1, qtyPresets: product.qtyPresets,
                qtyStep: product.qtyStep))
        }
        Track.addToCart(id: product.id, name: product.name, price: product.price, qty: 1)
        save()
    }
    func inc(_ key: String) {
        if let i = lines.firstIndex(where: { $0.key == key }) { lines[i].qty = snapCartQty(lines[i], lines[i].qty + lines[i].step); save() }
    }
    func dec(_ key: String) {
        if let i = lines.firstIndex(where: { $0.key == key }) {
            let raw = lines[i].qty - lines[i].step
            if raw <= 0 { lines.remove(at: i) } else { lines[i].qty = snapCartQty(lines[i], raw) }
            if lines.isEmpty { shopId = nil; shopName = nil; shopSlug = nil }
            save()
        }
    }
    func clear() { lines = []; shopId = nil; shopName = nil; shopSlug = nil; save() }

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
    let subtotal: Double
}

/// Расчёт сервисного сбора (как на сервере): с клиента — при любом payer, кроме "shop".
enum Fees {
    static func service(subtotal: Double, shop: ShopDetail?) -> Double {
        // Как на сервере (api_v1.php: payer === 'shop' ? 'shop' : 'client'): сбор не берётся
        // только при payer == "shop". Пустое поле раньше давало 0 в приложении, а сервер сбор брал.
        guard let shop, (shop.serviceFeePayer ?? "") != "shop" else { return 0 }
        if (shop.serviceFeeType ?? "percent") == "fixed" { return shop.serviceFeeFixed ?? 0 }
        // В Decimal: 1234,50 × 3 % в Double = 37,0349… → 37,03, сервер — 37,04.
        var v = Money.parse(subtotal) * Money.parse(shop.serviceFeePercent ?? 0) / 100
        var r = Decimal(); NSDecimalRound(&r, &v, 2, .plain)
        return NSDecimalNumber(decimal: r).doubleValue
    }
}
