import Foundation

/*
 ============================================================================
  Раздел «Жильё» — даты и вся текстовая логика БЕЗ SwiftUI.

  Зачем отдельным файлом: здесь только Foundation, поэтому этот код
  компилируется и прогоняется тестами на реальных ответах сервера (см.
  swiftt/ в рабочей папке раздела). Экраны берут строки отсюда и ничего не
  собирают у себя — иначе проверить их было бы нечем: SwiftUI на машине
  сборщика тестов нет.

  Даты держим в серверной форме «ГГГГ-ММ-ДД»: сравнение и арифметика идут по
  строкам и DateComponents в UTC, без TimeZone-сюрпризов.
 ============================================================================
 */

enum LodgingDate {
    /// Формат сервера.
    static let api: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// «Сегодня» — по времени ПЛОЩАДКИ (Europe/Moscow), а не по UTC и не по
    /// поясу телефона: прошедшие даты сервер отсекает своим `date()`, и с
    /// полуночи до трёх ночи по Москве UTC-«сегодня» — это вчера (поиск сразу
    /// отвечал «эти даты уже прошли»).
    private static let apiMoscow: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow") ?? TimeZone(identifier: "UTC")!
        return f
    }()

    static var today: String { apiMoscow.string(from: Date()) }

    static func plusDays(_ iso: String, _ days: Int) -> String {
        guard let d = api.date(from: iso) else { return iso }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return api.string(from: cal.date(byAdding: .day, value: days, to: d) ?? d)
    }

    /// «2026-11-09» → «9 ноября». Для человека даты только так.
    static func human(_ iso: String?) -> String {
        guard let iso = iso, let d = api.date(from: iso) else { return iso ?? "" }
        // Дата не этого года — с годом: прошлогодняя поездка «9 ноября — 12 ноября»
        // в «Моих поездках» читалась как нынешняя, январская бронь — тоже.
        if iso.prefix(4) != today.prefix(4) { return humanYearOut.string(from: d) }
        return humanOut.string(from: d)
    }
    private static let humanYearOut: DateFormatter = {
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "d MMMM yyyy"
        return out
    }()
    /// Один форматтер на приложение: раньше новый создавался на каждый вызов —
    /// по два на каждую строку «Моих поездок» и на каждое касание в календаре.
    private static let humanOut: DateFormatter = {
        let out = DateFormatter()
        out.locale = Locale(identifier: "ru_RU")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "d MMMM"
        return out
    }()

    /// Ночей между датами: день выезда НЕ считается — канон всей отрасли.
    static func nights(_ from: String?, _ to: String?) -> Int {
        guard let f = from, let t = to,
              let df = api.date(from: f), let dt = api.date(from: t) else { return 0 }
        let diff = dt.timeIntervalSince(df)
        return diff <= 0 ? 0 : Int((diff / 86_400).rounded())
    }

    /// Русские числительные: 1 ночь / 2 ночи / 5 ночей.
    /// ВНИМАНИЕ: возвращает ЧИСЛО И СЛОВО — второй раз число подставлять не надо
    /// (на сайте на этом уже получалось «До 3 3 гостей»).
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        let m100 = n % 100, m10 = n % 10
        let word: String
        if (11...14).contains(m100) { word = many }
        else if m10 == 1 { word = one }
        else if (2...4).contains(m10) { word = few }
        else { word = many }
        return "\(n) \(word)"
    }
}

/// Тон бейджа состояния брони. Экран переводит его в свой StatusPill.Kind —
/// здесь SwiftUI-типов нет специально (см. шапку файла).
enum LodgingTone {
    case cancel, done, active, pending
}

enum LodgingText {

    // ── Выдача поиска ──

    /// Цена в карточке выдачи.
    /// `total` сервер присылает только когда выбраны даты И объект свободен;
    /// в остальных случаях показываем цену за ночь (или за месяц в «Длительно»).
    static func price(_ item: LodgingItem, rentLong: Bool) -> String {
        guard let p = item.price else { return "" }
        if rentLong, let m = p.monthOrNil {
            return money(m) + " в месяц"
        }
        if let t = p.totalOrNil, p.nightsValue > 0 {
            return money(t) + " за " + LodgingDate.plural(p.nightsValue, "ночь", "ночи", "ночей")
        }
        return money(p.nightValue) + " за ночь"
    }

