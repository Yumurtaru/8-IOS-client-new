import Foundation

// «Отправить посылку» (волны А79 + А80): клиент вызывает курьера Yumurta
// отвезти вещь «отсюда — туда»; машина — легковая или кузов S…XXL, грузчики,
// межгород с выбором водителя. Ручки — /api/v1/parcels/* (routes/courier_pool.php),
// логика и поля — core/CourierPool.php (parcelQuote, cargoQuote, parcelView).
// Формат v1 {success, data, meta, error{message, details, code}}, деньги — "0.00".
// Всё аддитивно: старый сервер или выключенные посылки — раздел скрыт.

// MARK: - Толерантное чтение полей

/// Ключ для словарей с заранее неизвестными именами (sizes, errors).
private struct ParcelAnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

private extension KeyedDecodingContainer {
    /// Строка; число тоже принимаем (сервер иногда шлёт id/вес числом).
    func pStr(_ k: Key) -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: k) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: k) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: k) { return String(d) }
        return nil
    }
    func pInt(_ k: Key) -> Int? { (try? decode(LenientInt.self, forKey: k))?.wrappedValue }
    func pDbl(_ k: Key) -> Double? { (try? decode(LenientDouble.self, forKey: k))?.wrappedValue }
    func pBool(_ k: Key) -> Bool? { (try? decode(LenientBool.self, forKey: k))?.wrappedValue }
    func pMoney(_ k: Key) -> Decimal? { (try? decode(LenientDecimal.self, forKey: k))?.wrappedValue }
    /// Список, в котором битая запись не роняет остальные.
    func pList<T: Decodable>(_ k: Key, _ t: T.Type) -> [T] {
        (try? decodeIfPresent([LossyElement<T>].self, forKey: k))?.compactMap { $0.value } ?? []
    }
}

/// Словарь «ключ → первый текст»: {"поле": ["текст"]} или {"поле": "текст"}.
/// Ключи храним «нормализованными» (без «_», строчными): декодер API переводит
/// snake_case и в ключах словаря, и cargo_kg мог прийти как cargoKg.
struct ParcelTextMap: Decodable, Hashable {
    private(set) var items: [String: String] = [:]
    /// Порядок ключей как в ответе нам не важен — сортируем для стабильности.
    private(set) var keys: [String] = []
    init() {}
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: ParcelAnyKey.self) else { return }
        var raw: [(String, String)] = []
        for k in c.allKeys {
            if let s = try? c.decode(String.self, forKey: k), !s.isEmpty { raw.append((k.stringValue, s)) }
            else if let l = try? c.decode([String].self, forKey: k), let s = l.first(where: { !$0.isEmpty }) { raw.append((k.stringValue, s)) }
        }
        for (k, v) in raw.sorted(by: { $0.0 < $1.0 }) {
            let n = Self.norm(k)
            if items[n] == nil { items[n] = v; keys.append(k) }
        }
    }
    static func norm(_ k: String) -> String { k.replacingOccurrences(of: "_", with: "").lowercased() }
    subscript(_ key: String) -> String? { items[Self.norm(key)] }
    var isEmpty: Bool { items.isEmpty }
    /// Пара «ключ как пришёл — текст» по ключам в исходном написании.
    var pairs: [(key: String, text: String)] { keys.compactMap { k in items[Self.norm(k)].map { (k, $0) } } }
}

// MARK: - Подсказки формы: GET /api/v1/parcels/quote

/// Кузов {l, w, h} в сантиметрах.
struct ParcelBody: Decodable, Hashable {
    let l: Int, w: Int, h: Int
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        l = c.pInt(.l) ?? 0; w = c.pInt(.w) ?? 0; h = c.pInt(.h) ?? 0
    }
    private enum CodingKeys: String, CodingKey { case l, w, h }
    var known: Bool { l > 0 && w > 0 && h > 0 }
    var text: String { "\(l)×\(w)×\(h) см" }
}

