import Foundation

/*
 Ручки раздела «Жильё». Контракт — 5 Documentation/ЖИЛЬЁ-КОНТРАКТ.md, раздел 6.1.

 Цену и доступность считает СЕРВЕР: приложение вызывает /quote и показывает
 готовые строки. Повторять формулу на трёх платформах — верный способ
 разойтись в копейках.
 */
extension API {

    /// Поиск жилья. Даты необязательны: без них раздел работает как каталог и
    /// показывает цену «от» — так ведут себя все сервисы бронирования.
    func lodgingSearch(
        cityId: Int?,
        dateFrom: String? = nil,
        dateTo: String? = nil,
        guests: Int? = nil,
        rooms: Int? = nil,
        subtype: String? = nil,
        rent: String? = nil,
        sort: String? = nil,
        page: Int = 1
    ) async throws -> LodgingSearchResp {
        var q: [String: String] = ["page": String(page)]
        if let c = cityId { q["city_id"] = String(c) }
        if let f = dateFrom, let t = dateTo, !f.isEmpty, !t.isEmpty { q["date_from"] = f; q["date_to"] = t }
        if let g = guests { q["guests"] = String(g) }
        if let r = rooms { q["rooms"] = String(r) }
        if let s = subtype, !s.isEmpty { q["subtype"] = s }
        if let r = rent, !r.isEmpty { q["rent"] = r }
        if let s = sort, !s.isEmpty { q["sort"] = s }
        return try await get("api/v1/lodging", query: q)
    }

    func lodgingUnit(slug: String) async throws -> LodgingUnitResp {
        try await get("api/v1/lodging/\(slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug)")
    }

    func lodgingCalendar(slug: String, from: String? = nil, months: Int = 2) async throws -> LodgingCalendarResp {
        var q: [String: String] = ["months": String(months)]
        if let f = from, !f.isEmpty { q["from"] = f }
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return try await get("api/v1/lodging/\(s)/calendar", query: q)
    }

    func lodgingQuote(slug: String, body: LodgingQuoteReq) async throws -> LodgingQuoteResp {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return try await post("api/v1/lodging/\(s)/quote", body: body)
    }

    func lodgingBook(slug: String, body: LodgingBookReq) async throws -> LodgingBookResp {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return try await post("api/v1/lodging/\(s)/book", body: body)
    }

    func lodgingLongRequest(slug: String, body: LodgingLongRequestReq) async throws -> LodgingLongRequestResp {
        let s = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
        return try await post("api/v1/lodging/\(s)/long-request", body: body)
    }

    /// «Мои поездки»: брони жилья клиента.
    func lodgingTrips() async throws -> [LodgingTrip] {
        // list, а не get: одна бронь с неожиданным полем (объект жилья, заведение)
        // роняла разбор всего массива — «Мои поездки» показывали ошибку вместо
        // остальных броней. list пропускает битую запись и пишет её в журнал.
        try await list("api/v1/lodging/bookings")
    }

    func lodgingCancel(bookingId: Int) async throws -> LodgingCancelResp {
        try await post("api/v1/lodging/bookings/\(bookingId)/cancel")
    }
}
