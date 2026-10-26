import SwiftUI

//
//  CheckoutView.swift — экран оформления (screen: checkout). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    CheckoutView(onSuccess: (OrderCreateResult) -> Void, onBack: () -> Void)
//      onSuccess — заказ создан; родитель пушит SuccessView(order:).
//      onBack    — «‹ Оформление» назад к корзине.
//
//  API — реальные методы старого клиента (контракт НЕ меняется):
//    POST api/v1/delivery/quote            -> DeliveryQuote   (расчёт доставки по адресу)
//    GET  api/v1/profile/addresses         -> [Address]       (сохранённые адреса)
//    GET  api/address/suggest?q=…          -> [AddrSuggest]   (Dadata-прокси, токен на сервере)
//    POST api/v1/profile/addresses         -> (создание адреса, AddressBody)
//    GET  api/v1/shops/{slug}              -> ShopDetail      (сервисный сбор)
//    POST api/v1/orders                    -> OrderCreateResult (создание заказа)
//
//  Зона доставки определяется на сервере СКРЫТО по координатам адреса. Клиент видит только
//  результат: DeliveryQuote.available == false → адрес вне зоны, «Оформить заказ» блокируется.
//  Деньги — только Decimal через Money.format(Money.parse(...)). Токены — YM*.
//
//  Паритет с Android (9 Android-client-new): выбор сохранённых адресов радио-строкой,
//  «＋ Добавить новый адрес», форма без города (город из Session.cityName), Dadata-подсказки
//  строго по выбранному городу, блокировка CTA при outOfZone/noAddress, оплата «Наличные/Картой».
//

// ── Тело создания заказа (контракт как в старом клиенте, snake_case) ──
private struct OrderItemBody: Encodable {
    let productId: Int; let qty: Double; let modifiers: [Int]?
    enum CodingKeys: String, CodingKey { case productId = "product_id", qty, modifiers }
}
/// Адрес доставки — ОБЪЕКТОМ, 1:1 с AddressReq Android-клиента.
///
/// Раньше сюда уходила готовая строка. Сервер кладёт значение в
/// orders.address_json как есть, а панель продавца и приложение курьера читают
/// из него поля (city/street/house/apartment): из строки они получали
/// undefined, и адрес доставки у продавца и курьера был ПУСТОЙ. Плюс сервер не
/// находил в адресе координаты и никогда не считал время в пути (eta_minutes).
private struct OrderAddressBody: Encodable {
    let label: String?
    let city: String?
    let street: String?
    let house: String?
    let apartment: String?
    let entrance: String?
    let floor: String?
    let intercom: String?
    let lat: Double?
    let lng: Double?
}
private struct OrderBody: Encodable {
    let shopId: Int; let items: [OrderItemBody]; let deliveryType: String
    let paymentType: String; let address: OrderAddressBody?; let comment: String?
    let deliveryPrice: Double?
    let lat: Double?; let lng: Double?
    /// Тумблер «оплатить баллами»: сервер сам спишет min(баланс, потолок).
    /// Сумму на клиенте не считаем — источник правды один.
    let spendPointsAll: Bool
    /// Ключ идемпотентности (один на экран оформления): если ответ на создание
    /// заказа потерялся по таймауту, повторное нажатие вернёт уже созданный
    /// заказ, а не создаст второй.
    let idempotencyKey: String
    /// Номер стола для «За столик» и промокод (аддитивно; сервер принимает оба,
    /// Android их уже шлёт). Nil-поля в JSON не попадают.
    let tableNumber: String?
    let promoCode: String?
    /// Предзаказ у закрытого заведения: "YYYY-MM-DD HH:MM" по Москве (ОТВЕТЫ-САЙТА п. 7 к П-24).
    let preorderAt: String?
    /// «Нужна сдача с …» при оплате наличными — как на сайте (checkout.js
    /// change_from). Сервер принимает поле (api_v1.php, payment_note), а
    /// приложение его не слало. nil — в JSON не попадает.
    var changeFrom: String? = nil
    enum CodingKeys: String, CodingKey {
        case shopId = "shop_id", items, deliveryType = "delivery_type", paymentType = "payment_type",
             address, comment, deliveryPrice = "delivery_price", lat, lng,
             spendPointsAll = "spend_points_all", idempotencyKey = "idempotency_key",
             tableNumber = "table_number", promoCode = "promo_code", preorderAt = "preorder_at",
             changeFrom = "change_from"
    }
}
/// Ответ POST api/v1/promo/check.
private struct PromoCheckResult: Decodable {
    @LenientDecimal var discount: Decimal?
    let type: String?
    // Ключи без CodingKeys: декодер API сам переводит free_delivery → freeDelivery.
    let freeDelivery: Bool?
    /// Код-условие АКЦИИ: сервер отвечает discount 0 и promotion: true
    /// (api_v1.php, promo/check) — скидку считает движок акций при пересчёте.
    let promotion: Bool?
}
// Тело расчёта доставки (совпадает со старым клиентом).
// `address` нужен заведениям БЕЗ зон доставки: у них цена одна на весь город,
// и сервер по городу из адреса решает, возят ли туда. Координат у такого адреса
// может не быть вовсе. Поле опциональное — для заведений с зонами запрос тот же.
private struct QuoteAddressBody: Encodable {
    let value: String?
    let city: String?
    let street: String?
    let house: String?
}
private struct QuoteBody: Encodable { let shopId: Int; let lat: Double; let lng: Double; let subtotal: Double
    var address: QuoteAddressBody? = nil
    enum CodingKeys: String, CodingKey { case shopId = "shop_id", lat, lng, subtotal, address } }

// Тело создания адреса (POST api/v1/profile/addresses). camelCase → snake_case автоматически.
// Совпадает 1:1 с AddressBody профиля и AddressReq Android.
private struct NewAddressBody: Encodable {
    let label: String
    let city: String?
    let street: String
    let house: String?
    let apartment: String?
    let entrance: String?
    let floor: String?
    let intercom: String?
    let lat: Double?
    let lng: Double?
}

// Способ получения (в макете 3 сегмента; delivery/pickup + за столик = dine_in).
private enum Fulfillment: String, CaseIterable, Hashable {
    case delivery, pickup, dineIn
    var apiValue: String { self == .dineIn ? "dine_in" : rawValue }
    var title: String {
        switch self {
        case .delivery: return "Доставка"
        case .pickup:   return "Самовывоз"
        case .dineIn:   return "За столик"
        }
    }
}

// Способ оплаты при получении: «Наличные» или «Картой» курьеру/на месте.
// Онлайн-оплаты на экране оформления нет — ни редиректа на ЮKassa, ни
// подтверждения платежа, поэтому и значения соответствующие. Так же на Android.
private enum Payment: String, CaseIterable, Hashable {
    // sbp — «СБП по QR-коду» при получении, как на сайте (checkout.js PAY_LABEL).
    // Сервер его принимает (api_v1.php), а заведение, включившее только СБП,
    // раньше было не оформить: экран давал наличные/карту, сервер отказывал.
    case cash, card, sbp
    // Значения из белого списка сервера: cash | card_courier | sbp | online_card
    // (routes/api_v1.php). Всё прочее сервер молча заменяет на "cash" — и раньше
    // "online" именно так и превращалось в наличные: человек выбирал «Картой»,
    // а курьер приезжал за наличными.
    var apiValue: String {
        switch self {
        case .cash: return "cash"
        case .card: return "card_courier"
        case .sbp:  return "sbp"
        }
    }
    var title: String {
        switch self {
        case .cash: return "Наличные"
        case .card: return "Картой"
        case .sbp:  return "СБП"
        }
    }
}

struct CheckoutView: View {
    var onSuccess: (OrderCreateResult) -> Void = { _ in }
    var onBack: () -> Void = {}

    @ObservedObject private var cart = Cart.shared
    /// Сессия: истекла посреди оформления — раньше оставалась только надпись
    /// «Сессия истекла, войдите снова» без кнопки входа; вошёл другой человек
    /// при открытом оформлении — на экране оставались адреса прежнего.
    @ObservedObject private var session = Session.shared
    @State private var showAuth = false
    /// Промокод, применённый до выхода из аккаунта: после входа проверяем его заново.
    @State private var reapplyCode: String?
    /// Выбранный до выхода адрес: тот же человек вошёл снова — выбираем его же
    /// (у другого человека такого id нет, ему — адрес по умолчанию).
    @State private var reselectAddressId: Int?

    @State private var fulfillment: Fulfillment = .delivery
    @State private var payment: Payment = .cash
    @State private var addresses: [Address] = []
    /// Список адресов не загрузился (сеть/сервер).
    @State private var addressesError: String?
    @State private var selectedAddress: Address?
    @State private var shop: ShopDetail?
    /// Карточка заведения не загрузилась: сбор, способы и «открыто» неизвестны —
    /// раньше оформление шло на значениях по умолчанию (итог без сбора).
    @State private var shopLoadError: String?
    @State private var quote: DeliveryQuote?
    /// Сумма товаров, по которой считан quote (после скидок и баллов).
    @State private var quotedGoods: Double?
    @State private var comment = ""
    /// «Когда»: как можно скорее (false) или ко времени (true), как на сайте.
    /// У закрытого заведения — только ко времени (предзаказ).
    @State private var byTime = false
    /// Выбранное время: "YYYY-MM-DD HH:MM" по Москве или nil.
    @State private var preorderAt: String?
    @State private var placing = false
    @State private var errorText: String?
    /// Почему не посчиталась доставка (обрыв связи, 5xx). Раньше ошибка
    /// проглатывалась: кнопка «Оформить заказ» просто становилась серой и
    /// молчала — человек жал в неё и не понимал, что происходит.
    @State private var quoteError: String?