/// Кузов из quote.vehicles[]: car | s | m | l | xl | xxl (CourierPool::vehicleList).
struct ParcelVehicle: Decodable, Hashable, Identifiable {
    let code: String
    let label: String
    let hint: String
    let maxKg: Int?
    let body: ParcelBody?
    let cityPrice: Decimal?
    var id: String { code }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let code = c.pStr(.code), !code.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .code, in: c, debugDescription: "нет code")
        }
        self.code = code
        label = c.pStr(.label) ?? code
        hint = c.pStr(.hint) ?? ""
        maxKg = c.pInt(.maxKg)
        body = try? c.decodeIfPresent(ParcelBody.self, forKey: .body)
        cityPrice = c.pMoney(.cityPrice)
    }
    private enum CodingKeys: String, CodingKey { case code, label, hint, maxKg, body, cityPrice }
    /// Короткая подпись сегмента: «Авто S M L XL XXL».
    var short: String {
        switch code {
        case "car": return "Авто"
        default: return code.uppercased()
        }
    }
}

/// Блок cargo из quote: подсказка цены для выбранной машины и ошибки полей.
struct ParcelCargoQuote: Decodable, Hashable {
    let available: Bool?
    let vehicleClass: String?
    let cargoKg: Int?
    let loaders: Int?
    let trip: String?
    let destCityId: Int?
    let destCity: String?
    let distanceKm: Double?
    let suggestedFee: Decimal?
    let maxFee: Decimal?
    let errors: ParcelTextMap
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.pBool(.available)
        vehicleClass = c.pStr(.vehicleClass)
        cargoKg = c.pInt(.cargoKg)
        loaders = c.pInt(.loaders)
        trip = c.pStr(.trip)
        destCityId = c.pInt(.destCityId)
        destCity = c.pStr(.destCity)
        distanceKm = c.pDbl(.distanceKm)
        suggestedFee = c.pMoney(.suggestedFee)
        maxFee = c.pMoney(.maxFee)
        errors = (try? c.decodeIfPresent(ParcelTextMap.self, forKey: .errors)) ?? ParcelTextMap()
    }
    private enum CodingKeys: String, CodingKey {
        case available, vehicleClass, cargoKg, loaders, trip, destCityId, destCity, distanceKm, suggestedFee, maxFee, errors
    }
}

/// Водитель межгорода из quote.drivers[] (CourierPool::intercityDrivers).
struct ParcelDriver: Decodable, Hashable, Identifiable {
    let courierId: Int
    let name: String
    let rating: Double?
    let ratingCount: Int?
    let deliveriesCount: Int?
    let online: Bool
    /// «Сейчас в рейсе»: поездку «сейчас» не возьмёт, заранее — возьмёт.
    let busy: Bool
    let car: String
    let vehicleLabel: String
    let maxKg: Int?
    let body: ParcelBody?
    let loaders: Int?
    let kmPrice: Decimal?
    let intercityMin: Decimal?
    let total: Decimal?
    var id: Int { courierId }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let cid = c.pInt(.courierId), cid > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .courierId, in: c, debugDescription: "нет courier_id")
        }
        courierId = cid
        name = c.pStr(.name) ?? "Водитель"
        rating = c.pDbl(.rating)
        ratingCount = c.pInt(.ratingCount)
        deliveriesCount = c.pInt(.deliveriesCount)
        online = c.pBool(.online) ?? false
        busy = c.pBool(.busy) ?? false
        car = c.pStr(.car) ?? ""
        vehicleLabel = c.pStr(.vehicleLabel) ?? ""
        maxKg = c.pInt(.maxKg)
        body = try? c.decodeIfPresent(ParcelBody.self, forKey: .body)
        loaders = c.pInt(.loaders)
        kmPrice = c.pMoney(.kmPrice)
        intercityMin = c.pMoney(.intercityMin)
        total = c.pMoney(.total)
    }
    private enum CodingKeys: String, CodingKey {
        case courierId, name, rating, ratingCount, deliveriesCount, online, busy, car, vehicleLabel, maxKg, body, loaders, kmPrice, intercityMin, total
    }
}

