import Foundation

/*
 ============================================================================
  Раздел «Жильё»: отели, гостевые дома, квартиры посуточно и на длительный срок

  Модели выведены 1:1 из канонического контракта
  (5 Documentation/ЖИЛЬЁ-КОНТРАКТ.md, раздел 6) — те же имена и типы, что у
  сервера и у Android.

  ДВЕ ВЕЩИ, КОТОРЫЕ ЗДЕСЬ ВАЖНЕЕ ВСЕГО:

  1. Деньги — только Decimal через @LenientDecimal. Сервер отдаёт их строкой
     «0.00»; Double для денег не используется нигде.

  2. Декодер настроен на convertFromSnakeCase (см. API.swift), поэтому
     serverные ключи date_from / check_in_from / area_m2 сами превращаются в
     dateFrom / checkInFrom / areaM2 — CodingKeys не нужны. Все поля
     опциональные: ответ старого сервера без новых ключей не должен ронять
     экран, а значения по умолчанию отдаются через вычисляемые свойства.
 ============================================================================
 */

// MARK: - Поиск

struct LodgingPrice: Codable, Hashable {
    @LenientDecimal var night: Decimal?
    @LenientDecimal var month: Decimal?
    @LenientDecimal var total: Decimal?
    @LenientInt var nights: Int?
    let currency: String?

    var nightValue: Decimal { night ?? 0 }
    var nightsValue: Int { max(0, nights ?? 0) }
    /// Итог считается сервером только когда выбраны даты И объект свободен.
    /// Ноль трактуем как «итога нет»: иначе карточка показала бы «0 ₽ за 3 ночи».
    var totalOrNil: Decimal? { (total ?? 0) > 0 ? total : nil }
    var monthOrNil: Decimal? { (month ?? 0) > 0 ? month : nil }
}

struct LodgingShopBrief: Codable, Hashable {
    @LenientInt var id: Int?
    let slug: String?
    let name: String?
    let logo: String?
    @LenientDecimal var rating: Decimal?
    @LenientInt var reviews: Int?
    let city: String?
    let address: String?
}

struct LodgingUnitBrief: Codable, Hashable {
    @LenientInt var id: Int?
    let slug: String?
    let title: String?
    let kind: String?
    let subtype: String?
    let subtypeLabel: String?
    let photo: String?
    @LenientInt var baseGuests: Int?
    @LenientInt var maxGuests: Int?
    @LenientInt var roomsCount: Int?
    @LenientInt var areaM2: Int?
    let address: String?

    var subtypeText: String { (subtypeLabel?.isEmpty == false ? subtypeLabel! : "Жильё") }
    var maxGuestsValue: Int { max(1, maxGuests ?? 1) }
    var roomsValue: Int { max(1, roomsCount ?? 1) }
}

struct LodgingItem: Codable, Hashable, Identifiable {
    let shop: LodgingShopBrief?
    let unit: LodgingUnitBrief?
    let price: LodgingPrice?
    let badges: [String]?
    /// Свободно ли на выбранные даты. Без дат сервер присылает true.
    @LenientBool var available: Bool?
    /// Машинный код причины: no_rooms | closed | min_nights | cta | ctd …
    let reason: String?
    /// Текст причины от сервера. Без него карточка писала «занято на эти даты»
    /// на что угодно — на прошедшие даты, на закрытые и на слишком короткий
    /// срок, то есть врала.
    let reasonText: String?

    // Без slug id раньше был новым UUID при каждом обращении: ForEach пересоздавал
    // карточки, а склейка страниц в «Показать ещё» дублировала их.
    var id: String { unit?.slug ?? "unit-\(unit?.id ?? 0)-\(unit?.title ?? "")" }
    var isAvailable: Bool { available ?? true }
}

struct LodgingSearchResp: Codable {
    let items: [LodgingItem]?
    @LenientInt var total: Int?
    @LenientInt var page: Int?
    @LenientInt var perPage: Int?

    var itemsList: [LodgingItem] { items ?? [] }
    var totalValue: Int { total ?? (items?.count ?? 0) }
}

// MARK: - Карточка объекта