    // Движок акций и баллов: сервер считает ВСЁ (автоматические акции, подарки,
    // бесплатную доставку, потолок списания баллов и начисление). Клиент только
    // показывает результат. Раньше приложение об этом не знало вовсе: акция
    // применялась молча при создании заказа, и человек до последнего экрана
    // видел цену без скидки, а баллами заплатить было нельзя.
    @State private var promo: PromoPreview?
    @State private var spendPoints = false
    @State private var promoTask: Task<Void, Never>?
    /// Пересчёт акций/баллов ещё идёт. Пока он не вернулся, итог на кнопке — от
    /// прежнего состояния: сняли «Оплатить баллами» — кнопка ещё показывала сумму
    /// со списанием, а сервер брал полную. Кнопку держим до ответа.
    @State private var promoPending = false
    @State private var showAddAddress = false
    // «За столик»: номер стола уходит в заказ (раньше не отправлялся вовсе).
    @State private var tableNumber = ""
    // Промокод: проверка через api/v1/promo/check, код уходит в заказ.
    @State private var promoInput = ""
    @State private var appliedCode: String?
    @State private var codeDiscount: Decimal = 0
    @State private var codeFree = false
    @State private var codeMsg: String?
    @State private var checkingCode = false
    /// «Сдача с» (только для наличных) — уходит в заказ как change_from.
    @State private var changeFrom = ""
    /// Поле ввода в фокусе (клавиатура открыта): тогда нижняя панель сжимается
    /// до «Готово», чтобы не закрывать поле над клавиатурой.
    private enum Field: Hashable { case table, promo, comment, change }
    @FocusState private var field: Field?

    // Город из настроек — клиент его НЕ вводит (шапка «Ваш город»).
    private var cityName: String { Session.shared.cityName ?? "" }

    // MARK: - Деньги (всё Decimal)

    private var subtotal: Decimal { Money.parse(cart.total) }

    // Стоимость доставки — ТОЛЬКО из серверного расчёта по адресу. До адреса / при
    // недоступности / для самовывоза-и-стола → 0.
    private var deliveryCost: Decimal {
        guard fulfillment == .delivery, let q = quote, q.available else { return 0 }
        return Money.parse(q.deliveryPrice ?? 0)
    }
    private var serviceFee: Decimal { Money.parse(Fees.service(subtotal: cart.total, shop: shop)) }

    // Итоги: если сервер посчитал акции — используем ЕГО числа, иначе прежний
    // локальный расчёт (старый сервер, обрыв связи — оформление не блокируем).
    private var freeDelivery: Bool { promo?.freeDelivery == true || (appliedCode != nil && codeFree) }
    private var effectiveDelivery: Decimal { freeDelivery ? 0 : deliveryCost }
    private var promoDiscount: Decimal { Money.parse(promo?.discount ?? 0) }
    private var pointsSpent: Decimal { Money.parse(promo?.pointsSpent ?? 0) }
    private var pointsEarned: Decimal { Money.parse(promo?.pointsEarned ?? 0) }
    private var pointsMax: Decimal { Money.parse(promo?.pointsSpendMax ?? 0) }
    /// Скидка промокода (не больше суммы товаров — как на сервере).
    private var codeOff: Decimal { appliedCode == nil ? 0 : min(codeDiscount, subtotal) }
    private var grandTotal: Decimal {
        max(0, subtotal + effectiveDelivery + serviceFee - promoDiscount - codeOff - pointsSpent)
    }

    /// Проверить/применить промокод. silent — перепроверка после изменения корзины.
    private func applyCode(_ raw: String, silent: Bool = false) async {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let sid = cart.shopId else { return }
        await MainActor.run { checkingCode = true; if !silent { codeMsg = nil } }
        let subtotalD = NSDecimalNumber(decimal: subtotal).doubleValue
        do {
            let r: PromoCheckResult = try await API.shared.post(
                "api/v1/promo/check", body: PromoCheckBody(code: code, subtotal: subtotalD, shopId: sid))
            await MainActor.run {
                checkingCode = false
                // Тихая перепроверка, а код за это время убрали («Убрать») или
                // сменили — ответ по старому коду не должен вернуть его в заказ.
                if silent && appliedCode != code { return }
                let d = r.discount ?? 0
                // Код-условие акции (promotion: true, скидка 0): код оставляем —
                // он уходит в предпросмотр и в заказ, скидку считает движок акций.
                // Раньше такой код снимался как «не даёт скидки», и акция по
                // промокоду в приложении не срабатывала (на сайте — срабатывала).
                let isPromotion = r.promotion == true || r.type == "promotion"
                if isPromotion && d <= 0 && r.freeDelivery != true {
                    appliedCode = code; codeDiscount = 0; codeFree = false
                    codeMsg = "Промокод принят — скидка появится в итогах, если выполнены условия акции"
                } else if d > 0 || r.freeDelivery == true {
                    appliedCode = code; codeDiscount = d; codeFree = r.freeDelivery == true
                    codeMsg = r.freeDelivery == true ? "Промокод применён: бесплатная доставка" : "Промокод применён: −" + Money.format(d)
                } else {
                    appliedCode = nil; codeDiscount = 0; codeFree = false
                    codeMsg = "Промокод не даёт скидки на этот заказ"
                }
                refreshPromo()
            }
        } catch {
            await MainActor.run {
                checkingCode = false
                if silent && appliedCode != code { return }
                // Тихая перепроверка не дошла (нет сети, таймаут, 5xx) — код не
                // снимаем: раньше скидка пропадала из-за обрыва связи. Сервер всё
                // равно проверит код при оформлении.
                if silent, error is CancellationError { return }
                if silent, (error as? APIError)?.isRetryable == true {
                    // Скидка осталась прежней, но не подтверждена — честно говорим об этом.
                    codeMsg = "Промокод проверим при оформлении"
                    return
                }
                appliedCode = nil; codeDiscount = 0; codeFree = false
                codeMsg = (error as? LocalizedError)?.errorDescription ?? "Промокод не подошёл"
                refreshPromo()
            }
        }
    }