/// А101 (CourierPool::schedQuote): забор позже, чем через fromMin минут, — курьера ищем до
/// времени забора минус leadMin, но не дольше maxHours часов; remind — напоминания курьерам
/// за час и за 30 мин до забора. Ноль/нет поля — умолчания сайта (seller-pool.js).
struct ParcelSchedSearch: Decodable, Hashable {
    let fromMin: Int?
    let leadMin: Int?
    let maxHours: Int?
    let remind: Bool?
    init(fromMin: Int? = nil, leadMin: Int? = nil, maxHours: Int? = nil, remind: Bool? = nil) {
        self.fromMin = fromMin; self.leadMin = leadMin; self.maxHours = maxHours; self.remind = remind
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fromMin = c.pInt(.fromMin)
        leadMin = c.pInt(.leadMin)
        maxHours = c.pInt(.maxHours)
        remind = c.pBool(.remind)
    }
    private enum CodingKeys: String, CodingKey { case fromMin, leadMin, maxHours, remind }
}

/// Ответ quote (CourierPool::parcelQuote + cargoQuote).
struct ParcelQuote: Decodable {
    let enabled: Bool?
    let cityId: Int?
    let couriersOnline: Int?
    let distanceKm: Double?
    let suggestedFee: Decimal?
    let minFee: Decimal?
    let maxFee: Decimal?
    let base: Decimal?
    let perKm: Decimal?
    let searchMinutes: Int?
    let maxActive: Int?
    /// Размеры для легковой: docs | small | medium → подпись.
    let sizes: [(code: String, label: String)]
    let rules: String?
    /// А81: «Сервис только для грузов и посылок, пассажиров не перевозим» — плашка над
    /// формой. Старый сервер поля не шлёт — плашки нет. С ним rules начинается с этого текста.
    let rule: String?
    // А80: кузова, грузчики, межгород. Старый сервер их не шлёт — выбор машины скрыт.
    let vehicles: [ParcelVehicle]
    let intercityEnabled: Bool
    let loaderPrice: Decimal?
    let cargo: ParcelCargoQuote?
    let drivers: [ParcelDriver]
    /// А101: вызов «на потом» — ищем курьера до времени забора. Старый сервер поля не шлёт —
    /// выбор «Когда забрать» и подсказки как раньше.
    let scheduledSearch: ParcelSchedSearch?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.pBool(.enabled)
        cityId = c.pInt(.cityId)
        couriersOnline = c.pInt(.couriersOnline)
        distanceKm = c.pDbl(.distanceKm)
        suggestedFee = c.pMoney(.suggestedFee)
        minFee = c.pMoney(.minFee)
        maxFee = c.pMoney(.maxFee)
        base = c.pMoney(.base)
        perKm = c.pMoney(.perKm)
        searchMinutes = c.pInt(.searchMinutes)
        maxActive = c.pInt(.maxActive)
        rules = c.pStr(.rules)
        rule = c.pStr(.rule)
        // Порядок размеров — как на сайте (docs, small, medium), незнакомые — в конце.
        var sz: [(String, String)] = []
        if let m = try? c.nestedContainer(keyedBy: ParcelAnyKey.self, forKey: .sizes) {
            for k in m.allKeys { if let s = try? m.decode(String.self, forKey: k) { sz.append((k.stringValue, s)) } }
        }
        let order = ["docs", "small", "medium"]
        sizes = sz.sorted { a, b in
            let ia = order.firstIndex(of: a.0) ?? 99, ib = order.firstIndex(of: b.0) ?? 99
            return ia != ib ? ia < ib : a.0 < b.0
        }.map { (code: $0.0, label: $0.1) }
        vehicles = c.pList(.vehicles, ParcelVehicle.self)
        intercityEnabled = c.pBool(.intercityEnabled) ?? false
        loaderPrice = c.pMoney(.loaderPrice)
        cargo = try? c.decodeIfPresent(ParcelCargoQuote.self, forKey: .cargo)
        drivers = c.pList(.drivers, ParcelDriver.self)
        scheduledSearch = try? c.decodeIfPresent(ParcelSchedSearch.self, forKey: .scheduledSearch)
    }
    private enum CodingKeys: String, CodingKey {
        case enabled, cityId, couriersOnline, distanceKm, suggestedFee, minFee, maxFee, base, perKm
        case searchMinutes, maxActive, sizes, rules, rule, vehicles, intercityEnabled, loaderPrice, cargo, drivers
        case scheduledSearch
    }
}

