import Foundation

/// «Пауза приёма» заведения (сервер А719, routes/api_v1.php v1ShopPause).
///
/// Карточка /shops/{slug}, меню (meta) и избранное отдают paused (bool),
/// pause_until ("ГГГГ-ММ-ДД ЧЧ:ММ:СС" по Москве | null — бессрочно) и pause_reason
/// (текст продавца | null). Поля аддитивные: нет ключа (старый сервер) — не на паузе.
/// На паузе заведение видно, а заказ сервер отклоняет (409, error.code = "paused").
///
/// Тексты — как у сервера (v1PauseText): «Заведение временно не принимает заказы до 18:30»
/// (сегодня — только время, иначе «ДД.ММ ЧЧ:ММ»; срока нет — без «до …»).
/// Паритет с Android (core/ShopPause.kt).
enum ShopPause {
    /// Код ошибки оформления, пока заведение на паузе (HTTP 409).
    static let errCode = "paused"
    static let baseText = "Заведение временно не принимает заказы"

    /// Отсутствие ключа (nil) — не пауза: старый сервер ведёт себя как раньше.
    static func isPaused(_ paused: Bool?) -> Bool { paused == true }

    /// Сегодняшняя дата по Москве "ГГГГ-ММ-ДД" — pause_until сервер отдаёт московским временем.
    static func todayMsk() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? TimeZone(secondsFromGMT: 3 * 3600)!
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// "2026-11-01 18:30:00" → "18:30" (если today — тот же день) или "01.11 18:30"; мусор/nil → nil.
    static func untilLabel(_ until: String?, today: String = todayMsk()) -> String? {
        guard let raw = until?.trimmingCharacters(in: .whitespaces) else { return nil }
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)), m.numberOfRanges == 6
        else { return nil }
        func part(_ i: Int) -> String {
            guard let r = Range(m.range(at: i), in: raw) else { return "" }
            return String(raw[r])
        }
        let time = part(4) + ":" + part(5)
        return part(1) + "-" + part(2) + "-" + part(3) == today ? time : part(3) + "." + part(2) + " " + time
    }

    /// Заголовок плашки. Текст сервера (status_text карточки) — как есть, если он пришёл;
    /// иначе собираем сами из pause_until.
    static func title(statusText: String?, until: String?, today: String = todayMsk()) -> String {
        if let t = statusText?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        if let l = untilLabel(until, today: today) { return baseText + " до " + l }
        return baseText
    }

    /// Причина от продавца отдельной строкой; пусто → nil.
    static func reason(_ reason: String?) -> String? {
        guard let r = reason?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        return r
    }
}