struct LodgingRules: Codable, Hashable {
    let checkInFrom: String?
    let checkOutUntil: String?
    let holdType: String?
    let holdUntilTime: String?
    @LenientDouble var prepayPct: Double?
    @LenientInt var cancelFreeDays: Int?
    let cancelPenalty: String?
    @LenientBool var petsAllowed: Bool?
    @LenientBool var smokingAllowed: Bool?
    @LenientBool var partyAllowed: Bool?
    @LenientBool var kidsAllowed: Bool?
    let text: String?

    var checkIn: String { (checkInFrom?.isEmpty == false ? checkInFrom! : "14:00") }
    var checkOut: String { (checkOutUntil?.isEmpty == false ? checkOutUntil! : "12:00") }
    var prepay: Double { prepayPct ?? 0 }
    var freeDays: Int { max(0, cancelFreeDays ?? 0) }
}

struct LodgingRegistry: Codable, Hashable {
    let no: String?
    let url: String?
}

struct LodgingLongTerm: Codable, Hashable {
    @LenientDecimal var priceMonth: Decimal?
    @LenientInt var minMonths: Int?
    @LenientBool var utilitiesIncluded: Bool?
    let utilitiesNote: String?
    @LenientDecimal var depositMonth: Decimal?
    let note: String?

    var priceMonthValue: Decimal { priceMonth ?? 0 }
    var minMonthsValue: Int { max(1, minMonths ?? 1) }
    var utilitiesOn: Bool { utilitiesIncluded ?? false }
}

struct LodgingUnitFull: Codable, Hashable {
    @LenientInt var id: Int?
    let slug: String?
    let title: String?
    let kind: String?
    let subtype: String?
    let subtypeLabel: String?
    let description: String?
    @LenientInt var baseGuests: Int?
    @LenientInt var maxGuests: Int?
    @LenientInt var maxChildren: Int?
    @LenientInt var roomsCount: Int?
    @LenientInt var areaM2: Int?
    @LenientInt var floor: Int?
    @LenientInt var inventory: Int?
    @LenientBool var rentDaily: Bool?
    @LenientBool var rentLong: Bool?
    @LenientDecimal var priceNight: Decimal?
    @LenientDecimal var priceWeekend: Decimal?
    @LenientDecimal var cleaningFee: Decimal?
    @LenientDecimal var deposit: Decimal?
    @LenientDecimal var extraGuestPrice: Decimal?
    @LenientInt var minNights: Int?
    @LenientInt var maxNights: Int?
    @LenientDouble var discountWeekPct: Double?
    @LenientDouble var discountMonthPct: Double?
    let address: String?
    @LenientDouble var lat: Double?
    @LenientDouble var lng: Double?
    @LenientBool var instantBooking: Bool?
    let rules: LodgingRules?
    let registry: LodgingRegistry?
    let longTerm: LodgingLongTerm?

    var subtypeText: String { (subtypeLabel?.isEmpty == false ? subtypeLabel! : "Жильё") }
    var maxGuestsValue: Int { max(1, maxGuests ?? 1) }
    var baseGuestsValue: Int {
        let b = baseGuests ?? 0
        return (b > 0 && b <= maxGuestsValue) ? b : maxGuestsValue
    }
    var childrenMax: Int { max(0, maxChildren ?? 0) }
    var minNightsValue: Int { max(1, minNights ?? 1) }
    var roomsValue: Int { max(1, roomsCount ?? 1) }
    var priceNightValue: Decimal { priceNight ?? 0 }
    /* Правила читаем через отдельные свойства, а не собираем пустой
       LodgingRules: у структуры с property wrapper'ами memberwise-инициализатор
       принимает уже развёрнутые типы, и «пустышку» так не создать. */
    var checkIn: String { rules?.checkIn ?? "14:00" }
    var checkOut: String { rules?.checkOut ?? "12:00" }
    var prepayPctValue: Double { rules?.prepay ?? 0 }
    var cancelFreeDaysValue: Int { rules?.freeDays ?? 0 }
    var cancelPenaltyValue: String { rules?.cancelPenalty ?? "first_night" }
    var petsOk: Bool { rules?.petsAllowed ?? false }
    var kidsOk: Bool { rules?.kidsAllowed ?? true }
    var smokingOk: Bool { rules?.smokingAllowed ?? false }
    var partyOk: Bool { rules?.partyAllowed ?? false }
    var rulesText: String? { rules?.text }
    var isDaily: Bool { rentDaily ?? false }
    var isLong: Bool { rentLong ?? false }
    var instant: Bool { instantBooking ?? false }
}