// MARK: - Посылка: GET /api/v1/parcels, /api/v1/parcels/{id}

/// Кнопки по can (CourierPool::sellerView + parcelView).
struct ParcelCan: Decodable, Hashable {
    var cancel = false, changeFee = false, retry = false, chooseDriver = false, unassign = false, rate = false
    /// А81: «Пожаловаться» на курьера. Старый сервер — false, кнопки нет.
    var complain = false
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cancel = c.pBool(.cancel) ?? false
        changeFee = c.pBool(.changeFee) ?? false
        retry = c.pBool(.retry) ?? false
        chooseDriver = c.pBool(.chooseDriver) ?? false
        unassign = c.pBool(.unassign) ?? false
        rate = c.pBool(.rate) ?? false
        complain = c.pBool(.complain) ?? false
    }
    private enum CodingKeys: String, CodingKey { case cancel, changeFee, retry, chooseDriver, unassign, rate, complain }
}

/// Курьер посылки: имя, телефон, машина, ETA и точка (свежая — не старше 10 мин).
struct ParcelCourier: Decodable, Hashable {
    let name: String
    let phone: String
    let car: String
    let rating: Double?
    let vehicleLabel: String?
    let lat: Double?
    let lng: Double?
    let etaMinutes: Int?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.pStr(.name) ?? "Курьер"
        phone = c.pStr(.phone) ?? ""
        car = c.pStr(.car) ?? ""
        rating = c.pDbl(.rating)
        vehicleLabel = c.pStr(.vehicleLabel)
        lat = c.pDbl(.lat)
        lng = c.pDbl(.lng)
        etaMinutes = c.pInt(.etaMinutes)
    }
    private enum CodingKeys: String, CodingKey { case name, phone, car, rating, vehicleLabel, lat, lng, etaMinutes }
}

/// Кому предложили межгород, пока он не ответил.
struct ParcelTarget: Decodable, Hashable {
    let name: String
    let car: String
    let rating: Double?
    let vehicleLabel: String
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.pStr(.name) ?? "Водитель"
        car = c.pStr(.car) ?? ""
        rating = c.pDbl(.rating)
        vehicleLabel = c.pStr(.vehicleLabel) ?? ""
    }
    private enum CodingKeys: String, CodingKey { case name, car, rating, vehicleLabel }
}

/// А81: своя жалоба на курьера (CourierPool::complaintBrief). status: open | closed.
struct ParcelComplaint: Decodable, Hashable {
    let id: Int
    let status: String
    let statusLabel: String
    let reason: String
    let reasonLabel: String
    let createdAt: String?
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.pInt(.id) ?? 0
        status = c.pStr(.status) ?? ""
        statusLabel = c.pStr(.statusLabel) ?? ""
        reason = c.pStr(.reason) ?? ""
        reasonLabel = c.pStr(.reasonLabel) ?? ""
        createdAt = c.pStr(.createdAt)
    }
    private enum CodingKeys: String, CodingKey { case id, status, statusLabel, reason, reasonLabel, createdAt }
    /// «Жалоба: Грубил — Рассматривает администратор» (как на сайте).
    var line: String {
        let r = reasonLabel.isEmpty ? reason : reasonLabel
        let st = !statusLabel.isEmpty ? statusLabel : (status == "open" ? "Рассматривает администратор" : "Рассмотрена")
        return "Жалоба: " + [r, st].filter { !$0.isEmpty }.joined(separator: " — ")
    }
}