    /// Пересчёт акций на сервере. Дебаунс 350 мс: зовётся на каждое изменение
    /// корзины, способа получения, адреса и тумблера баллов.
    private func refreshPromo() {
        promoTask?.cancel()
        guard let sid = cart.shopId, !cart.isEmpty else { promo = nil; promoPending = false; return }
        promoPending = true
        let body = PromoPreviewRequest(
            shopId: sid,
            items: cart.lines.map { PromoCartItem(productId: $0.productId, qty: $0.qty, modifiers: $0.modifierIds) },
            deliveryType: fulfillment.apiValue,
            deliveryPrice: NSDecimalNumber(decimal: deliveryCost).doubleValue,
            promoCode: appliedCode,
            spendPoints: 0,
            spendPointsAll: spendPoints
        )
        promoTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let r: PromoPreview? = try? await API.shared.post("api/v1/cart/promo-preview", body: body)
            // Отменённый запрос (его сменил следующий пересчёт) через try? даёт nil —
            // раньше это гасило тумблер «Оплатить баллами» и мигало карточкой акции.
            if Task.isCancelled { return }
            await MainActor.run {
                promo = r
                promoPending = false
                // Списывать нечего — тумблер сам гаснет.
                if (r?.pointsSpendMax ?? 0) <= 0 { spendPoints = false }
                // Скидка/баллы изменили оплачиваемую сумму — пересчитываем доставку:
                // «бесплатно от» и минимум считаются от неё (как на сервере).
                if fulfillment == .delivery, quote != nil, let qg = quotedGoods, abs(qg - goodsForQuote) >= 0.01 {
                    Task { await quoteDelivery() }
                }
            }
        }
    }

    // MARK: - Блокировка CTA (паритет с Android: outOfZone / noAddress / belowMin)

    // Адрес вне зоны доставки: сервер вернул quote.available == false.
    private var outOfZone: Bool {
        fulfillment == .delivery && quote != nil && quote?.available == false
    }
    /// У заведения нет ни одной зоны доставки → цена единая по его городу, и
    /// координаты адреса не нужны: определять по ним нечего. Раньше их требовали
    /// всегда, и в малом городе доставку было не оформить вовсе — подсказки
    /// адресов часто не знают ни улицы, ни дома. Карточка ещё не пришла
    /// (`deliveryZones == nil`) → считаем, что зоны есть: безопасный откат.
    private var shopNoZones: Bool { shop?.deliveryZones?.isEmpty == true }
    // Для доставки обязателен выбранный адрес. Координаты — только там, где по
    // ним определяется зона; у заведения без зон адреса строкой достаточно.
    private var noAddress: Bool {
        guard fulfillment == .delivery else { return false }
        if selectedAddress == nil { return true }
        if shopNoZones { return false }
        return selectedAddress?.lat == nil || selectedAddress?.lng == nil
    }
    // Минимальная сумма не набрана.
    private var belowMin: Bool {
        fulfillment == .delivery && quote?.belowMin == true
    }
    // Доставка ещё не посчитана (быстрое нажатие или сбой расчёта): раньше
    // заказ уходил с «Доставка: уточняется» и итогом без доставки, а сервер
    // добавлял цену зоны — человек платил больше, чем подтвердил.
    private var quoteMissing: Bool {
        fulfillment == .delivery && !noAddress && quote == nil
    }
    /// Способы получения, которые заведение реально принимает. Сервер отдаёт
    /// их в карточке (`fulfillment`), а раньше экран всегда рисовал все три и
    /// отказ приходил на последнем шаге: «Способ „Доставка“ сейчас недоступен».
    private var allowedFulfillment: [Fulfillment] {
        guard let list = shop?.fulfillment, !list.isEmpty else { return Fulfillment.allCases }
        let allowed = Fulfillment.allCases.filter { list.contains($0.apiValue) }
        return allowed.isEmpty ? Fulfillment.allCases : allowed
    }
    /// Способы оплаты, которые принимает заведение (аналогично).
    /// СБП — только если заведение явно включило "sbp" (как Android; решение
    /// владельца по СБП ещё не принято). Способы не настроены — прежняя пара.
    private var allowedPayments: [Payment] {
        let fallback: [Payment] = [.cash, .card]
        guard let list = shop?.paymentMethods, !list.isEmpty else { return fallback }
        let allowed = Payment.allCases.filter { list.contains($0.apiValue) }
        return allowed.isEmpty ? fallback : allowed
    }
    /// П-27.1: заведение настроило способы получения и выключило все
    /// (delivery_methods_configured = true, список пуст) — сервер такой заказ
    /// не примет никаким способом. Нет поля (старый сервер) — false, как раньше.
    /// Услуги (mode == "service") не блокируем: у них fulfillment собран из
    /// типов услуг, а не из способов получения, и пустой список ничего не значит.
    private var fulfillmentNone: Bool {
        shop?.mode != "service"
            && shop?.deliveryMethodsConfigured == true && (shop?.fulfillment ?? []).isEmpty
    }
    /// П-27.1: то же для оплаты при получении (онлайн-оплаты на экране нет).
    private var paymentNone: Bool {
        shop?.paymentMethodsConfigured == true && (shop?.paymentMethods ?? []).isEmpty
    }
    /// П-27.1: заведение требует номер стола для заказа в зале, а он пуст.
    /// Так же проверяет сайт при оформлении; без поля — как раньше, не обязателен.
    private var tableMissing: Bool {
        fulfillment == .dineIn && shop?.dineInTableRequired == true
            && tableNumber.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Заведение закрыто прямо сейчас (считает сервер — часы работы заданы его
    /// временем, а не временем телефона).
    private var shopClosed: Bool { shop?.isOpen == false }

    /// Нужно ли время: закрыто (предзаказ) или выбрано «Ко времени».
    private var needTime: Bool { shopClosed || byTime }
    /// Дни и время — по графику заведения.
    private var preorderDays: [PreorderDay] {
        needTime ? PreorderSlots.build(shop?.statusSchedule) : []
    }
    /// Выбранное время ещё есть в графике (день мог смениться, пока экран открыт).
    private var preorderValid: Bool {
        guard let p = preorderAt else { return false }
        return PreorderSlots.contains(preorderDays, p)
    }

    private func loadShop(_ slug: String) async {
        do {
            let loaded: ShopDetail = try await API.shared.get("api/v1/shops/\(slug)")
            // Пока грузили, корзина перешла к другому заведению — чужие условия не кладём.
            await MainActor.run { if cart.shopSlug == slug { shop = loaded; shopLoadError = nil } }
        } catch is CancellationError {
        } catch {
            await MainActor.run { shopLoadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить условия заведения" }
        }
    }

    private var ctaEnabled: Bool {
        // Заведение закрыто — заказ уходит предзаказом (preorder_at); без
        // выбранного времени сервер откажет, поэтому кнопка ждёт выбора.
        !placing && !cart.isEmpty && !outOfZone && !noAddress && !belowMin && !quoteMissing
            && (!needTime || preorderValid)
            && (cart.shopSlug == nil || shop != nil) && !promoPending
            && !fulfillmentNone && !paymentNone && !tableMissing
    }

    /// Почему «Оформить заказ» сейчас серая — коротко, прямо у кнопки. Причины
    /// были выше по экрану (а часть — нигде), у самой кнопки была тишина, и
    /// человек считал, что «кнопка не работает». Порядок — как в ctaEnabled.
    /// Короткие переходные состояния (загрузка карточки, пересчёт акций) не
    /// пишем, чтобы строка не мигала.
    private var ctaHint: String? {
        if ctaEnabled || placing || cart.isEmpty { return nil }
        if cart.shopSlug != nil && shop == nil {
            return shopLoadError == nil ? nil : "Не удалось загрузить условия заведения — нажмите на сообщение вверху"
        }
        // П-27.1: причины из настроек заведения (сервер отказал бы на последнем
        // шаге) — первыми: иначе под кнопкой стояла бы подсказка про адрес.
        if fulfillmentNone { return "Заведение сейчас не принимает заказы через приложение" }
        if paymentNone { return "Заведение сейчас не принимает оплату при получении" }
        if tableMissing { return "Укажите номер стола" }
        if noAddress {
            return selectedAddress == nil ? "Выберите или добавьте адрес доставки" : "У адреса нет точки на карте — добавьте его заново"
        }
        if outOfZone { return "Доставка по этому адресу недоступна" }
        if belowMin {
            let minSum = Money.format(Money.parse(quote?.minOrder ?? 0))
            return "Минимальная сумма заказа: " + minSum
        }
        if quoteMissing {
            return quoteError == nil ? "Считаем стоимость доставки…" : "Не удалось рассчитать доставку — нажмите «повторить» выше"
        }
        if needTime && !preorderValid {
            if preorderDays.isEmpty { return "В ближайшие 7 дней заведение не работает" }
            return shopClosed ? "Заведение закрыто — выберите время предзаказа выше" : "Выберите время выше"
        }
        return nil
    }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                scrollContent
                bottomCTA
            }
        }
        .navigationBarHidden(true)
        .sheet(isPresented: $showAddAddress, onDismiss: { Task { await loadAddresses() } }) {
            AddAddressSheet(cityName: cityName) { newAddr in
                // Свежесозданный адрес выбираем и сразу считаем доставку.
                selectedAddress = newAddr
                quote = nil; quotedGoods = nil; quoteError = nil
                Task { await loadAddresses(selectAfter: newAddr) }
            }
        }
        .task {
            await loadAddresses()
            if let slug = cart.shopSlug {
                await loadShop(slug)
                // Если заведение не принимает выбранный по умолчанию способ
                // (доставка/наличные) — сразу переключаемся на доступный, а не
                // ведём человека через весь экран к отказу сервера.
                await MainActor.run {
                    let fs = allowedFulfillment
                    if !fs.contains(fulfillment), let first = fs.first { fulfillment = first }
                    let ps = allowedPayments
                    if !ps.contains(payment), let first = ps.first { payment = first }
                }
                // Адреса считались до загрузки карточки заведения — тогда ещё не было
                // известно, что зон нет. Пересчитываем: иначе у заведения без зон и
                // адреса без координат висело «Считаем стоимость…», а кнопка молчала.
                await quoteDelivery()
            }
            refreshPromo()
        }
        .onChange(of: fulfillment) { _ in errorText = nil; Task { await quoteDelivery() }; refreshPromo() }
        // Корзина перешла к другому заведению, пока оформление было открыто во
        // вкладке «Корзина» (ушли в каталог, «Очистить и начать новую»): раньше
        // здесь оставались сбор, способы получения, «открыто» и цена доставки
        // прежнего заведения.
        .onChange(of: cart.shopId) { _ in reloadForShop() }
        .onChange(of: session.token) { _ in resetForAccount() }
        .onAppear { restoreDraft() }
        // Один параметр в onChange: двухпараметрический вариант — iOS 17, цель 16.0.
        .onChange(of: cart.lines.count) { _ in refreshPromo() }
        .onChange(of: cart.total) { _ in
            refreshPromo()
            // Скидка кода считается от суммы корзины — перепроверяем тихо.
            if let c = appliedCode { Task { await applyCode(c, silent: true) } }
        }
        .onChange(of: spendPoints) { _ in refreshPromo() }
        .onChange(of: selectedAddress?.id) { _ in refreshPromo() }
    }

    // MARK: - Header «‹ Оформление»

    private var header: some View {
        HStack(spacing: YMSpace.md) {
            Button(action: { Haptics.light(); onBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            // Пока заказ создаётся, назад нельзя: вернулся в корзину, поменял её, а
            // пришедший ответ очищал уже новую корзину и показывал «Заказ оформлен»
            // со старым составом.
            .disabled(placing)
            Text("Оформление")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            Spacer()
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.xs)
        .padding(.bottom, YMSpace.md)
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                storeBanner
                    .padding(.bottom, YMSpace.md)

                if shop == nil, let e = shopLoadError, let slug = cart.shopSlug {
                    Button {
                        Task {
                            await loadShop(slug)
                            await MainActor.run {
                                let fs = allowedFulfillment
                                if !fs.contains(fulfillment), let first = fs.first { fulfillment = first }
                                let ps = allowedPayments
                                if !ps.contains(payment), let first = ps.first { payment = first }
                            }
                            await quoteDelivery()
                        }
                    } label: {
                        Text("Не удалось загрузить условия заведения: \(e). Нажмите, чтобы повторить")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, YMSpace.sm)
                }


                SectionKicker("Способ получения").padding(.top, YMSpace.xs).padding(.bottom, YMSpace.sm)
                YMSegmented(options: allowedFulfillment, selection: $fulfillment) { $0.title }

                if fulfillment == .dineIn {
                    tableField.padding(.top, YMSpace.md)
                }
                // Паритет с Android и сайтом: при самовывозе — где забирать.
                if fulfillment == .pickup {
                    pickupCard.padding(.top, YMSpace.md)
                }
                // «Когда» — как на сайте: как можно скорее или ко времени (день и
                // время в часы работы). Закрыто — только ко времени (предзаказ).
                if shop != nil {
                    whenSection.padding(.top, YMSpace.md)
                }
                if fulfillment == .delivery {
                    addressSelector.padding(.top, YMSpace.md)
                    if quoteMissing {
                        Button {
                            Task { await quoteDelivery() }
                        } label: {
                            Text(quoteError == nil
                                 ? "Считаем стоимость доставки… Нажмите, чтобы повторить"
                                 : "Не удалось рассчитать доставку: \(quoteError!). Нажмите, чтобы повторить")
                                .font(YMFont.caption)
                                .foregroundStyle(quoteError == nil ? YMColor.muted : YMColor.statusCancel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, YMSpace.sm)
                    }
                    if outOfZone {
                        Text(quote?.reason?.isEmpty == false ? quote!.reason! : "Доставка по этому адресу недоступна")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, YMSpace.sm)
                    }
                    // Адрес выбран, но без координат, а зона считается по ним: кнопка
                    // была серой без единого слова — человек не понимал, что не так.
                    // Только после карточки заведения: без неё неизвестно, есть ли зоны.
                    if selectedAddress != nil && noAddress && (shop != nil || cart.shopSlug == nil) {
                        Text("У этого адреса нет точки на карте — зону доставки не определить. Добавьте адрес заново, выбрав улицу из подсказок.")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, YMSpace.sm)
                    }
                }

                SectionKicker("Ваш заказ").padding(.top, YMSpace.lg).padding(.bottom, YMSpace.md)
                VStack(spacing: YMSpace.md) {
                    ForEach(cart.lines) { line in CheckoutRow(line: line) }
                }

                SectionKicker("Оплата").padding(.top, YMSpace.lg).padding(.bottom, YMSpace.sm)
                YMSegmented(options: allowedPayments, selection: $payment) { $0.title }
                // Как на сайте: при СБП — как будет проходить оплата; при
                // наличных — «Сдача с» (cart.php / checkout.js).
                if payment == .sbp {
                    Text("После подтверждения заказа продавец пришлёт QR-код для оплаты по СБП.")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, YMSpace.sm)
                }
                if payment == .cash {
                    changeField.padding(.top, YMSpace.md)
                }

                commentField.padding(.top, YMSpace.lg)

                promoCodeField.padding(.top, YMSpace.md)

                promoCard

                totalsCard.padding(.top, YMSpace.lg)

                // Ошибка оформления теперь над кнопкой (bottomCTA): в самом низу
                // прокрутки её не было видно — нажал «Оформить», и ничего.
                Color.clear.frame(height: YMSpace.lg)
            }
            .padding(.horizontal, YMSpace.xl)
        }
        // Клавиатура убирается жестом прокрутки (как в корзине).
        .scrollDismissesKeyboard(.interactively)
    }

    private var storeBanner: some View {
        HStack(spacing: YMSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(YMColor.surface2)
                Text(monogram).font(.system(size: 17, weight: .heavy)).foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(cart.shopName ?? "Магазин").font(.system(size: 14.5, weight: .bold)).foregroundStyle(YMColor.text)
                // cart.count — число штук, а не позиций: одна позиция ×3 читалась
                // как «3 поз.». Слово то же, что в корзине.
                Text("В заказе \(cart.count) \(ruItemsWord(cart.count))").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var monogram: String {
        let s = (cart.shopName ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "•" : String(s.prefix(1)).uppercased()
    }

    // MARK: - Выбор сохранённого адреса (радио-строки) + «＋ Добавить новый адрес»

    private var addressSelector: some View {
        VStack(spacing: YMSpace.xs) {
            if addresses.isEmpty, let e = addressesError {
                // Сбой сети — не «нет адресов»: иначе человек заводил адрес заново.
                Button { Task { await loadAddresses() } } label: {
                    Text("Не удалось загрузить адреса: \(e). Нажмите, чтобы повторить")
                        .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            } else if addresses.isEmpty {
                Text("Нет сохранённых адресов")
                    .font(YMFont.subhead).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 10)
            } else {
                ForEach(addresses) { a in
                    Button(action: { Haptics.light(); selectAddress(a) }) {
                        addressRow(a)
                    }
                    .buttonStyle(.plain)
                }
            }

            // ＋ Добавить новый адрес. П-25 №6: сервер хранит не больше 50 —
            // на пределе кнопку не показываем, а говорим почему.
            if addresses.count >= 50 {
                Text("Сохранено 50 адресов — это максимум. Удалите ненужный в профиле, чтобы добавить новый.")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
            } else {
                Button(action: { Haptics.light(); showAddAddress = true }) {
                    HStack(spacing: YMSpace.sm) {
                        Text("＋").font(.system(size: 17, weight: .bold)).foregroundStyle(YMColor.accent)
                        Text("Добавить новый адрес")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(YMColor.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 12)
                }
                .buttonStyle(.plain)
            }

            // ETA доставки / минимум — только для выбранного адреса.
            // Ко времени / предзаказ: «30–45 мин» сбивало — заказ привезут к
            // выбранному времени, а не через столько минут.
            if !needTime, let q = quote, q.available, let tmin = q.timeMin, let tmax = q.timeMax, tmax > 0 {
                // «0–30» у зоны = «до 30 мин», равные границы — «~30 мин» (как на Android).
                Text(Self.etaText(tmin, tmax))
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 2)
            }
            if let hint = freeDeliveryHint {
                Text(hint)
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 2)
            }
            if belowMin, let q = quote {
                Text("Минимальная сумма заказа: \(Money.format(Money.parse(q.minOrder ?? 0)))")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 2)
            }
        }
        .padding(YMSpace.xs)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    /// «30–45 мин»; нижняя граница 0 — «до 30 мин»; равные границы — «~30 мин».
    static func etaText(_ lo: Int, _ hi: Int) -> String {
        if lo <= 0 { return "до \(hi) мин" }
        if lo >= hi { return "~\(hi) мин" }
        return "\(lo)–\(hi) мин"
    }

    private func addressRow(_ a: Address) -> some View {
        let isSel = selectedAddress?.id == a.id
        return HStack(spacing: YMSpace.md) {
            // radio-индикатор
            ZStack {
                Circle().strokeBorder(isSel ? YMColor.accent : YMColor.hairline, lineWidth: 2)
                if isSel { Circle().fill(YMColor.accent).frame(width: 10, height: 10) }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(a.label?.isEmpty == false ? a.label! : "Адрес")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(YMColor.text)
                Text(a.display.isEmpty ? "Адрес без деталей" : a.display)
                    .font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 10)
        .background(isSel ? YMColor.surface2 : Color.clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }

    private var tableField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "number").font(.system(size: 15)).foregroundStyle(YMColor.muted)
            // П-27.1: заведение требует номер стола — так и пишем в поле.
            TextField(shop?.dineInTableRequired == true ? "Номер стола (обязательно)" : "Номер стола", text: $tableNumber)
                .focused($field, equals: .table)
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.text)
                .tint(YMColor.accent)
                .onChange(of: tableNumber) { v in CheckoutDraft.shopId = cart.shopId; CheckoutDraft.table = v }
                // П-25 №6: table_number сервер хранит до 20 знаков.
                .ymMaxLength($tableNumber, 20)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    /// Самовывоз: «Заберёте заказ в заведении» и адрес заведения (как Android).
    private var pickupCard: some View {
        HStack(alignment: .top, spacing: YMSpace.sm) {
            Image(systemName: "bag").font(.system(size: 15)).foregroundStyle(YMColor.muted)
            VStack(alignment: .leading, spacing: 2) {
                Text("Заберёте заказ в заведении")
                    .font(.system(size: 13.5)).foregroundStyle(YMColor.text)
                if let a = pickupAddress {
                    Text(a).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // П-27.1: пояснение продавца к самовывозу («вход со двора»…).
                if let c = shop?.pickupComment?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
                    Text(c).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var pickupAddress: String? {
        // П-27.1: у самовывоза бывает свой адрес (точка выдачи); нет — адрес заведения.
        let own = (shop?.pickupAddress ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !own.isEmpty { return own }
        let a = (shop?.address ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? nil : a
    }

    /// «Сдача с» — необязательное поле для наличных (сервер хранит до 100 знаков).
    private var changeField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "banknote").font(.system(size: 15)).foregroundStyle(YMColor.muted)
            TextField("Сдача с (сумма купюры, необязательно)", text: $changeFrom)
                .focused($field, equals: .change)
                .keyboardType(.numberPad)
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.text)
                .tint(YMColor.accent)
                .ymMaxLength($changeFrom, 9)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var promoCodeField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: YMSpace.sm) {
                Image(systemName: "ticket").font(.system(size: 15)).foregroundStyle(YMColor.muted)
                TextField("Промокод", text: $promoInput)
                    .focused($field, equals: .promo)
                    .font(.system(size: 13.5))
                    .foregroundStyle(YMColor.text)
                    .tint(YMColor.accent)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    // Применённый код правился в поле, а в заказ уходил прежний:
                    // на экране один код, в заказе другой. Сменить — через «Убрать».
                    .disabled(appliedCode != nil)
                if appliedCode != nil {
                    Button("Убрать") {
                        appliedCode = nil; codeDiscount = 0; codeFree = false; codeMsg = nil; promoInput = ""
                        refreshPromo()
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                } else {
                    Button(checkingCode ? "…" : "Применить") {
                        Task { await applyCode(promoInput) }
                    }
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
                    .disabled(checkingCode || promoInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            if let m = codeMsg {
                Text(m).font(YMFont.caption)
                    .foregroundStyle(appliedCode != nil ? YMColor.accent : YMColor.statusCancel)
            }
        }
        .onChange(of: appliedCode) { c in CheckoutDraft.shopId = cart.shopId; CheckoutDraft.promo = c }
    }

    private var commentField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "square.and.pencil").font(.system(size: 15)).foregroundStyle(YMColor.muted)
            TextField("Комментарий к заказу…", text: $comment, axis: .vertical)
                .focused($field, equals: .comment)
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.text)
                .tint(YMColor.accent)
                .onChange(of: comment) { v in CheckoutDraft.shopId = cart.shopId; CheckoutDraft.comment = v }
                // П-25 №6: comment заказа сервер молча режет до 490 знаков.
                .ymMaxLength($comment, 490)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(YMColor.hairline)
        )
    }

    // Акции, подарки и списание баллов — то, что посчитал сервер.
    // Карточки нет, если движок ничего не нашёл: экран остаётся прежним (и на
    // старом сервере без ручки предпросмотра — тоже).
    @ViewBuilder
    private var promoCard: some View {
        let applied = promo?.applied ?? []
        let gifts = promo?.gifts ?? []
        if !applied.isEmpty || !gifts.isEmpty || pointsMax > 0 {
            VStack(alignment: .leading, spacing: 9) {
                if !applied.isEmpty {
                    Text("Акции").font(YMFont.headline).foregroundStyle(YMColor.text)
                    ForEach(applied) { a in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.name).font(.system(size: 13.5)).foregroundStyle(YMColor.text)
                                if let d = a.description, !d.isEmpty {
                                    Text(d).font(YMFont.caption).foregroundStyle(YMColor.muted)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(promoBadge(a))
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(YMColor.accent)
                        }
                    }
                }
                if !gifts.isEmpty {
                    Text("Подарки").font(YMFont.headline).foregroundStyle(YMColor.text)
                    ForEach(gifts) { g in
                        HStack {
                            Text((g.name ?? "Подарок") + ((g.qty ?? 1) > 1 ? " ×\(Int(g.qty ?? 1))" : ""))
                                .font(.system(size: 13.5)).foregroundStyle(YMColor.text)
                            Spacer()
                            Text("бесплатно").font(.system(size: 13.5, weight: .semibold)).foregroundStyle(YMColor.accent)
                        }
                    }
                }
                if pointsMax > 0 {
                    Toggle(isOn: $spendPoints) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Оплатить баллами").font(.system(size: 13.5)).foregroundStyle(YMColor.text)
                            Text(spendPoints && pointsSpent > 0
                                 ? "Списываем \(Money.format(pointsSpent))"
                                 : "Доступно до \(Money.format(pointsMax))")
                                .font(YMFont.caption).foregroundStyle(YMColor.muted)
                        }
                    }
                    .tint(YMColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.lg)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            .padding(.top, YMSpace.lg)
        }
    }

    private func promoBadge(_ a: AppliedPromo) -> String {
        if let d = a.discount, d > 0 { return "−" + Money.format(Money.parse(d)) }
        if a.freeDelivery == true { return "доставка бесплатно" }
        if let p = a.points, p > 0 { return "+" + Money.format(Money.parse(p)) + " баллов" }
        return ""
    }

    // Итоги: Товары / Доставка / Сервисный сбор / Скидка / Баллы.
    private var totalsCard: some View {
        VStack(spacing: 9) {
            totalRow("Товары (\(cart.count))", Money.format(subtotal))
            if fulfillment == .delivery {
                totalRow("Доставка", deliveryLabel)
            }
            if serviceFee > 0 {
                totalRow("Сервисный сбор", Money.format(serviceFee))
            }
            if promoDiscount > 0 {
                totalRow("Скидка по акции", "−" + Money.format(promoDiscount), accent: true)
            }
            if codeOff > 0 {
                totalRow("Промокод", "−" + Money.format(codeOff), accent: true)
            }
            if pointsSpent > 0 {
                totalRow("Оплачено баллами", "−" + Money.format(pointsSpent), accent: true)
            }
            if pointsEarned > 0 {
                totalRow("Вернётся баллами", Money.format(pointsEarned), accent: true)
            }
        }
        .padding(YMSpace.lg)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var deliveryLabel: String {
        if freeDelivery { return "бесплатно" }
        guard let q = quote else { return "уточняется" }
        if !q.available { return "недоступна" }
        return deliveryCost <= 0 ? "бесплатно" : Money.format(deliveryCost)
    }

    private func totalRow(_ label: String, _ value: String, accent: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(accent ? YMColor.accent : YMColor.muted)
            Spacer()
            Text(value).font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(accent ? YMColor.accent : YMColor.muted)
        }
    }

    // MARK: - Bottom CTA «Оформить заказ · СУММА»

    private static let whenOptions: [Bool] = [false, true]
    private static func whenTitle(_ byTime: Bool) -> String {
        byTime ? "Ко времени" : "Как можно скорее"
    }

    private var whenTitle: String {
        switch fulfillment {
        case .delivery: return "Когда доставить"
        case .dineIn: return "Когда придёте"
        default: return "Когда приготовить"
        }
    }

    private var whenSection: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            SectionKicker(whenTitle)
            if !shopClosed {
                YMSegmented(options: Self.whenOptions, selection: $byTime, title: Self.whenTitle)
            }
            if needTime {
                PreorderPickerView(statusText: shop?.statusText, days: preorderDays,
                                   selection: $preorderAt, closed: shopClosed)
            }
        }
    }

    private var ctaTitle: String {
        let sum = Money.format(grandTotal)
        if shopClosed { return "Оформить предзаказ · " + sum }
        return "Оформить заказ · " + sum
    }

    private var bottomCTA: some View {
        VStack(spacing: YMSpace.md) {
            // Клавиатура открыта — вместо панели «Итого / Оформить» узкая
            // полоса «Готово»: высокая панель поднималась над клавиатурой и
            // закрывала поле (комментарий, промокод, стол), а у многострочного
            // комментария нет клавиши, которая убирает клавиатуру.
            if field != nil {
                keyboardDoneRow
            } else {
                ctaContent
            }
        }
        // Шторка входа — на нижней панели, а не на корне экрана: там уже висит
        // шторка нового адреса, а две .sheet на одной вьюхе SwiftUI путает.
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false })
            }
            .environmentObject(Session.shared)
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, field == nil ? YMSpace.lg : YMSpace.sm)
        .padding(.bottom, field == nil ? YMSpace.xxl : YMSpace.sm)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { YMColor.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var keyboardDoneRow: some View {
        HStack {
            Spacer()
            Button("Готово") { field = nil }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YMColor.accent)
        }
    }

    @ViewBuilder private var ctaContent: some View {
        HStack {
            Text("Итого").font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
            Spacer()
            Text(Money.format(grandTotal)).font(.system(size: 22, weight: .heavy)).foregroundStyle(YMColor.text)
        }
        if let e = errorText {
            Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        if !session.isLoggedIn && !placing {
            // Сессия истекла (или вышли из аккаунта в профиле), а оформление
            // открыто: войти отсюда, корзина и введённое остаются.
            Button(action: { Haptics.light(); showAuth = true }) {
                Text("Войти, чтобы оформить заказ")
            }
            .buttonStyle(YMPrimaryButtonStyle())
        } else {
            Button(action: placeOrder) {
                HStack(spacing: YMSpace.sm) {
                    if placing { ProgressView().tint(YMColor.onAccent) }
                    Text(placing ? "Оформляем…" : ctaTitle)
                }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(!ctaEnabled)
        }
        // Причина серой кнопки — прямо под ней (см. ctaHint).
        if session.isLoggedIn, errorText == nil, let hint = ctaHint {
            Text(hint).font(YMFont.caption).foregroundStyle(YMColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Загрузка / расчёт

    // Загрузка списка адресов. selectAfter — если задан, выбрать именно его (после создания).
    private func loadAddresses(selectAfter: Address? = nil) async {
        do {
            let list: [Address] = try await API.shared.list("api/v1/profile/addresses")
            await MainActor.run {
                addresses = list
                addressesError = nil
                if let want = selectAfter,
                   let match = list.first(where: { $0.id == want.id }) ?? list.max(by: { $0.id < $1.id }) {
                    selectedAddress = match
                } else if selectedAddress == nil {
                    // По умолчанию — основной адрес (с координатами) → сразу считается доставка.
                    selectedAddress = list.first(where: { $0.isDefaultBool }) ?? list.first
                }
            }
            await quoteDelivery()
        } catch is CancellationError {
        } catch {
            // Список не пришёл: показываем причину и «повторить», а не «Нет
            // сохранённых адресов». Уже загруженный список не трогаем.
            await MainActor.run { addressesError = error.localizedDescription }
        }
    }

    private func selectAddress(_ a: Address) {
        selectedAddress = a
        // Цена доставки прежнего адреса не должна висеть для нового: раньше,
        // пока считался новый адрес, можно было оформить заказ по старой цене,
        // а сервер брал цену своей зоны.
        quote = nil; quotedGoods = nil; quoteError = nil
        errorText = nil   // «Выберите адрес доставки» и прочее от прошлой попытки
        Task { await quoteDelivery() }
    }

    // Серверный расчёт доставки по координатам адреса. shop_id — из корзины.
    private func quoteDelivery() async {
        guard fulfillment == .delivery,
              let a = selectedAddress,
              let sid = cart.shopId else {
            await MainActor.run { quote = nil; quoteError = nil }
            return
        }
        // Без зон расчёт нужен ТЕМ ЖЕ порядком, даже без координат: иначе экран
        // показал бы доставку нулевой, а сервер добавил бы к заказу единый
        // тариф — человек заплатил бы больше, чем видел.
        let noZones = await MainActor.run { shopNoZones }
        guard (a.lat != nil && a.lng != nil) || noZones else {
            await MainActor.run { quote = nil; quoteError = nil }
            return
        }
        let la = a.lat ?? 0
        let lo = a.lng ?? 0
        let goods = await MainActor.run { goodsForQuote }
        await MainActor.run { quoteError = nil }
        do {
            let q: DeliveryQuote = try await API.shared.post(
                "api/v1/delivery/quote",
                body: QuoteBody(
                    shopId: sid, lat: la, lng: lo, subtotal: goods,
                    address: QuoteAddressBody(
                        value: a.display, city: a.city, street: a.street, house: a.house
                    )
                )
            )
            // Пока считали, могли выбрать другой адрес или самовывоз: опоздавший
            // ответ клал цену и зону прежнего адреса на новый.
            // И заведение корзины то же: ответ по прежнему заведению (корзину
            // сменили, пока шёл расчёт) мог прийти последним и лечь на новое.
            let current = await MainActor.run { selectedAddress?.id == a.id && fulfillment == .delivery && cart.shopId == sid }
            guard current else { return }
            // Пересчёт акций — ПОСЛЕ расчёта доставки: движок должен видеть её цену
            // (иначе акция «бесплатная доставка от N» не сработает).
            await MainActor.run { quote = q; quotedGoods = goods; quoteError = nil; refreshPromo() }
        } catch is CancellationError {
            // Экран ушёл (смена вкладки) — это не ошибка. Раньше под адресом
            // появлялось английское «The operation couldn’t be completed…».
        } catch {
            let current = await MainActor.run { selectedAddress?.id == a.id && fulfillment == .delivery && cart.shopId == sid }
            guard current else { return }
            await MainActor.run {
                quote = nil
                quoteError = error.localizedDescription
            }
        }
    }

    /// «Сдача с» — только цифры (вставка из буфера могла принести пробелы и «₽»).
    private var changeDigits: String { changeFrom.filter { $0.isNumber } }

    /// Как на сайте (checkout.js): «Добавьте на N ₽ до бесплатной доставки»,
    /// когда доставка платная, а у зоны/тарифа есть порог free_from (он в расчёте
    /// доставки). Сравниваем с оплачиваемой суммой товаров — так считает сервер.
    private var freeDeliveryHint: String? {
        guard fulfillment == .delivery, !freeDelivery, let q = quote, q.available else { return nil }
        let price = Money.parse(q.deliveryPrice ?? 0)
        let from = Money.parse(q.freeFrom ?? 0)
        let goods = Money.parse(quotedGoods ?? goodsForQuote)
        guard price > 0, from > 0, goods < from else { return nil }
        return "Добавьте на " + Money.format(from - goods) + " до бесплатной доставки"
    }

    /// Что клиент платит за товары: корзина минус скидка и баллы (не меньше 0).
    private var goodsForQuote: Double {
        let paid = Money.parse(cart.total) - promoDiscount - codeOff - pointsSpent
        let v = NSDecimalNumber(decimal: max(0, paid)).doubleValue
        return (v * 100).rounded() / 100
    }

    /// Адрес доставки объектом — его читают и панель продавца, и курьер.
    private func addressBody() -> OrderAddressBody? {
        guard let a = selectedAddress else { return nil }
        func clean(_ v: String?) -> String? {
            guard let v, !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return v
        }
        return OrderAddressBody(
            label: clean(a.label) ?? "Адрес",
            city: clean(a.city), street: clean(a.street), house: clean(a.house),
            apartment: clean(a.apartment), entrance: clean(a.entrance),
            floor: clean(a.floor), intercom: clean(a.intercom),
            lat: a.lat, lng: a.lng
        )
    }

    // Полный адрес одной строкой — для экрана (в заказ уходит объект выше).
    private func composedAddress() -> String? {
        guard let a = selectedAddress else { return nil }
        var parts: [String] = []
        if let c = a.city, !c.isEmpty { parts.append(c) }
        if let st = a.street, !st.isEmpty {
            var line = st
            if let h = a.house, !h.isEmpty { line += ", д. \(h)" }
            parts.append(line)
        }
        if let ap = a.apartment, !ap.isEmpty { parts.append("кв. \(ap)") }
        if let en = a.entrance, !en.isEmpty { parts.append("подъезд \(en)") }
        if let fl = a.floor, !fl.isEmpty { parts.append("этаж \(fl)") }
        if let ic = a.intercom, !ic.isEmpty { parts.append("домофон \(ic)") }
        let s = parts.joined(separator: ", ")
        return s.isEmpty ? a.display : s
    }

    // MARK: - Создание заказа

    private func placeOrder() {
        guard ctaEnabled, let shopId = cart.shopId, !cart.isEmpty else { return }
        if fulfillment == .delivery {
            if selectedAddress == nil { errorText = "Выберите адрес доставки"; return }
            if let q = quote, !q.available { errorText = q.reason ?? "Доставка по этому адресу недоступна"; return }
            if let q = quote, q.belowMin == true {
                errorText = "Минимальная сумма заказа: \(Money.format(Money.parse(q.minOrder ?? 0)))"; return
            }
        }
        Haptics.medium()
        placing = true; errorText = nil

        let items = cart.lines.map {
            OrderItemBody(productId: $0.productId, qty: $0.qty,
                          modifiers: $0.modifierIds.isEmpty ? nil : $0.modifierIds)
        }
        let dp = fulfillment == .delivery ? NSDecimalNumber(decimal: deliveryCost).doubleValue : nil
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = OrderBody(
            shopId: shopId, items: items,
            deliveryType: fulfillment.apiValue,
            paymentType: payment.apiValue,   // "cash" | "card_courier" («Картой» — курьеру/на месте)
            address: fulfillment == .delivery ? addressBody() : nil,
            comment: trimmed.isEmpty ? nil : trimmed,
            deliveryPrice: dp,
            lat: fulfillment == .delivery ? selectedAddress?.lat : nil,
            lng: fulfillment == .delivery ? selectedAddress?.lng : nil,
            spendPointsAll: spendPoints,
            // Ключ живёт в корзине, а не в экране: после таймаута человек
            // возвращался в корзину и снова в оформление — новый экран слал
            // новый ключ, и создавался второй заказ.
            idempotencyKey: cart.checkoutKey,
            tableNumber: fulfillment == .dineIn && !tableNumber.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(tableNumber.trimmingCharacters(in: .whitespaces).prefix(20)) : nil,
            promoCode: appliedCode,
            preorderAt: needTime ? preorderAt : nil,
            // Только для наличных и только непустое — как сайт (change_from || null).
            changeFrom: payment == .cash && !changeDigits.isEmpty ? changeDigits : nil
        )

        Task {
            do {
                let r: OrderCreateResult = try await API.shared.post("api/v1/orders", body: body)
                await MainActor.run {
                    Haptics.success()
                    CheckoutDraft.clear()
                    cart.clear()
                    placing = false
                    onSuccess(r)
                }
            } catch {
                await MainActor.run {
                    Haptics.error()
                    errorText = error.localizedDescription
                    placing = false
                }
            }
        }
    }
}

// MARK: - Смена заведения / аккаунта, черновик полей

extension CheckoutView {
    /// Заведение в корзине сменилось: условия прежнего (сбор, способы, «открыто»,
    /// зона и цена доставки, акции) больше не действуют — грузим заново.
    fileprivate func reloadForShop() {
        shop = nil; shopLoadError = nil
        quote = nil; quotedGoods = nil; quoteError = nil
        promo = nil; spendPoints = false; errorText = nil
        tableNumber = ""
        guard let slug = cart.shopSlug, session.isLoggedIn else { return }
        // Промокод прежнего заведения мог не действовать в новом — перепроверяем
        // тихо по новому shopId (не подошёл — applyCode сам его уберёт).
        if let c = appliedCode { Task { await applyCode(c, silent: true) } }
        Task {
            await loadShop(slug)
            await MainActor.run {
                let fs = allowedFulfillment
                if !fs.contains(fulfillment), let first = fs.first { fulfillment = first }
                let ps = allowedPayments
                if !ps.contains(payment), let first = ps.first { payment = first }
            }
            await quoteDelivery()
            await MainActor.run { refreshPromo() }
        }
    }

    /// Вход/выход при открытом оформлении. Адреса, выбранный адрес, баллы и
    /// расчёты принадлежат человеку — убираем их и после входа грузим заново:
    /// раньше вошедший следом видел (и мог выбрать) адреса прежнего.
    fileprivate func resetForAccount() {
        if appliedCode != nil { reapplyCode = appliedCode }
        if let id = selectedAddress?.id { reselectAddressId = id }
        addresses = []; addressesError = nil; selectedAddress = nil
        quote = nil; quotedGoods = nil; quoteError = nil
        promo = nil; spendPoints = false; promoPending = false; promoTask?.cancel()
        appliedCode = nil; codeDiscount = 0; codeFree = false; codeMsg = nil
        guard session.isLoggedIn else { return }
        errorText = nil
        let code = reapplyCode
        reapplyCode = nil
        let keep = reselectAddressId
        reselectAddressId = nil
        Task {
            await loadAddresses()
            if let keep {
                await MainActor.run {
                    if let a = addresses.first(where: { $0.id == keep }) { selectAddress(a) }
                }
            }
            let needShop = await MainActor.run { shop == nil ? cart.shopSlug : nil }
            if let slug = needShop { await loadShop(slug) }
            if let c = code { await applyCode(c) }
            await MainActor.run { refreshPromo() }
        }
    }

    /// Ушли в корзину поправить количество и вернулись — комментарий, номер
    /// стола и промокод раньше пропадали (экран создаётся заново).
    fileprivate func restoreDraft() {
        guard CheckoutDraft.shopId != nil, CheckoutDraft.shopId == cart.shopId else { return }
        if comment.isEmpty { comment = CheckoutDraft.comment }
        if tableNumber.isEmpty { tableNumber = CheckoutDraft.table }
        if appliedCode == nil, promoInput.isEmpty, let c = CheckoutDraft.promo, !c.isEmpty {
            promoInput = c
            Task { await applyCode(c) }
        }
    }
}

/// Черновик полей оформления — в памяти, пока приложение живо. Привязан к
/// заведению корзины; стирается после заказа и при выходе из аккаунта.
enum CheckoutDraft {
    static var shopId: Int?
    static var comment = ""
    static var table = ""
    static var promo: String?
    static func clear() { shopId = nil; comment = ""; table = ""; promo = nil }
}

// MARK: - Форма нового адреса (шторка). Город НЕ вводится — из Session.cityName.
//         Улица — Dadata-подсказки строго по выбранному городу.

private struct AddAddressSheet: View {
    let cityName: String
    var onSaved: (Address) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var label = "Дом"
    @State private var street = ""
    @State private var house = ""
    @State private var apartment = ""
    @State private var entrance = ""
    @State private var floor = ""
    @State private var intercom = ""
    @State private var lat: Double?
    @State private var lng: Double?

    @State private var suggestions: [AddrSuggest] = []
    @State private var suggestTask: Task<Void, Never>?
    @State private var suppressSuggest = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                // П-25 №6: пределы полей адреса — как хранит сервер (лишнее он режет молча).
                Section { TextField("Название (Дом, Работа…)", text: $label).ymMaxLength($label, 100) }
                Section("Адрес") {
                    // Город берётся из настроек — не поле ввода.
                    if !cityName.isEmpty {
                        HStack { Text("Город"); Spacer(); Text(cityName).foregroundStyle(YMColor.muted) }
                    }
                    TextField("Улица", text: $street)
                        .onChange(of: street) { v in scheduleSuggest(v) }
                        .ymMaxLength($street, 190)
                    // Подсказки Dadata, отфильтрованные по выбранному городу.
                    ForEach(suggestions) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.circle").foregroundStyle(YMColor.muted)
                                Text(suggestLine(s)).foregroundStyle(YMColor.text)
                                Spacer()
                            }
                        }
                    }
                    TextField("Дом", text: $house).ymMaxLength($house, 30)
                    TextField("Квартира (по желанию)", text: $apartment).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($apartment, 30)
                    TextField("Подъезд (по желанию)", text: $entrance).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($entrance, 20)
                    TextField("Этаж (по желанию)", text: $floor).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($floor, 20)
                    TextField("Домофон (по желанию)", text: $intercom).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($intercom, 50)
                }
                if let e = error { Text(e).foregroundStyle(YMColor.statusCancel).font(YMFont.caption) }
                Section {
                    Button(action: save) {
                        HStack { Spacer()
                            if saving { ProgressView() } else { Text("Сохранить").fontWeight(.bold) }
                            Spacer() }
                    }
                    .disabled(saving)
                }
            }
            .navigationTitle("Новый адрес")
            .navigationBarTitleDisplayMode(.inline)
            // Пока адрес сохраняется, шторку не закрыть: смахнул — ошибка
            // сохранения пропадала вместе со шторкой, а введённый адрес терялся.
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) } }
        }
        .tint(YMColor.accent)
        .presentationDetents([.large])
        .interactiveDismissDisabled(saving)
    }

    private func suggestLine(_ s: AddrSuggest) -> String {
        var line = s.street ?? ""
        if let h = s.house, !h.isEmpty { line += (line.isEmpty ? "" : ", ") + "д. \(h)" }
        return line.isEmpty ? (s.value ?? "") : line
    }

    // Подсказки адреса (Dadata через сервер). Дебаунс 300 мс. Только выбранный город.
    private func scheduleSuggest(_ text: String) {
        suggestTask?.cancel()
        // ВАЖНО: сначала проверяем suppressSuggest. pick() меняет street → сюда прилетает onChange;
        // если сбросить lat/lng ДО этой проверки — обнулим только что выбранные координаты (баг
        // «Выберите адрес из подсказок» после выбора). Обнуляем ТОЛЬКО при ручном вводе.
        if suppressSuggest { suppressSuggest = false; suggestions = []; return }
        lat = nil; lng = nil   // ручной ввод улицы — координаты недействительны, пока не выбрана подсказка
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { suggestions = []; return }
        // Запрос строим как «<Город>, <ввод>» — Dadata приоритезирует этот город.
        let query = cityName.isEmpty ? q : "\(cityName), \(q)"
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let res: [AddrSuggest] = (try? await API.shared.get("api/address/suggest", query: ["q": query])) ?? []
            if Task.isCancelled { return }
            // Дополнительная фильтрация: остаются только адреса выбранного города
            // (или без города — если прокси не вернул city), чтобы улицы других городов не лезли.
            let filtered = res.filter { s in
                cityName.isEmpty || (s.city?.isEmpty ?? true) || s.city?.caseInsensitiveCompare(cityName) == .orderedSame
            }
            await MainActor.run { suggestions = filtered }
        }
    }

    // Выбор подсказки: заполняем улицу/дом/координаты.
    private func pick(_ s: AddrSuggest) {
        suppressSuggest = true
        street = s.street?.isEmpty == false ? s.street! : (s.value ?? street)
        if let h = s.house, !h.isEmpty { house = h }
        lat = s.lat; lng = s.lng
        suggestions = []
    }

    private func save() {
        // Двойное нажатие до перерисовки кнопки сохраняло адрес дважды.
        guard !saving else { return }
        if street.trimmingCharacters(in: .whitespaces).isEmpty { error = "Укажите улицу"; return }
        if house.trimmingCharacters(in: .whitespaces).isEmpty { error = "Укажите номер дома"; return }
        // Координаты могут отсутствовать (подсказка без geo) — сервер догеокодирует адрес при сохранении.
        saving = true; error = nil
        let body = NewAddressBody(
            label: label.trimmingCharacters(in: .whitespaces).isEmpty ? "Адрес" : label,
            city: cityName.isEmpty ? nil : cityName,
            street: street,
            house: house.isEmpty ? nil : house,
            apartment: apartment.isEmpty ? nil : apartment,
            entrance: entrance.isEmpty ? nil : entrance,
            floor: floor.isEmpty ? nil : floor,
            intercom: intercom.isEmpty ? nil : intercom,
            lat: lat, lng: lng
        )
        // Локальный объект — чтобы сразу выбрать созданный адрес (id уточнится при перезагрузке списка).
        let optimistic = Address(
            id: Int.min, label: label, city: cityName.isEmpty ? nil : cityName,
            street: street, house: house.isEmpty ? nil : house,
            apartment: apartment.isEmpty ? nil : apartment, entrance: entrance.isEmpty ? nil : entrance,
            floor: floor.isEmpty ? nil : floor, intercom: intercom.isEmpty ? nil : intercom,
            lat: lat, lng: lng, isDefault: nil
        )
        Task {
            do {
                // П-27.14: ключ повтора — повтор после обрыва связи не создаёт второй адрес.
                try await API.shared.postVoid("api/v1/profile/addresses", body: body, retryKey: true)
                // Перечитываем список — сервер догеокодировал координаты; берём созданный адрес (макс. id).
                let list: [Address] = (try? await API.shared.list("api/v1/profile/addresses")) ?? []
                let created = list.max(by: { $0.id < $1.id }) ?? optimistic
                await MainActor.run { Haptics.success(); onSaved(created); dismiss() }
            } catch {
                await MainActor.run { Haptics.error(); self.error = error.localizedDescription; saving = false }
            }
        }
    }
}