struct LodgingPhoto: Codable, Hashable, Identifiable {
    @LenientInt var id: Int?
    let path: String?
    var identifier: Int { id ?? 0 }
}

struct LodgingAmenity: Codable, Hashable, Identifiable {
    let slug: String?
    let name: String?
    let icon: String?
    let groupName: String?
    var id: String { slug ?? (name ?? UUID().uuidString) }
}

struct LodgingRatePlan: Codable, Hashable, Identifiable {
    @LenientInt var id: Int?
    let name: String?
    let meal: String?
    let mealLabel: String?
    let priceMode: String?
    @LenientDecimal var priceValue: Decimal?
    @LenientInt var cancelFreeDays: Int?
    let cancelPenalty: String?
    @LenientDouble var prepayPct: Double?
    @LenientInt var minNights: Int?

    var identifier: Int { id ?? 0 }
    var title: String { name ?? "Тариф" }
}

struct LodgingUnitResp: Codable {
    let unit: LodgingUnitFull?
    let shop: LodgingShopBrief?
    let photos: [LodgingPhoto]?
    let amenities: [LodgingAmenity]?
    let ratePlans: [LodgingRatePlan]?
    @LenientDecimal var priceFrom: Decimal?

    var photosList: [LodgingPhoto] { photos ?? [] }
    var amenitiesList: [LodgingAmenity] { amenities ?? [] }
    var plansList: [LodgingRatePlan] { ratePlans ?? [] }
}

// MARK: - Календарь

struct LodgingDay: Codable, Hashable, Identifiable {
    let date: String?
    @LenientDecimal var price: Decimal?
    /// Сколько номеров свободно. 0 — занято.
    @LenientInt var available: Int?
    @LenientBool var closed: Bool?
    @LenientBool var cta: Bool?
    @LenientBool var ctd: Bool?
    @LenientInt var minNights: Int?

    var id: String { date ?? UUID().uuidString }
    var priceValue: Decimal { price ?? 0 }
    var freeRooms: Int { max(0, available ?? 0) }
    var isClosed: Bool { closed ?? false }
    /// Можно ли заехать: есть свободные номера и дата не закрыта.
    var canStay: Bool { freeRooms > 0 && !isClosed }
    var noArrival: Bool { cta ?? false }
    var noDeparture: Bool { ctd ?? false }
}

struct LodgingCalendarResp: Codable {
    let days: [LodgingDay]?
    @LenientDecimal var basePrice: Decimal?
    let from: String?
    let to: String?
    @LenientInt var minNights: Int?

    var daysList: [LodgingDay] { days ?? [] }
    /// Готовый словарь «дата → день» для сетки календаря.
    var byDate: [String: LodgingDay] {
        var out: [String: LodgingDay] = [:]
        for d in daysList { if let k = d.date { out[k] = d } }
        return out
    }
}

// MARK: - Расчёт и бронирование

struct LodgingQuoteLine: Codable, Hashable, Identifiable {
    let key: String?
    let label: String?
    @LenientDecimal var amount: Decimal?
    var id: String { (key ?? "") + (label ?? "") }
    var amountValue: Decimal { amount ?? 0 }
    var labelText: String { label ?? "" }
}

struct LodgingQuoteReq: Encodable {
    let dateFrom: String
    let dateTo: String
    let adults: Int
    let children: Int
    let rooms: Int
    let ratePlanId: Int?
}

struct LodgingQuoteResp: Codable {
    @LenientBool var ok: Bool?
    @LenientBool var available: Bool?
    let reason: String?
    let reasonText: String?
    @LenientInt var nights: Int?
    let lines: [LodgingQuoteLine]?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var prepay: Decimal?
    @LenientDecimal var deposit: Decimal?
    let cancelDeadline: String?
    let cancelPenalty: String?
    let checkInFrom: String?
    let checkOutUntil: String?

    var canBook: Bool { ok ?? false }
    var linesList: [LodgingQuoteLine] { lines ?? [] }
    var totalValue: Decimal { total ?? 0 }
    var prepayValue: Decimal { prepay ?? 0 }
    var depositValue: Decimal { deposit ?? 0 }
    var nightsValue: Int { max(0, nights ?? 0) }
}

