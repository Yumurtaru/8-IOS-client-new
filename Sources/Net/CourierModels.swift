import Foundation
import SwiftUI

// А97 (задача владельца): «Отправить посылку» на главной, «Стать курьером» в профиле.
//
//   GET  /api/v1/features   — что включено на площадке (без входа), routes/downloads.php;
//   GET  /api/v1/pool/me    — заявка курьера этого аккаунта (CourierPool::courierMe); с А98 — ?lite=1
//                             (CourierPool::courierLite: те же enabled, consent_version, rules, courier + lite: true,
//                             без денег и линии); старый сервер параметр не знает — полный ответ, разбор тот же;
//   GET  /api/v1/pool/rules — правило «только грузы и посылки» (без входа);
//   POST /api/v1/pool/apply — заявка (multipart), те же поля, что у приложения курьера.
//
// Разбор — JSONSerialization, терпимо к типам: булевы приходят и как true, и как 0/1/"1",
// числа — и строкой. Кривое поле не роняет весь ответ: оно просто «неизвестно».
// Те же правила и тексты — Android data/remote/CourierDto.kt, data/repo/CourierRepo.kt.

// MARK: - Терпимый разбор

enum JSONLenient {
    static func str(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return ""
    }

    /// Ссылка: только http(s), иначе пусто (кнопку не показываем).
    static func url(_ v: Any?) -> String {
        let s = str(v).trimmingCharacters(in: .whitespacesAndNewlines)
        let low = s.lowercased()
        return (low.hasPrefix("https://") || low.hasPrefix("http://")) ? s : ""
    }

    static func int(_ v: Any?) -> Int? {
        if let n = v as? NSNumber {
            let d = n.doubleValue
            guard d.isFinite, abs(d) < 1e15 else { return nil }
            return Int(d.rounded(.towardZero))
        }
        if let s = v as? String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite, abs(d) < 1e15 { return Int(d.rounded(.towardZero)) }
        }
        return nil
    }

    /// true / false / 1 / 0 / "1" / "0" / "true" / "false"; прочее и отсутствие — nil.
    static func bool(_ v: Any?) -> Bool? {
        if let n = v as? NSNumber { return n.doubleValue != 0 }
        if let s = v as? String {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off": return false
            default: return nil
            }
        }
        return nil
    }
}

// MARK: - Что включено на площадке

/// Ссылки на «Yumurta Курьер»: пустая строка — ссылки нет, кнопку не показываем.
struct CourierAppLinks: Equatable {
    var ios = ""
    var android = ""
    var web = ""
}

/// nil у поля — неизвестно (старый сервер без ручки, 429, нет сети): экраны ведут себя как до А97.
struct AppFeatures: Equatable {
    var parcels: Bool?
    var courierSignup: Bool?
    var ads: Bool?
    var courierApp: CourierAppLinks?

    static let unknown = AppFeatures(parcels: nil, courierSignup: nil, ads: nil, courierApp: nil)

    /// Тело ответа {success, data:{…}}; не JSON / не объект — всё неизвестно.
    static func parse(_ data: Data) -> AppFeatures {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .unknown }
        let d: [String: Any]
        if let inner = root["data"] as? [String: Any] { d = inner }
        else if root["parcels"] != nil || root["courier_signup"] != nil { d = root }
        else { return .unknown }
        var links: CourierAppLinks?
        if let a = d["courier_app"] as? [String: Any] {
            links = CourierAppLinks(ios: JSONLenient.url(a["ios"]), android: JSONLenient.url(a["android"]),
                                    web: JSONLenient.url(a["web"]))
        }
        return AppFeatures(parcels: JSONLenient.bool(d["parcels"]),
                           courierSignup: JSONLenient.bool(d["courier_signup"]),
                           ads: JSONLenient.bool(d["ads"]),
                           courierApp: links)
    }
}

/// GET /api/v1/features — ответ держим в памяти минуту (сервер отдаёт Cache-Control: max-age=60):
/// главная и профиль спрашивают при каждом открытии, а запрос уходит не чаще раза в минуту.
/// Не 200 (старый сервер — 404, 429) — флаги «неизвестны» (как до А97). Нет сети — тоже
/// «неизвестно», но такой ответ не запоминаем: следующее открытие спросит снова.
@MainActor
final class FeaturesStore: ObservableObject {
    static let shared = FeaturesStore()
    @Published private(set) var current: AppFeatures = .unknown
    private var fetchedAt: Date?
    private var running = false

    func refresh(force: Bool = false) async {
        if !force, let t = fetchedAt, Date().timeIntervalSince(t) < 60 { return }
        guard !running else { return }
        running = true
        defer { running = false }
        do {
            let (status, data) = try await API.shared.raw("GET", "api/v1/features", json: nil)
            current = (200..<300).contains(status) ? AppFeatures.parse(data) : .unknown
            fetchedAt = Date()
        } catch {
            current = .unknown
            fetchedAt = nil
        }
    }
}

