import Foundation
import CryptoKit
import Security
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/*
 Одноразовый QR карты клиента (К-57 п.4).

 GET /api/v1/profile/card-secret -> {client_code, secret(base32), algorithm "SHA1",
 digits 6, period 30, format "yc19", server_time}. Строка для QR и Code128 =
 client_code (13 цифр) + TOTP (RFC 6238, HMAC-SHA1, шаг 30 с, 6 цифр) = 19 цифр.
 Время = часы устройства с поправкой (server_time - локальное время в момент ответа).

 Секрет хранится в Keychain (не в UserDefaults, не в логах) и удаляется при выходе
 из аккаунта (Session.signOut). Поправка времени и код клиента — не секрет.
*/

// MARK: - TOTP (RFC 6238)

enum TOTP {
    /// Декодирование base32 (RFC 4648), регистр, пробелы и «=» не важны. Некорректный символ — nil.
    static func base32Decode(_ s: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var bits = 0, value = 0
        var out = Data()
        for ch in s.uppercased() where ch != "=" && ch != " " {
            guard let idx = alphabet.firstIndex(of: ch) else { return nil }
            value = (value << 5) | idx
            bits += 5
            if bits >= 8 {
                out.append(UInt8((value >> (bits - 8)) & 0xFF))
                bits -= 8
                value &= (1 << bits) - 1
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Код TOTP для момента `time` (секунды Unix), нули слева сохраняются.
    static func code(secret: Data, time: Int64, period: Int = 30, digits: Int = 6) -> String {
        var counter = UInt64(max(0, time) / Int64(max(1, period))).bigEndian
        let msg = Data(bytes: &counter, count: 8)
        let mac = Data(HMAC<Insecure.SHA1>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let bin = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        var pow10: UInt32 = 1
        for _ in 0..<min(max(digits, 1), 9) { pow10 *= 10 }
        let n = String(bin % pow10)
        return String(repeating: "0", count: max(0, digits - n.count)) + n
    }

    /// Проверка по векторам RFC 6238 (секрет ASCII "12345678901234567890", SHA-1, 6 цифр:
    /// T=59 -> 287082, T=1111111109 -> 081804). Тестового таргета в проекте нет — функцию
    /// можно вызвать из отладки: `assert(TOTP.selfCheck())`.
    static func selfCheck() -> Bool {
        let key = Data("12345678901234567890".utf8)
        return code(secret: key, time: 59) == "287082"
            && code(secret: key, time: 1_111_111_109) == "081804"
            && base32Decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") == key
    }
}

// MARK: - Секрет карты

struct CardSecretResponse: Decodable {
    let clientCode: String?
    let secret: String?
    @LenientInt var digits: Int?
    @LenientInt var period: Int?
    @LenientInt var serverTime: Int?
    let format: String?
}

/// Что показывать на карте: 19-значная строка и сколько секунд до смены.
struct CardSecretMaterial {
    let clientCode: String
    let key: Data
    let period: Int
    let digits: Int
    let offset: Int   // server_time - локальное время, секунды

    func string(at date: Date = Date()) -> String {
        let t = Int64(date.timeIntervalSince1970) + Int64(offset)
        return clientCode + TOTP.code(secret: key, time: t, period: period, digits: digits)
    }
    func secondsLeft(at date: Date = Date()) -> Int {
        let t = Int(date.timeIntervalSince1970) + offset
        return period - (((t % period) + period) % period)
    }
}

enum CardSecretStore {
    private static let service = "ru.marketplace.client.cardsecret"
    private static let account = "card_secret"
    private static let offsetKey = "card_secret_time_offset"
    private static let codeKey = "card_secret_client_code"
    private static let paramsKey = "card_secret_params"   // "period,digits"

    static func save(_ r: CardSecretResponse) -> CardSecretMaterial? {
        guard let code = r.clientCode, code.count == 13, code.allSatisfy({ $0.isNumber }),
              let secret = r.secret, let key = TOTP.base32Decode(secret) else { return nil }
        let rawPeriod = r.period ?? 30
        let rawDigits = r.digits ?? 6
        let period = rawPeriod > 0 ? rawPeriod : 30
        let digits = (rawDigits >= 4 && rawDigits <= 8) ? rawDigits : 6
        var offset = 0
        if let st = r.serverTime, st > 0 { offset = st - Int(Date().timeIntervalSince1970) }
        guard write(secret) else { return nil }
        UserDefaults.standard.set(code, forKey: codeKey)
        UserDefaults.standard.set(offset, forKey: offsetKey)
        UserDefaults.standard.set("\(period),\(digits)", forKey: paramsKey)
        return CardSecretMaterial(clientCode: code, key: key, period: period, digits: digits, offset: offset)
    }

    /// Сохранённый ранее секрет (для работы без сети) или nil.
    static func load() -> CardSecretMaterial? {
        guard let secret = read(), let key = TOTP.base32Decode(secret),
              let code = UserDefaults.standard.string(forKey: codeKey) else { return nil }
        let p = (UserDefaults.standard.string(forKey: paramsKey) ?? "30,6").split(separator: ",").compactMap { Int($0) }
        return CardSecretMaterial(clientCode: code, key: key, period: p.first ?? 30, digits: p.count > 1 ? p[1] : 6,
                                  offset: UserDefaults.standard.integer(forKey: offsetKey))
    }

    /// Выход из аккаунта / удаление аккаунта.
    static func clear() {
        SecItemDelete(query() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: codeKey)
        UserDefaults.standard.removeObject(forKey: offsetKey)
        UserDefaults.standard.removeObject(forKey: paramsKey)
    }

    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    private static func read() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var res: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &res) == errSecSuccess, let d = res as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    private static func write(_ s: String) -> Bool {
        guard let d = s.data(using: .utf8) else { return false }
        SecItemDelete(query() as CFDictionary)
        var a = query()
        a[kSecValueData as String] = d
        a[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(a as CFDictionary, nil) == errSecSuccess
    }
}

// MARK: - Модель экрана карты

@MainActor
final class CardCodeModel: ObservableObject {
    enum LoadState { case loading, ready(CardSecretMaterial), fallback }
    @Published var state: LoadState = .loading
    @Published var rotating = false
    @Published var rotateError: String?

    func load() async {
        do {
            let r: CardSecretResponse = try await API.shared.get("api/v1/profile/card-secret", fresh: true)
            if let m = CardSecretStore.save(r) { state = .ready(m) } else { dropSecret() }
        } catch is CancellationError {
        } catch let e as APIError {
            var status = 0
            switch e {
            case .http(let c): status = c
            case .rejected(let c, _, _): status = c
            case .server: status = 503   // ошибка уровня приложения (card_unavailable) - секрета нет
            default: break
            }
            // 503 / 404 / прочие отказы - секрет не действует: удаляем и показываем EAN-13.
            // Нет связи, таймаут и остальные 5xx - работаем по сохранённому секрету.
            if status == 503 || status == 404 || (status >= 400 && status < 500 && status != 401) {
                dropSecret()
            } else {
                useCachedOrFallback()
            }
        } catch {
            useCachedOrFallback()
        }
    }

    /// 503 card_unavailable / 404 / старый сервер: секрет не действует - удаляем и показываем EAN-13.
    private func dropSecret() {
        CardSecretStore.clear()
        state = .fallback
    }

    private func useCachedOrFallback() {
        if case .ready = state { return }
        if let m = CardSecretStore.load() { state = .ready(m) } else { state = .fallback }
    }

    func rotate() async {
        rotating = true; rotateError = nil
        defer { rotating = false }
        do {
            let r: CardSecretResponse = try await API.shared.post("api/v1/profile/card-secret/rotate", body: [String: String]())
            if let m = CardSecretStore.save(r) { state = .ready(m) }
        } catch {
            rotateError = (error as? LocalizedError)?.errorDescription ?? "Не удалось обновить код"
        }
    }
}

// MARK: - Рисование QR и Code128

enum CardBarcode {
    private static let context = CIContext()

    /// QR, уровень коррекции M. Масштаб целым числом, на экране — .interpolation(.none).
    static func qr(_ s: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(s.utf8)
        f.correctionLevel = "M"
        return render(f.outputImage, scale: 10)
    }
    static func code128(_ s: String) -> UIImage? {
        let f = CIFilter.code128BarcodeGenerator()
        f.message = Data(s.utf8)
        f.quietSpace = 4
        return render(f.outputImage, scale: 4)
    }
    private static func render(_ img: CIImage?, scale: CGFloat) -> UIImage? {
        guard let img = img else { return nil }
        let scaled = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