// MARK: - Строка товара (read-only, без степпера — как в макете checkout)

private struct CheckoutRow: View {
    let line: CartLine
    // Как Cart.total и сервер: каждая строка округляется до копейки отдельно,
    // иначе строка могла разойтись с итогом на 1 копейку (72,46 против 72,47).
    private var lineTotal: Decimal {
        var v = Money.parse(line.unitPrice) * (Decimal(string: String(line.qty)) ?? 0)
        var r = Decimal(); NSDecimalRound(&r, &v, 2, .plain); return r
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 14, tone: line.productId)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).font(.system(size: 14.5, weight: .bold)).foregroundStyle(YMColor.text).lineLimit(1)
                let sub = subtitle
                if !sub.isEmpty {
                    Text(sub).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
                }
            }
            Spacer(minLength: YMSpace.sm)
            Text(quantityLabel).font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.muted)
            Text(Money.format(lineTotal)).font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.text).fixedSize()
        }
    }

    private var subtitle: String {
        if !line.modsLabel.isEmpty { return line.modsLabel }
        if let u = line.unit, !u.isEmpty { return u }
        return ""
    }
    private var quantityLabel: String {
        line.isFractional ? fmtQty(line.qty, line.unit) : "× \(Int(line.qty.rounded()))"
    }
}