struct Parcel: Decodable, Identifiable, Hashable {
    let id: Int
    let status: String
    let statusLabel: String
    let pickupAddress: String
    let dropAddress: String
    let pickupAt: String?
    let fee: Decimal?
    let feeBy: String
    let distanceKm: Double?
    let createdAt: String?
    let expiresAt: String?
    let failReason: String?
    let cancelReason: String?
    let rating: Int?
    let offeredTo: Int?
    let comment: String
    let can: ParcelCan
    let courier: ParcelCourier?
    let target: ParcelTarget?
    // А80: машина и груз.
    let vehicleClass: String
    let vehicleLabel: String
    let cargoKg: Int?
    let loaders: Int
    let trip: String
    let destCityId: Int?
    let destCity: String
    // Посылка.
    let pickupName: String
    let pickupPhone: String
    let recipientName: String
    let recipientPhone: String
    let description: String
    let size: String?
    let sizeLabel: String
    /// А81: своя жалоба на курьера (nil — не жаловались или старый сервер).
    let complaint: ParcelComplaint?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let id = c.pInt(.id), id > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "нет id")
        }
        self.id = id
        status = c.pStr(.status) ?? ""
        statusLabel = c.pStr(.statusLabel) ?? ""
        pickupAddress = c.pStr(.pickupAddress) ?? ""
        dropAddress = c.pStr(.dropAddress) ?? ""
        pickupAt = c.pStr(.pickupAt)
        fee = c.pMoney(.fee)
        feeBy = c.pStr(.feeBy) ?? "sender"
        distanceKm = c.pDbl(.distanceKm)
        createdAt = c.pStr(.createdAt)
        expiresAt = c.pStr(.expiresAt)
        failReason = c.pStr(.failReason)
        cancelReason = c.pStr(.cancelReason)
        rating = c.pInt(.rating)
        offeredTo = c.pInt(.offeredTo)
        comment = c.pStr(.comment) ?? ""
        can = (try? c.decodeIfPresent(ParcelCan.self, forKey: .can)) ?? ParcelCan()
        courier = try? c.decodeIfPresent(ParcelCourier.self, forKey: .courier)
        target = try? c.decodeIfPresent(ParcelTarget.self, forKey: .target)
        vehicleClass = c.pStr(.vehicleClass) ?? "car"
        vehicleLabel = c.pStr(.vehicleLabel) ?? ""
        cargoKg = c.pInt(.cargoKg)
        loaders = c.pInt(.loaders) ?? 0
        trip = c.pStr(.trip) ?? "city"
        destCityId = c.pInt(.destCityId)
        destCity = c.pStr(.destCity) ?? ""
        pickupName = c.pStr(.pickupName) ?? ""
        pickupPhone = c.pStr(.pickupPhone) ?? ""
        recipientName = c.pStr(.recipientName) ?? ""
        recipientPhone = c.pStr(.recipientPhone) ?? ""
        description = c.pStr(.description) ?? ""
        size = c.pStr(.size)
        sizeLabel = c.pStr(.sizeLabel) ?? ""
        complaint = try? c.decodeIfPresent(ParcelComplaint.self, forKey: .complaint)
    }
    private enum CodingKeys: String, CodingKey {
        case id, status, statusLabel, pickupAddress, dropAddress, pickupAt, fee, feeBy, distanceKm, createdAt, expiresAt
        case failReason, cancelReason, rating, offeredTo, comment, can, courier, target
        case vehicleClass, vehicleLabel, cargoKg, loaders, trip, destCityId, destCity
        case pickupName, pickupPhone, recipientName, recipientPhone, description, size, sizeLabel, complaint
    }

    /// Посылка в пути — карточку и список опрашиваем раз в 15 с.
    var isLive: Bool { ["searching", "accepted", "picked"].contains(status) }
    /// Строка про машину: только если это не «легковая по городу без грузчиков».
    var cargoLine: String? {
        guard vehicleClass != "car" || loaders > 0 || trip == "intercity" else { return nil }
        var s = vehicleLabel
        if let kg = cargoKg, kg > 0 { s += (s.isEmpty ? "" : ", ") + "\(kg) кг" }
        if loaders > 0 { s += (s.isEmpty ? "" : " · ") + "грузчики: \(loaders)" }
        if trip == "intercity" { s += (s.isEmpty ? "" : " · ") + "межгород → " + destCity }
        return s.isEmpty ? nil : s
    }
}