    /// «Отель · до 3 гостей · 42 м²»
    static func unitSubtitle(_ u: LodgingUnitBrief?) -> String {
        guard let u = u else { return "" }
        var parts = [u.subtypeText,
                     "до " + LodgingDate.plural(u.maxGuestsValue, "гостя", "гостей", "гостей")]
        if let a = u.areaM2, a > 0 { parts.append("\(a) м²") }
        return parts.joined(separator: " · ")
    }

    static func place(_ item: LodgingItem) -> String {
        join(placeParts(item.unit?.address ?? item.shop?.address, item.shop?.city))
    }

    /// Город и адрес без повтора: у многих организаций адрес уже начинается с
    /// города, и «Миллерово · Миллерово ул. Российская 69» читается как сбой
    /// вёрстки. Если город есть в адресе — оставляем только адрес.
    static func placeParts(_ address: String?, _ city: String?) -> [String?] {
        guard let c = city, !c.isEmpty else { return [address] }
        if let a = address, !a.isEmpty,
           a.range(of: c, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return [a]
        }
        return [c, address]
    }

    // ── Карточка объекта ──

    static func unitPlace(_ unit: LodgingUnitFull, shop: LodgingShopBrief?) -> String {
        join([unit.subtypeText] + placeParts(unit.address ?? shop?.address, shop?.city))
    }

    static func datesTitle(_ from: String?, _ to: String?) -> String {
        guard let f = from, let t = to else { return "Выбрать даты" }
        return range(f, t) + ", " + LodgingDate.plural(LodgingDate.nights(f, t), "ночь", "ночи", "ночей")
    }

    /// «9 ноября — 12 ноября». Пустые даты не превращаем в « — »: у брони их
    /// всегда две, но ответ старого или урезанного сервера не должен рисовать
    /// на экране висящее тире.
    static func range(_ from: String?, _ to: String?) -> String {
        let f = LodgingDate.human(from), t = LodgingDate.human(to)
        if f.isEmpty && t.isEmpty { return "" }
        if f.isEmpty { return t }
        if t.isEmpty { return f }
        return f + " — " + t
    }

    /// Пункты блока «Правила и оплата» — по одному на строку.
    static func rules(_ unit: LodgingUnitFull) -> [String] {
        var out = [
            "Заезд с \(unit.checkIn), выезд до \(unit.checkOut)",
            "Минимальный срок: " + LodgingDate.plural(unit.minNightsValue, "ночь", "ночи", "ночей"),
        ]
        out.append(unit.cancelFreeDaysValue > 0
                   ? "Бесплатная отмена не позднее чем за "
                        + LodgingDate.plural(unit.cancelFreeDaysValue, "сутки", "суток", "суток")
                        + " до заезда"
                   : "Бесплатной отмены нет")
        out.append(upperFirst([
            unit.petsOk ? "можно с животными" : "без животных",
            unit.kidsOk ? "можно с детьми" : "без детей",
            unit.smokingOk ? "курение разрешено" : "курение запрещено",
            unit.partyOk ? "вечеринки разрешены" : "без вечеринок",
        ].joined(separator: ", ")))
        return out
    }

    /// Подпись под кнопкой брони: как подтверждается и как платить.
    ///
    /// Площадка денег за проживание не принимает, поэтому и предоплату
    /// запрашивает сам объект — об этом говорим прямо, иначе человек ждёт
    /// платёжную страницу, которой не будет.
    static func bookingNote(_ unit: LodgingUnitFull) -> String {
        (unit.instant ? "Подтверждение сразу. " : "Бронь подтверждает хозяин. ")
            + (unit.prepayPctValue > 0
               ? "Предоплата \(Int(unit.prepayPctValue))% — объект запросит её сам."
               : "Оплата на месте, при заселении.")
    }

    static func longTerm(_ lt: LodgingLongTerm) -> String {
        // Цены за месяц нет (0) — «по договорённости», а не «0 ₽ в месяц».
        // Части — отдельными let: длинная цепочка «+» тяжела для проверки типов Xcode.
        let price: String = lt.priceMonthValue > 0 ? money(lt.priceMonthValue) + " в месяц" : "Цена по договорённости"
        let months: String = LodgingDate.plural(lt.minMonthsValue, "месяц", "месяца", "месяцев")
        let util: String = lt.utilitiesOn ? "Коммунальные включены." : "Коммунальные отдельно."
        let note: String = lt.utilitiesNote.map { " " + $0 } ?? ""
        return price + ", минимум " + months + ". " + util + note
    }

    // ── Итог брони и поездки ──