// MARK: - Предзаказ у закрытого заведения

/// День предзаказа: дата "YYYY-MM-DD", подпись и слоты "HH:MM".
struct PreorderDay: Identifiable, Hashable {
    let date: String
    let label: String
    let slots: [String]
    var id: String { date }
}

/// Слоты предзаказа по графику заведения. Сервер (ОТВЕТЫ-САЙТА п. 7 к П-24):
/// preorder_at = "YYYY-MM-DD HH:MM" по Москве, окно — до «сейчас + 7 суток»,
/// время сверяется с графиком (границы включительно), графика нет — часы не
/// проверяются. Слоты — как на сайте (/api/checkout/slots): шаг 30 минут от
/// времени открытия, слот целиком в часах работы, не раньше чем через 20 минут
/// от «сейчас»; время московское независимо от пояса телефона. Тот же выбор —
/// «Ко времени» у открытого заведения. Паритет с Android (Preorder.kt).
enum PreorderSlots {
    static let step = 30
    static let lead = 20
    static let dayCount = 7
    private static let weekdays: [String] = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]
    private static let months: [String] = ["янв", "фев", "мар", "апр", "мая", "июн",
                                           "июл", "авг", "сен", "окт", "ноя", "дек"]

    /// "HH:MM[:SS]" → минуты от полуночи; мусор → nil.
    static func minutes(_ raw: String?) -> Int? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        let parts = s.split(separator: ":")
        guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        guard (0...24).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    /// Отрезок работы: [start, end) в минутах этого дня, сетка слотов от base.
    struct Shift { let start: Int; let end: Int; let base: Int }

    /// Смены в день недели dow (0 = Вс … 6 = Сб). «Ночная» смена (18:00–02:00)
    /// даёт этому дню отрезок до полуночи, следующему — хвост. Графика нет совсем —
    /// весь день; день без часов — открыт.
    static func shifts(_ schedule: [ScheduleDay]?, dow: Int) -> [Shift] {
        var byDow: [Int: ScheduleDay] = [:]
        for d in schedule ?? [] {
            let k: Int = (((d.dow ?? 0) % 7) + 7) % 7
            byDow[k] = d
        }
        var anyHours = false
        for d in byDow.values where d.isClosed == true || minutes(d.open) != nil { anyHours = true }
        if !anyHours { return [Shift(start: 0, end: 1440, base: 0)] }
        var out: [Shift] = []
        if let p = byDow[(dow + 6) % 7], p.isClosed != true,
           let o = minutes(p.open), let c = minutes(p.close), c <= o, c > 0 {
            out.append(Shift(start: 0, end: c, base: o % step))
        }
        if let t = byDow[dow], t.isClosed != true {
            if let o = minutes(t.open), let c = minutes(t.close) {
                if c > o {
                    out.append(Shift(start: o, end: c, base: o))
                } else {
                    out.append(Shift(start: o, end: 1440 + c, base: o))   // через полночь
                }
            } else {
                out.append(Shift(start: 0, end: 1440, base: 0))          // день без часов — открыт
            }
        }
        return out
    }

    static func build(_ schedule: [ScheduleDay]?, now: Date = Date()) -> [PreorderDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        let hm = cal.dateComponents([.hour, .minute], from: now)
        let nowMin: Int = (hm.hour ?? 0) * 60 + (hm.minute ?? 0)
        let earliest: Int = nowMin + lead
        var result: [PreorderDay] = []
        for d in 0..<dayCount {
            guard let day = cal.date(byAdding: .day, value: d, to: now) else { continue }
            let dc = cal.dateComponents([.year, .month, .day, .weekday], from: day)
            let dow: Int = (dc.weekday ?? 1) - 1               // Calendar: 1 = Вс
            let from: Int = d == 0 ? earliest : 0
            var mins = Set<Int>()
            for sh in shifts(schedule, dow: dow) {
                // Первый слот сетки смены — не раньше начала и не раньше «from».
                var t: Int = max(sh.start, from)
                let r: Int = (((t - sh.base) % step) + step) % step
                if r != 0 { t += step - r }
                while t + step <= sh.end && t < 1440 {
                    mins.insert(t)
                    t += step
                }
            }
            var slots: [String] = []
            for m in mins.sorted() { slots.append(String(format: "%02d:%02d", m / 60, m % 60)) }
            if slots.isEmpty { continue }
            let y: Int = dc.year ?? 0
            let mo: Int = dc.month ?? 1
            let dm: Int = dc.day ?? 1
            let label: String
            switch d {
            case 0: label = "Сегодня"
            case 1: label = "Завтра"
            default: label = weekdays[dow] + ", " + String(dm) + " " + months[max(0, min(11, mo - 1))]
            }
            result.append(PreorderDay(date: String(format: "%04d-%02d-%02d", y, mo, dm), label: label, slots: slots))
        }
        return result
    }

    /// "YYYY-MM-DD HH:MM" — то, что уходит в preorder_at.
    static func value(_ date: String, _ time: String) -> String { date + " " + time }

    static func contains(_ days: [PreorderDay], _ v: String) -> Bool {
        for d in days {
            for t in d.slots where value(d.date, t) == v { return true }
        }
        return false
    }
}