struct LodgingBookReq: Encodable {
    let dateFrom: String
    let dateTo: String
    let adults: Int
    let children: Int
    let rooms: Int
    let ratePlanId: Int?
    let guestName: String?
    let guestPhone: String?
    let guestComment: String?
    // Поля payment нет: сервер его не читает, онлайн-оплаты брони нет — оплата всегда
    // на месте, предоплату запрашивает сам объект (ответ на заявку №6, волна А4).
    /// Сумма, которую показали гостю в расчёте. Сервер сверяет её с пересчётом
    /// и при расхождении отвечает 409 reason=price_changed, НЕ создавая бронь:
    /// между расчётом и подтверждением продавец мог поднять цену в календаре, и
    /// бронь оформлялась дороже — новую сумму гость видел уже после факта.
    let expectedTotal: String?
    /// Ключ повтора: ответ потерялся (таймаут), гость нажал ещё раз — сервер
    /// вернёт ту же бронь, а не создаст вторую.
    var idempotencyKey: String? = nil
}

struct LodgingBookResp: Codable {
    @LenientInt var orderId: Int?
    @LenientInt var bookingId: Int?
    let status: String?
    let dateFrom: String?
    let dateTo: String?
    @LenientInt var nights: Int?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var prepay: Decimal?
    @LenientDecimal var deposit: Decimal?
    let checkInFrom: String?
    let checkOutUntil: String?
    let cancelDeadline: String?

    var bookingIdValue: Int { bookingId ?? 0 }
    var totalValue: Decimal { total ?? 0 }
    var prepayValue: Decimal { prepay ?? 0 }
    var nightsValue: Int { max(0, nights ?? 0) }
    var confirmed: Bool { status == "confirmed" }
}

struct LodgingLongRequestReq: Encodable {
    let desiredFrom: String?
    let months: Int
    let adults: Int
    let children: Int
    let pets: Bool
    let name: String?
    let phone: String?
    let message: String?
}

struct LodgingLongRequestResp: Codable {
    @LenientInt var requestId: Int?
    @LenientBool var duplicate: Bool?
    var isDuplicate: Bool { duplicate ?? false }
}

// MARK: - Мои поездки

struct LodgingTripUnit: Codable, Hashable {
    let slug: String?
    let title: String?
    let subtypeLabel: String?
    let address: String?
}

struct LodgingTripShop: Codable, Hashable {
    let slug: String?
    let name: String?
    let phone: String?
}

struct LodgingTrip: Codable, Hashable, Identifiable {
    @LenientInt var id: Int?
    @LenientInt var orderId: Int?
    let unit: LodgingTripUnit?
    let shop: LodgingTripShop?
    let dateFrom: String?
    let dateTo: String?
    @LenientInt var nights: Int?
    @LenientInt var rooms: Int?
    @LenientInt var adults: Int?
    @LenientInt var children: Int?
    let checkInFrom: String?
    let checkOutUntil: String?
    @LenientDecimal var total: Decimal?
    @LenientDecimal var prepay: Decimal?
    let status: String?
    let statusLabel: String?
    let cancelDeadline: String?
    @LenientBool var canCancel: Bool?
    /// Правило отмены — снимок на момент брони: none | first_night | full.
    let cancelPenalty: String?
    /// Сколько объект вправе удержать, если отменить СЕЙЧАС. Раньше гость
    /// узнавал сумму из ответа — когда отмена уже произошла.
    @LenientDecimal var penaltyNow: Decimal?

    var identifier: Int { id ?? 0 }
    var penaltyNowValue: Decimal { penaltyNow ?? 0 }
    var totalValue: Decimal { total ?? 0 }
    var nightsValue: Int { max(0, nights ?? 0) }
    var cancellable: Bool { canCancel ?? false }
    var statusText: String { (statusLabel?.isEmpty == false ? statusLabel! : (status ?? "")) }
}

struct LodgingCancelResp: Codable {
    @LenientBool var cancelled: Bool?
    @LenientDecimal var penalty: Decimal?
    /// Сколько реально прошло через площадку. За проживание гость платит на
    /// месте, поэтому обычно 0 — и возвращать нечего.
    @LenientDecimal var paid: Decimal?
    @LenientDecimal var refund: Decimal?
    var penaltyValue: Decimal { penalty ?? 0 }
    var paidValue: Decimal { paid ?? 0 }
    var refundValue: Decimal { refund ?? 0 }
}