// MARK: - Отказ сервера по посылке

/// Отказ с кодом и ошибками полей (ключи — как прислал сервер, snake_case).
struct ParcelFailure: LocalizedError {
    let status: Int
    let code: String
    let message: String
    let fields: [String: String]
    var errorDescription: String? { message }
    /// Ответа по существу не было — ключ повтора держим для того же нажатия.
    var keepsIdemKey: Bool {
        status >= 500 || isUnknownOutcome || code == "idempotency_in_progress"
    }
    /// Исход прошлого нажатия неизвестен: посылка могла уже создаться. Ключ не
    /// меняем — новый ключ на то же нажатие дал бы второй вызов курьера.
    /// key_reused сюда же: тело с тем же ключом разошлось (поправили поле после обрыва).
    var isUnknownOutcome: Bool { code == "idempotency_unknown_outcome" || code == "idempotency_key_reused" }
}

// MARK: - Запросы

enum ParcelAPI {
    /// Декодер ответов raw(): как у API (snake_case → camelCase).
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }()

    static func quote(_ query: [String: String]) async throws -> ParcelQuote {
        try await API.shared.get("api/v1/parcels/quote", query: query)
    }
    static func list(status: String, page: Int) async throws -> Page<Parcel> {
        try await API.shared.page("api/v1/parcels", query: ["status": status, "page": String(page)])
    }
    static func get(_ id: Int) async throws -> Parcel {
        try await API.shared.get("api/v1/parcels/\(id)")
    }

    /// Проверка видимости раздела. nil у поля — ответа по существу не было
    /// (сеть, таймаут, 5xx без текста, отмена): прежнее значение не трогаем.
    /// false — только на точный отказ: 404 (старый сервер), 409 (disabled),
    /// 503 с текстом (unavailable). Список смотрим, только когда quote отказал:
    /// при включённых посылках «Мои посылки» видны и так.
    static func gateCheck(cityId: Int?) async -> (canSend: Bool?, hasParcels: Bool?) {
        let path = "api/v1/parcels/quote" + ((cityId ?? 0) > 0 ? "?city_id=\(cityId ?? 0)" : "")
        guard let q = try? await API.shared.raw("GET", path, json: nil) else { return (nil, nil) }
        let st = q.status, data = q.data
        if (200..<300).contains(st) {
            let ok = (try? decoder.decode(APIEnvelope<ParcelQuote>.self, from: data))?.data
            if let ok { return (ok.enabled != false, nil) }
            return (nil, nil)
        }
        guard definiteRefusal(st, data) else { return (nil, nil) }
        guard let l = try? await API.shared.raw("GET", "api/v1/parcels?status=all&page=1", json: nil) else { return (false, nil) }
        let ls = l.status, ld = l.data
        if (200..<300).contains(ls) {
            let obj = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any]
            let count = (obj?["data"] as? [Any])?.count ?? 0
            let total = ((obj?["meta"] as? [String: Any])?["total"] as? NSNumber)?.intValue ?? 0
            return (false, count > 0 || total > 0)
        }
        return (false, definiteRefusal(ls, ld) ? false : nil)
    }

    /// Точный отказ сервера: 404, 409, 503 с текстом ошибки.
    private static func definiteRefusal(_ st: Int, _ data: Data) -> Bool {
        if st == 404 || st == 409 { return true }
        if st == 503 {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let msg = ((obj?["error"] as? [String: Any])?["message"] as? String) ?? (obj?["error"] as? String) ?? ""
            return !msg.isEmpty
        }
        return false
    }

    /// POST /api/v1/parcels: ключ повтора и в теле, и в заголовке (сервер берёт
    /// заголовок, тело — запасной путь). 409 idempotency_in_progress — первый
    /// запрос ещё идёт: ждём 2 с и повторяем один раз тем же ключом.
    static func create(_ body: [String: Any], key: String) async throws -> Parcel {
        var b = body
        b["idempotency_key"] = key
        // Ключи по алфавиту: повтор того же нажатия — те же байты тела (отпечаток на сервере
        // зависит от порядка полей, иначе 422 idempotency_key_reused).
        let json = try JSONSerialization.data(withJSONObject: b, options: [.sortedKeys])
        do {
            return try await send("POST", "api/v1/parcels", json: json, headers: ["Idempotency-Key": key])
        } catch let f as ParcelFailure where f.code == "idempotency_in_progress" {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await send("POST", "api/v1/parcels", json: json, headers: ["Idempotency-Key": key])
        }
    }

    /// А81: жалоба на курьера — POST /api/v1/parcels/{id}/complaint {reason, comment}.
    /// Ответ — свежая карточка. Отказы: 409 complaint_exists | no_courier | too_old,
    /// 422 validation (details.reason / details.comment), 404, 503 unavailable.
    static func complain(_ id: Int, reason: String, comment: String) async throws -> Parcel {
        var b: [String: Any] = ["reason": reason]
        if !comment.isEmpty { b["comment"] = comment }
        return try await action(id, "complaint", b)
    }

    /// А81: правило и причины жалоб на курьера — GET /api/v1/pool/rules (без входа).
    /// Кэш на время работы приложения; неудачу не кэшируем — окно жалобы предложит «Повторить».
    @MainActor static func rules() async throws -> PoolRulesInfo {
        if let r = PoolRulesInfo.cached { return r }
        let (status, data) = try await API.shared.raw("GET", "api/v1/pool/rules", json: nil)
        guard (200..<300).contains(status) else { throw failure(status: status, data: data) }
        // Сырой JSON, а не общий декодер: тот переводит snake_case и в ключах словаря
        // (extra_money → extraMoney), а ключ причины уходит на сервер как есть.
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = obj["data"] as? [String: Any],
              let info = PoolRulesInfo(d), !info.courierReasons.isEmpty else { throw APIError.decoding }
        PoolRulesInfo.cached = info
        return info
    }

    /// Действие с посылкой: cancel | unassign | fee | rate.
    static func action(_ id: Int, _ name: String, _ body: [String: Any] = [:]) async throws -> Parcel {
        let json = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return try await send("POST", "api/v1/parcels/\(id)/\(name)", json: json)
    }

    private static func send(_ method: String, _ path: String, json: Data?, headers: [String: String] = [:]) async throws -> Parcel {
        let (status, data) = try await API.shared.raw(method, path, json: json, headers: headers)
        if (200..<300).contains(status),
           let env = try? decoder.decode(APIEnvelope<Parcel>.self, from: data),
           env.success != false, let p = env.data {
            return p
        }
        throw failure(status: status, data: data)
    }

    /// Разбор отказа: {success:false, error:{message, details{поле:[текст]}, code}}.
    static func failure(status: Int, data: Data) -> Error {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let err = obj?["error"]
        var message = "", code = ""
        var fields: [String: String] = [:]
        if let e = err as? [String: Any] {
            message = (e["message"] as? String) ?? ""
            code = (e["code"] as? String) ?? ""
            if let d = e["details"] as? [String: Any] {
                for (k, v) in d {
                    if let s = v as? String, !s.isEmpty { fields[k] = s }
                    else if let l = v as? [Any], let s = l.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) { fields[k] = s }
                    else if let n = v as? NSNumber { fields[k] = n.stringValue }
                }
            }
        } else if let s = err as? String {
            message = s
        }
        if (200..<300).contains(status) { return APIError.decoding }
        if message.isEmpty {
            if status >= 500 || status == 0 { return APIError.http(status) }
            message = APIError.httpText(status)
        }
        return ParcelFailure(status: status, code: code, message: APIError.serverText(message, status: status), fields: fields)
    }
}