/// Выбор дня и времени предзаказа.
private struct PreorderPickerView: View {
    let statusText: String?
    let days: [PreorderDay]
    @Binding var selection: String?
    /// true — заведение закрыто: заголовок «Предзаказ» и причина.
    var closed: Bool = true

    private var currentDay: PreorderDay? {
        let selDate: String? = selection.map { String($0.prefix(10)) }
        if let d = days.first(where: { $0.date == selDate }) { return d }
        return days.first
    }

    private var intro: String {
        let st = (statusText ?? "").trimmingCharacters(in: .whitespaces)
        let head = st.isEmpty ? "Заведение сейчас закрыто" : st
        return head + ". Выберите день и время — в часы работы заведения."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            if closed {
                Text("Предзаказ").font(YMFont.headline).foregroundStyle(YMColor.text)
                Text(intro).font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Выберите день и время — в часы работы заведения.")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            if days.isEmpty {
                Text("В ближайшие 7 дней свободного времени нет — заведение не работает.")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let day = currentDay {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.sm) {
                        ForEach(days) { d in
                            PreorderChip(title: d.label, selected: d.date == day.date) {
                                // Другой день — ставим его ближайшее время.
                                if d.date != day.date, let first = d.slots.first {
                                    selection = PreorderSlots.value(d.date, first)
                                }
                            }
                        }
                    }
                }
                FlexibleWrap(spacing: YMSpace.sm) {
                    ForEach(day.slots, id: \.self) { t in
                        PreorderChip(title: t, selected: selection == PreorderSlots.value(day.date, t)) {
                            selection = PreorderSlots.value(day.date, t)
                        }
                    }
                }
                if selection == nil {
                    Text("Выберите время, чтобы оформить заказ.")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
        }
        .padding(YMSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

private struct PreorderChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? YMColor.onAccent : YMColor.text)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(selected ? YMColor.accent : YMColor.surface2,
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