    static func bookedTitle(_ r: LodgingBookResp) -> String {
        r.confirmed ? "Бронь подтверждена."
                    : "Бронь принята, хозяин подтвердит её в ближайшее время."
    }

    static func bookedSummary(_ r: LodgingBookResp) -> String {
        let dates = range(r.dateFrom, r.dateTo)
        return (dates.isEmpty ? "" : dates + ", ")
            + LodgingDate.plural(r.nightsValue, "ночь", "ночи", "ночей")
            + ". Итого " + money(r.totalValue) + "."
    }

    static func stay(checkIn: String?, checkOut: String?) -> String {
        "Заезд с \(checkIn ?? "14:00"), выезд до \(checkOut ?? "12:00")"
    }

    static func tripDates(_ t: LodgingTrip) -> String {
        let dates = range(t.dateFrom, t.dateTo)
        return (dates.isEmpty ? "" : dates + ", ")
            + LodgingDate.plural(t.nightsValue, "ночь", "ночи", "ночей")
    }

    static func tripStay(_ t: LodgingTrip) -> String {
        var s = stay(checkIn: t.checkInFrom, checkOut: t.checkOutUntil)
        if let a = t.unit?.address, !a.isEmpty { s += " · " + a }
        return s
    }

    /// Предупреждение перед отменой: человек должен понимать, что часть суммы
    /// удержат (ПП РФ 1853 — до одной ночи при незаезде).
    static func cancelWarning(_ t: LodgingTrip, today: String = LodgingDate.today) -> String {
        let dates = range(t.dateFrom, t.dateTo)
        var s = (t.unit?.title ?? "Объект") + (dates.isEmpty ? "." : ", " + dates + ".")
        // СУММУ удержания показываем ДО нажатия: её считает сервер и присылает в
        // penalty_now. Раньше «часть суммы будет удержана» было единственным
        // предупреждением, а сумму гость узнавал из ответа — то есть когда
        // отмена уже произошла и обратного хода не было.
        if t.penaltyNowValue > 0 {
            s += " Объект вправе удержать " + money(t.penaltyNowValue)
                + " — оплаты через площадку не было, счёт выставит объект."
        } else {
            s += " Удержания не будет."
        }
        if let dl = t.cancelDeadline, !dl.isEmpty {
            s += today > dl
                ? " Срок бесплатной отмены прошёл."
                : " Бесплатная отмена до " + LodgingDate.human(dl) + "."
        }
        return s
    }

    /// Итог отмены.
    ///
    /// Площадка за проживание денег НЕ ПРИНИМАЕТ — гость платит на месте.
    /// Поэтому «удержано и к возврату» говорим только когда через площадку
    /// реально что-то прошло (paid > 0). Раньше показывалось «удержано
    /// 6 000 ₽, к возврату 12 000 ₽» по броне, за которую гость не заплатил
    /// ни рубля.
    static func cancelResult(_ r: LodgingCancelResp) -> String {
        if r.penaltyValue <= 0 { return "Бронь отменена без удержания." }
        if r.paidValue > 0 {
            return "Бронь отменена. Удержано " + money(r.penaltyValue)
                + ", к возврату " + money(r.refundValue) + "."
        }
        return "Бронь отменена. Оплата не вносилась, но по правилам объект"
            + " вправе взять до " + money(r.penaltyValue) + " за позднюю отмену."
    }

    static func tone(_ status: String?) -> LodgingTone {
        switch status {
        case "cancelled", "no_show":     return .cancel
        case "checked_out", "confirmed": return .done
        case "checked_in":               return .active
        default:                         return .pending
        }
    }

    // ── Мелочи ──

    static func upperFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    static func join(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Цена в ячейке календаря — коротко: 4200 → «4,2т», 850 → «850».
    static func shortPrice(_ v: Decimal) -> String? {
        let d = NSDecimalNumber(decimal: v).doubleValue
        if d <= 0 { return nil }
        if d >= 1000 {
            let t = ((d / 1000) * 10).rounded() / 10     // один знак после запятой
            if t == t.rounded() { return "\(Int(t))т" }
            return String(format: "%.1fт", t).replacingOccurrences(of: ".", with: ",")
        }
        return "\(Int(d))"
    }

    /// Показ денег — единый Money.format (Core/MoneyFormat.swift). Своей
    /// арифметики денег в разделе нет: суммы считает сервер, здесь только показ.
    static func money(_ value: Decimal) -> String { Money.format(value) }
}