// MARK: - А81: правило сервиса и причины жалоб

/// Ответ GET /api/v1/pool/rules: текст правила и причины жалобы НА курьера
/// (complaint_reasons.courier — их выбирает отправитель посылки).
struct PoolRulesInfo {
    let version: String
    let text: String
    let details: [String]
    /// Причины в порядке сайта; «Другое» (other) — последней.
    let courierReasons: [(code: String, label: String)]

    @MainActor static var cached: PoolRulesInfo?

    init?(_ d: [String: Any]) {
        version = (d["version"] as? String) ?? ""
        text = (d["text"] as? String) ?? ""
        details = (d["details"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard let cr = (d["complaint_reasons"] as? [String: Any])?["courier"] as? [String: Any] else { return nil }
        // JSONSerialization порядок ключей не хранит — раскладываем как у сервера (COMPLAINT_REASONS).
        let order = ["passenger", "rude", "unsafe", "extra_money"]
        let pairs = cr.compactMap { k, v -> (code: String, label: String)? in
            guard let s = v as? String, !s.isEmpty else { return nil }
            return (code: k, label: s)
        }
        courierReasons = pairs.sorted { a, b in
            let ia = a.code == "other" ? 1000 : (order.firstIndex(of: a.code) ?? 500)
            let ib = b.code == "other" ? 1000 : (order.firstIndex(of: b.code) ?? 500)
            return ia != ib ? ia < ib : a.code < b.code
        }
    }
}

// MARK: - Видимость раздела в профиле

/// Флаги «Отправить посылку» / «Мои посылки» на время сессии: профиль не
/// перепроверяет их при каждом открытии. Перепроверка — после вызова курьера
/// и по push посылки; выход из аккаунта (или другой аккаунт) — сброс.
@MainActor
enum ParcelGate {
    private(set) static var canSend = false
    private(set) static var hasParcels = false
    private static var fresh = false
    private static var owner = 0

    static func reset() { canSend = false; hasParcels = false; fresh = false; owner = 0 }
    static func invalidate() { fresh = false }
    /// Посылка создана — «Мои посылки» точно есть.
    static func noteCreated() { hasParcels = true; fresh = false }

    /// Текущие флаги; проверка у сервера — только если кэш устарел.
    static func flags(cityId: Int?) async -> (canSend: Bool, hasParcels: Bool) {
        let me = UserDefaults.standard.integer(forKey: AuthLastUser.key)
        if me != owner { reset(); owner = me }
        if fresh { return (canSend, hasParcels) }
        let r = await ParcelAPI.gateCheck(cityId: cityId)
        guard me == UserDefaults.standard.integer(forKey: AuthLastUser.key) else { return (canSend, hasParcels) }
        if let c = r.canSend { canSend = c }
        if let h = r.hasParcels { hasParcels = h }
        // Свежо, если quote ответил по существу и (включено или список прочитан).
        fresh = r.canSend == true || (r.canSend == false && r.hasParcels != nil)
        return (canSend, hasParcels)
    }
}

// MARK: - Push посылки

extension Notification.Name {
    /// Пришёл/нажат push pool_parcel (object — id посылки, Int): открытые
    /// карточка и список посылок перечитываются сразу, не дожидаясь опроса.
    static let ymParcelPushed = Notification.Name("ym.parcelPushed")
}
