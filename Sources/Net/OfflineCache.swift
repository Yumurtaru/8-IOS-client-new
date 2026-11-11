import Foundation
import Combine

/// Файловый кэш последних ответов GET для работы без сети.
///
/// Что кэшируется (список ниже, только GET и только чтение): главная, список заведений,
/// меню заведения, «Мои заказы» (список), профиль. Оформление заказа, корзина и
/// деньги кэш не используют: такие запросы идут с `fresh: true`.
///
/// Сырой ответ сервера лежит в Caches (система вправе очистить его сама).
/// Ключ — адрес со всеми параметрами плюс признак «вошёл / гость».
/// Чистится при выходе из аккаунта и смене города.
final class OfflineCache: ObservableObject {
    static let shared = OfflineCache()

    /// Время сохранения данных, показанных из кэша прямо сейчас. nil — экран свежий.
    @Published private(set) var staleAt: Date?

    /// Заголовок-пометка «этот запрос кэш не использует» (на сервер не уходит).
    static let freshHeader = "X-YM-Fresh"

    private let queue = DispatchQueue(label: "ru.marketplace.offlinecache")
    private let maxAge: TimeInterval = 14 * 24 * 3600
    private let dir: URL? = {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let d = base.appendingPathComponent("OfflineResponses", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private init() {}

    // MARK: - Что можно кэшировать

    /// Путь (без ведущего «/») из белого списка. Только чтение витрины и своих списков.
    static func isCacheable(path: String) -> Bool {
        let p = path.hasPrefix("/") ? String(path.dropFirst()) : path
        let exact: Set<String> = [
            "api/v1/recommendations", "api/v1/popular", "api/v1/banners", "api/v1/cities",
            "api/v1/org-categories/with-counts", "api/v1/categories",
            "api/v1/shops", "api/v1/organizations", "api/v1/orders", "api/v1/profile"
        ]
        if exact.contains(p) { return true }
        // api/v1/shops/{slug}, .../products, .../services
        let parts = p.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "api", parts[1] == "v1", parts[2] == "shops" { return true }
        if parts.count == 5, parts[0] == "api", parts[1] == "v1", parts[2] == "shops",
           parts[4] == "products" || parts[4] == "services" { return true }
        return false
    }

    static func isCacheable(_ req: URLRequest) -> Bool {
        guard (req.httpMethod ?? "GET") == "GET",
              req.value(forHTTPHeaderField: freshHeader) == nil,
              let url = req.url else { return false }
        return isCacheable(path: url.path)
    }

    // MARK: - Чтение и запись

    private func fileURL(_ req: URLRequest) -> URL? {
        guard let dir = dir, let url = req.url else { return nil }
        let auth = req.value(forHTTPHeaderField: "Authorization") == nil ? "g" : "u"
        let key = auth + "|" + url.absoluteString
        return dir.appendingPathComponent(Self.hash(key) + ".json")
    }

    /// FNV-1a 64 бита: стабильный между запусками (hashValue у String другой при каждом).
    private static func hash(_ s: String) -> String {
        var h: UInt64 = 14695981039346656037
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 16)
    }

    func store(_ data: Data, for req: URLRequest) {
        guard let f = fileURL(req) else { return }
        queue.async { try? data.write(to: f, options: .atomic) }
    }

    /// Сохранённый ответ и время сохранения; старше двух недель не отдаём.
    func read(for req: URLRequest) -> (data: Data, at: Date)? {
        guard let f = fileURL(req) else { return nil }
        return queue.sync {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
                  let at = attrs[.modificationDate] as? Date,
                  Date().timeIntervalSince(at) < maxAge,
                  let data = try? Data(contentsOf: f), !data.isEmpty else { return nil }
            return (data, at)
        }
    }

    func clearAll() {
        let d = dir
        queue.async {
            guard let dir = d,
                  let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
            for f in files { try? FileManager.default.removeItem(at: f) }
        }
        markFresh()
    }

    // MARK: - Пометка «данные из кэша»

    func markStale(_ at: Date) {
        DispatchQueue.main.async { if self.staleAt != at { self.staleAt = at } }
    }
    func markFresh() {
        DispatchQueue.main.async { if self.staleAt != nil { self.staleAt = nil } }
    }

    static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