// MARK: - Заявка курьера

/// courier в /pool/me. status: pending | approved | rejected | blocked.
struct CourierRecord: Equatable {
    var status = ""
    var statusLabel = ""
    var fullName = ""
    var phone = ""
    var cityId = 0
    var city = ""
    var carModel = ""
    var carColor = ""
    var carPlate = ""
    var car = ""
    var selfEmployed = false
    var hasPhoto = false
    var hasLicense = false
    var reviewNote: String?
    var consentAt: String?

    init() {}

    init(_ c: [String: Any]) {
        status = JSONLenient.str(c["status"]).trimmingCharacters(in: .whitespaces).lowercased()
        statusLabel = JSONLenient.str(c["status_label"])
        fullName = JSONLenient.str(c["full_name"])
        phone = JSONLenient.str(c["phone"])
        cityId = JSONLenient.int(c["city_id"]) ?? 0
        city = JSONLenient.str(c["city"])
        carModel = JSONLenient.str(c["car_model"])
        carColor = JSONLenient.str(c["car_color"])
        carPlate = JSONLenient.str(c["car_plate"])
        car = JSONLenient.str(c["car"])
        selfEmployed = JSONLenient.bool(c["self_employed"]) ?? false
        hasPhoto = JSONLenient.bool(c["has_photo"]) ?? false
        hasLicense = JSONLenient.bool(c["has_license"]) ?? false
        let note = JSONLenient.str(c["review_note"]).trimmingCharacters(in: .whitespacesAndNewlines)
        reviewNote = note.isEmpty ? nil : note
        let at = JSONLenient.str(c["consent_at"]).trimmingCharacters(in: .whitespaces)
        consentAt = at.isEmpty ? nil : at
    }
}

/// Правило сервиса (А81) для формы заявки.
struct CourierRule: Equatable {
    var version = ""
    var text = ""
    var details: [String] = []

    /// «Подтвердите: сервис только для …» — как у сервера и приложения курьера.
    var confirmText: String {
        guard let first = text.first else { return text }
        return "Подтвердите: " + String(first).lowercased() + String(text.dropFirst())
    }

