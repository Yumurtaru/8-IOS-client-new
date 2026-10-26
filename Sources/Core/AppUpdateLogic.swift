import Foundation

/// П-52 (волна А101): «Вышла новая версия — обновите». Ответ GET /api/v1/app-version.
/// Пустые строки и нули — «нет данных»: приложение молчит.
struct AppVersionInfo: Equatable {
    var latestVersion = ""
    var latestBuild = 0
    var minVersion = ""
    var minBuild = 0
    var message = ""
    var storeURL = ""

    /// Конверт {success, data:{…}} или голый объект. Не объект, нет data и нет ни одного
    /// поля версии (битый ответ, success:false) — nil: это «ошибка», ничего не меняем.
    static func parse(_ data: Data) -> AppVersionInfo? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let d: [String: Any]
        if let inner = root["data"] as? [String: Any] { d = inner }
        else if root["latest_version"] != nil || root["min_version"] != nil
                    || root["latest_build"] != nil || root["min_build"] != nil { d = root }
        else { return nil }
        var i = AppVersionInfo()
        i.latestVersion = JSONLenient.str(d["latest_version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        i.latestBuild = max(0, JSONLenient.int(d["latest_build"]) ?? 0)
        i.minVersion = JSONLenient.str(d["min_version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        i.minBuild = max(0, JSONLenient.int(d["min_build"]) ?? 0)
        i.message = String(JSONLenient.str(d["message"]).trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        // Только http(s): другую схему открыть нечем — тогда окна нет вовсе.
        i.storeURL = JSONLenient.url(d["store_url"])
        return i
    }

    /// Для хранения последнего ответа в настройках (тот же вид, что у сервера, — читает parse).
    func stored() -> String {
        let o: [String: Any] = ["latest_version": latestVersion, "latest_build": latestBuild,
                                "min_version": minVersion, "min_build": minBuild,
                                "message": message, "store_url": storeURL]
        guard let d = try? JSONSerialization.data(withJSONObject: o) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    /// Сохранённый ответ из настроек; пусто или испорчено — nil.
    static func parseStored(_ s: String) -> AppVersionInfo? {
        guard !s.isEmpty else { return nil }
        return parse(Data(s.utf8))
    }
}

enum UpdateKind { case none, soft, force }

/// Чистая логика окна обновления (без UIKit): сравнение версий и решение «обязательное /
/// мягкое / ничего», отложено ли мягкое окно и пора ли спрашивать сервер.
enum AppUpdateLogic {
    /// Сервер спрашиваем не чаще раза в 6 часов (кроме уже показанного обязательного обновления).
    static let checkInterval: TimeInterval = 6 * 60 * 60
    /// «Позже» и «Обновить» в мягком окне — не показывать эту версию 24 часа.
    static let snoozeInterval: TimeInterval = 24 * 60 * 60

    /// Сравнить версии по точкам: 1.0.10 > 1.0.9, 1.3 = 1.3.0. Нецифровая часть — 0. −1 / 0 / 1.
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    private static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { max(0, Int($0.trimmingCharacters(in: .whitespaces)) ?? 0) }
    }

    /// Обязательное: установленная версия ниже минимальной. Без ссылки на магазин — нет.
    static func needsForce(_ info: AppVersionInfo, version: String) -> Bool {
        guard !info.storeURL.isEmpty, !info.minVersion.isEmpty else { return false }
        return compare(version, info.minVersion) < 0
    }

    /// Мягкое: вышла версия новее установленной.
    static func needsSoft(_ info: AppVersionInfo, version: String) -> Bool {
        guard !info.storeURL.isEmpty, !info.latestVersion.isEmpty else { return false }
        return compare(version, info.latestVersion) < 0
    }

    /// Ключ отложенной версии: «Позже» откладывает именно эту latest_version/latest_build.
    static func snoozeKey(_ info: AppVersionInfo) -> String { "\(info.latestVersion)|\(info.latestBuild)" }

    /// Отложено ли мягкое окно: та же версия и прошло меньше суток (часы назад — не отложено).
    static func isSnoozed(_ info: AppVersionInfo, snoozedKey: String, snoozedAt: TimeInterval, now: TimeInterval) -> Bool {
        guard snoozedAt > 0, snoozedKey == snoozeKey(info) else { return false }
        let passed = now - snoozedAt
        return passed >= 0 && passed < snoozeInterval
    }

    static func decide(_ info: AppVersionInfo?, version: String,
                       snoozedKey: String, snoozedAt: TimeInterval, now: TimeInterval) -> UpdateKind {
        // Версию приложения прочитать не удалось — не гадаем (иначе «обязательное» любому).
        guard let info = info, !version.trimmingCharacters(in: .whitespaces).isEmpty else { return .none }
        if needsForce(info, version: version) { return .force }
        if needsSoft(info, version: version),
           !isSnoozed(info, snoozedKey: snoozedKey, snoozedAt: snoozedAt, now: now) { return .soft }
        return .none
    }

    /// Пора ли спрашивать сервер: показан обязательный экран — каждый раз; иначе раз в 6 часов.
    static func shouldCheck(now: TimeInterval, lastSuccessAt: TimeInterval, forceShown: Bool) -> Bool {
        if forceShown || lastSuccessAt <= 0 { return true }
        let passed = now - lastSuccessAt
        return passed < 0 || passed >= checkInterval
    }
}
