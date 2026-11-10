import Foundation

/// Часовой пояс заведения (П-68, ответ сайта 09.11).
///
/// Карточка GET /api/v1/shops/{slug} отдаёт `timezone` — IANA-строку пояса города
/// заведения ("Asia/Yekaterinburg"); нет города — "Europe/Moscow". Часы работы,
/// слоты и preorder_at, «Сегодня» у записи к услугам — стенные часы этого пояса.
/// Нет поля (старый сервер) или пояс телефону неизвестен — Москва, как раньше.
/// В списках и избранном поля нет. Паритет с Android (core/ShopTime.kt).
enum ShopTime {
    static let defaultId = "Europe/Moscow"
    static let moscow: TimeZone = TimeZone(identifier: defaultId) ?? TimeZone(secondsFromGMT: 3 * 3600)!

    /// Пояс по строке сервера; пусто или неизвестный id — Москва.
    static func zone(_ id: String?) -> TimeZone {
        guard let key = id?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
              let tz = TimeZone(identifier: key) else { return moscow }
        return tz
    }
}