    init?(_ r: [String: Any]?) {
        guard let r else { return nil }
        let t = JSONLenient.str(r["text"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        text = t
        version = JSONLenient.str(r["version"])
        details = ((r["details"] as? [Any]) ?? []).map { JSONLenient.str($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// GET /api/v1/pool/me — только то, что нужно экрану «Стать курьером».
struct CourierMe: Equatable {
    var courier: CourierRecord?
    /// false — приём курьеров закрыт администратором; nil — старый сервер (как «открыт»).
    var enabled: Bool?
    var consentVersion: String?
    var rule: CourierRule?

    static func parse(_ data: Data) -> CourierMe? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return nil }
        var me = CourierMe()
        if let c = d["courier"] as? [String: Any] { me.courier = CourierRecord(c) }
        me.enabled = JSONLenient.bool(d["enabled"])
        let v = JSONLenient.str(d["consent_version"]).trimmingCharacters(in: .whitespaces)
        me.consentVersion = v.isEmpty ? nil : v
        me.rule = CourierRule(d["rules"] as? [String: Any])
        return me
    }
}

/// Отказ сервера по заявке: код, текст и ошибки полей (ключи — как прислал сервер).
struct CourierFailure: LocalizedError {
    let status: Int
    let code: String
    let message: String
    let fields: [String: String]
    var errorDescription: String? { message }
}

/// События заявки (push pool_account): открытый экран «Стать курьером» и профиль перечитывают /pool/me.
extension Notification.Name {
    static let ymCourierPushed = Notification.Name("ym.courierPushed")
}

/// Какой экран заявки сейчас открыт: push по ней не открывает второй такой же, а перечитывает открытый.
enum CourierLive {
    static var open = false
    /// Открыли браузер / App Store с экрана заявки — возврат в приложение /pool/me не перечитывает.
    static var leftForLink = false
}

/// Пункт «Стать курьером» виден и при courier_signup: false, если у аккаунта уже есть заявка
/// (человек должен видеть её статус). Кэш на время сессии: проверка раз на аккаунт и после
/// события заявки. Нет сети — прежний ответ не трогаем.
@MainActor
enum CourierGate {
    private(set) static var hasRecord = false
    private static var fresh = false
    private static var owner = 0

    static func reset() { hasRecord = false; fresh = false; owner = 0 }
    static func invalidate() { fresh = false }
    static func note(_ me: CourierMe) { hasRecord = me.courier != nil; fresh = true }

    static func check() async -> Bool {
        let me = UserDefaults.standard.integer(forKey: AuthLastUser.key)
        if me != owner { reset(); owner = me }
        if fresh { return hasRecord }
        do {
            let m = try await CourierAPI.me()
            guard me == UserDefaults.standard.integer(forKey: AuthLastUser.key) else { return hasRecord }
            hasRecord = m.courier != nil
            fresh = true
        } catch let f as CourierFailure where f.status == 404 || f.status == 503 {
            // 404 (старый сервер) / 503 (раздел курьеров недоступен) — заявки нет.
            hasRecord = false
            fresh = true
        } catch {
            // 401, нет сети — прежний ответ.
        }
        return hasRecord
    }
}

// MARK: - Запросы

enum CourierAPI {
    static func me() async throws -> CourierMe {
        // А98 (П-50 №1): лёгкий статус ?lite=1 — заявка, её статус и правило, без побочных действий
        // (не списывает комиссию из кошелька, не трогает линию). Форма — та же, что у полного /pool/me
        // (enabled, consent_version, rules, courier) + lite: true, без денег и линии. Старый сервер
        // параметр не знает и отдаёт обычный /pool/me — разбор CourierMe.parse тот же.
        let (status, data) = try await API.shared.raw("GET", "api/v1/pool/me?lite=1", json: nil)
        guard (200..<300).contains(status) else { throw failure(status: status, data: data) }
        guard let m = CourierMe.parse(data) else { throw APIError.decoding }
        return m
    }

    /// Правило без входа (если /pool/me его не прислал). nil — нет (старый сервер): галочку не показываем.
    static func rule() async -> CourierRule? {
        guard let (status, data) = try? await API.shared.raw("GET", "api/v1/pool/rules", json: nil),
              (200..<300).contains(status),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return CourierRule(root["data"] as? [String: Any])
    }

    /// Города площадки — те же, что у веб-страницы и приложения курьера (with_orgs=1).
    static func cities() async throws -> [City] {
        let list: [City] = try await API.shared.list("api/v1/cities", query: ["with_orgs": "1"])
        return list.filter { $0.id > 0 && !($0.name ?? "").isEmpty }
    }

    /// POST /api/v1/pool/apply (multipart). Фото — готовый JPEG; nil — не менять (повторная заявка).
    /// noPassengers = nil — поле не шлём (правила на сервере нет).
    static func apply(fullName: String, cityId: Int, carModel: String, carColor: String, carPlate: String,
                      selfEmployed: Bool, consent: Bool, noPassengers: Bool?,
                      photo: Data?, license: Data?) async throws -> CourierMe {
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }
        func file(_ name: String, _ jpeg: Data) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(name).jpg\"\r\n".utf8))
            body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
            body.append(jpeg)
            body.append(Data("\r\n".utf8))
        }
        let ws = CharacterSet.whitespacesAndNewlines
        field("full_name", fullName.trimmingCharacters(in: ws))
        field("city_id", cityId > 0 ? String(cityId) : "")
        field("car_model", carModel.trimmingCharacters(in: ws))
        field("car_color", carColor.trimmingCharacters(in: ws))
        field("car_plate", carPlate.trimmingCharacters(in: ws))
        field("self_employed", selfEmployed ? "1" : "0")
        field("consent", consent ? "1" : "0")
        if let np = noPassengers { field("no_passengers", np ? "1" : "0") }
        if let photo { file("photo", photo) }
        if let license { file("license", license) }
        body.append(Data("--\(boundary)--\r\n".utf8))
        let (status, data) = try await API.shared.raw("POST", "api/v1/pool/apply", json: body,
                                                       headers: ["Content-Type": "multipart/form-data; boundary=\(boundary)"])
        guard (200..<300).contains(status) else { throw failure(status: status, data: data) }
        guard let m = CourierMe.parse(data) else { throw APIError.decoding }
        return m
    }

    /// Разбор отказа: {success:false, error:{message, details{поле:[текст]}, code}}.
    static func failure(status: Int, data: Data) -> Error {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let err = obj?["error"]
        var message = "", code = ""
        var fields: [String: String] = [:]
        if let e = err as? [String: Any] {
            message = JSONLenient.str(e["message"])
            code = JSONLenient.str(e["code"])
            if let d = e["details"] as? [String: Any] {
                for (k, v) in d {
                    if let s = v as? String, !s.isEmpty { fields[k] = s }
                    else if let l = v as? [Any], let s = l.compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) { fields[k] = s }
                }
            }
        } else if let s = err as? String {
            message = s
        }
        if message.isEmpty {
            if status >= 500 || status == 0 { return APIError.http(status) }
            message = status == 404 ? "Раздел курьеров пока недоступен — обновите приложение позже" : APIError.httpText(status)
        }
        return CourierFailure(status: status, code: code, message: APIError.serverText(message, status: status), fields: fields)
    }
}
