import Foundation

enum APIError: LocalizedError {
    case server(String)   // ошибка уровня приложения (success=false) — не повторяем
    case http(Int)        // HTTP-статус ошибки — повторяем при >= 500
    case network          // нет соединения — повторяем
    case timeout          // истёк таймаут — повторяем
    case unauthorized     // 401 — нужен повторный вход
    /// 401 на запрос гостя (ушёл без токена). Паритет с Android (Repo.safeS):
    /// «Сессия истекла» сбивала с толку — гость войти ещё и не пытался.
    case guestNeedsLogin
    case decoding
    /// 409 «не хватает денег на кошельке». Сервер присылает суммы, и экран
    /// показывает «Пополните на 269 ₽» с кнопкой, а не «Ошибка сервера (409)».
    /// Так отвечают создание заказа с оплатой кошельком и публикация объявления.
    case walletShortage(need: Decimal, balance: Decimal, missing: Decimal, message: String)
    /// П-23: отказ 4xx с кодом и details. Текст тот же, что у .server, но экран
    /// может различить 409 «отзыв уже оставлен», 422 need=email_code, 429.
    case rejected(status: Int, message: String, details: [String: String]?)
    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .rejected(_, let m, _): return m
        // Код ответа человеку ничего не говорит («Ошибка сервера (502)») — пишем по-русски.
        case .http:          return "Сервер временно недоступен. Попробуйте позже"
        case .network:       return "Нет соединения с интернетом"
        case .timeout:       return "Превышено время ожидания. Попробуйте ещё раз"
        case .unauthorized:  return "Сессия истекла, войдите снова"
        case .guestNeedsLogin: return "Войдите, чтобы продолжить"
        case .decoding:      return "Не удалось обработать ответ"
        case .walletShortage(_, _, _, let m): return m
        }
    }
    /// Текст для 4xx без сообщения сервера (страница nginx, пустое тело).
    /// Раньше человек видел «Ошибка 413» или «Ошибка 404».
    static func httpText(_ code: Int) -> String {
        switch code {
        // 403/409/422 без текста: «Нет доступа» и «код 422» не объясняли, что делать.
        case 403: return "Недостаточно прав для этого действия"
        case 404: return "Не найдено — возможно, уже удалено"
        case 408: return "Превышено время ожидания. Попробуйте ещё раз"
        case 409: return "Данные уже изменились — обновите экран и попробуйте снова"
        case 413: return "Файл слишком большой"
        case 422: return "Проверьте введённые данные"
        case 429: return "Слишком много запросов. Подождите минуту и повторите"
        default:  return "Не удалось выполнить запрос (код \(code))"
        }
    }
    /// 5xx с общим текстом сервера («Внутренняя ошибка сервера», core/bootstrap.php)
    /// не говорил, что делать, — добавляем «попробуйте ещё раз». Остальные
    /// тексты сервера (уже с подсказкой) — как есть.
    static func serverText(_ msg: String, status: Int) -> String {
        guard status >= 500 else { return msg }
        let generic = ["Внутренняя ошибка сервера", "Ошибка формирования ответа", "Ошибка сервера"]
        return generic.contains(msg) ? "Ошибка на сервере. Попробуйте ещё раз через минуту" : msg
    }
    /// Стоит ли повторять запрос при этой ошибке (для идемпотентных GET).
    var isRetryable: Bool {
        switch self {
        case .network, .timeout: return true
        case .http(let c):       return c >= 500
        default:                 return false
        }
    }
    /// П-23: HTTP-код отказа (nil — не 4xx с разобранным ответом).
    var rejectStatus: Int? {
        if case .rejected(let s, _, _) = self { return s }
        return nil
    }
    /// П-23: details отказа (`need`, поля формы) — nil, если их нет.
    var rejectDetails: [String: String]? {
        if case .rejected(_, _, let d) = self { return d }
        return nil
    }
    /// 409 публикации объявления «цена размещения изменилась» (routes/ads.php,
    /// details.reason = "price_changed", details.price — новая цена). nil — другая ошибка.
    var priceChangedTo: Decimal? {
        guard rejectStatus == 409, let d = rejectDetails, d["reason"] == "price_changed" else { return nil }
        return d["price"].flatMap { Decimal(string: $0) } ?? 0
    }
    /// П-27.14: код отказа ключа повтора (idempotency_in_progress,
    /// idempotency_key_reused…). perform кладёт его в details отказа.
    var idempotencyCode: String? { rejectDetails?["idempotency_code"] }
}

final class API {
    static let shared = API()
    static let base = "https://yumurta.ru"

    /// Вызывается при 401 (истёкший токен). Session подписывается, чтобы выйти из аккаунта.
    var onUnauthorized: (() -> Void)?

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }()

    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    /// Свой URLSession: таймауты и ожидание появления сети.
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20       // ожидание ответа на запрос
        cfg.timeoutIntervalForResource = 40      // суммарный лимит на ресурс
        cfg.waitsForConnectivity = true          // подождать сеть вместо мгновенной ошибки
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Без cookie — как Android-клиент (у его OkHttp нет CookieJar). Вход
        // держится только на Bearer. Сервер может ставить cookie с токенами
        // (у продавца так делает ответ продления), а общее хранилище отправляло
        // их с каждым запросом — в том числе после выхода из аккаунта.
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg)
    }()

    /// А100: «Помощник Yumurta» отвечает 10–30 с, общая сессия ждёт только 20/40 с.
    /// Своя сессия — ожидание ответа до 60 с, без cookie, как общая. Сеть не ждём:
    /// без связи вопрос сразу получает «Нет соединения», а не висит минуту.
    private let longSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 70
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        return URLSession(configuration: cfg)
    }()

    /// Удалить cookie сайта из общего хранилища (их туда клали прежние версии).
    static func clearCookies() {
        guard let url = URL(string: base) else { return }
        let store = HTTPCookieStorage.shared
        for c in store.cookies(for: url) ?? [] { store.deleteCookie(c) }
    }

    private let maxRetries = 2                    // доп. попытки (итого до 3) для GET

    /// Телефон сейчас без сети (по NetworkMonitor, читаем на главном потоке).
    static func offlineNow() async -> Bool {
        await MainActor.run { !NetworkMonitor.shared.online }
    }

    /// Абсолютный адрес картинки.
    ///
    /// Сервер отдаёт пути в двух видах, и это не оплошность, а история разделов:
    ///   • товары, логотипы, баннеры — голый путь внутри хранилища
    ///     ("products/2026/06/x.webp"), к нему нужно дописать /assets/uploads/;
    ///   • объявления — уже готовый путь от корня сайта
    ///     ("/assets/uploads/ads/2026/09/x.webp", см. adsPhotoUrl в routes/ads.php),
    ///     к нему нужно дописать ТОЛЬКО адрес сайта.
    ///
    /// Второй случай раньше не обрабатывался: URL(string:) отдавал относительный
    /// адрес без схемы, AsyncImage такой не грузит — фото объявлений было видно на
    /// сайте и не видно в приложении.
    static func imageURL(_ path: String?) -> URL? {
        guard let p = path, !p.isEmpty else { return nil }
        // Пробел или кириллица в имени файла (старые загрузки, импорт): на iOS 16
        // URL(string:) даёт nil, и картинки не было. Кодируем, только если
        // без кодирования адрес не собирается — уже закодированный не трогаем.
        func url(_ s: String) -> URL? {
            URL(string: s) ?? s.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed).flatMap(URL.init(string:))
        }
        if p.hasPrefix("http") { return url(p) }
        if p.hasPrefix("/") { return url(base + p) }
        return url(base + "/assets/uploads/" + p)
    }

    private func makeRequest(_ method: String, _ path: String, query: [String: String] = [:], body: Encodable? = nil) throws -> URLRequest {
        // Без «!»: путь может содержать данные извне (слаг из ссылки), и кривой
        // адрес должен давать ошибку запроса, а не падение приложения.
        guard var comps = URLComponents(string: API.base + "/" + path) else { throw APIError.network }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
            // URLQueryItem оставляет «+» как есть, а PHP читает его как пробел:
            // поиск «c++» или «+7…» уходил другим запросом.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let reqURL = comps.url else { throw APIError.network }
        var req = URLRequest(url: reqURL)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body = body { req.httpBody = try Self.encoder.encode(AnyEncodable(body)) }
        return req
    }

    /// Повтор только для идемпотентных запросов (GET): POST/PUT/DELETE не повторяем,
    /// чтобы не задвоить заказ или платёж.
    private func send<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let idempotent = (req.httpMethod ?? "GET") == "GET"
        let attempts = idempotent ? maxRetries + 1 : 1
        var lastError: Error = APIError.network
        for attempt in 0..<attempts {
            do {
                return try await perform(req, as: type)
            } catch let e as APIError where e.isRetryable && attempt < attempts - 1 {
                lastError = e
                // Без сети повтор бесполезен: каждая попытка ждёт сеть до 40 с
                // (waitsForConnectivity), и крутилка висела около двух минут.
                if await API.offlineNow() { throw APIError.network }
                let delay = pow(2.0, Double(attempt)) * 0.5 + Double.random(in: 0...0.3) // 0.5s, 1.5s + джиттер
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
        }
        throw lastError
    }

    private func perform<T: Decodable>(_ req: URLRequest, as type: T.Type, isRetryAfterRefresh: Bool = false) async throws -> T {
        let data: Data; let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }   // отмена (дебаунс) — не повторяем
            // Таймаут при выключенной сети — это «нет соединения», а не
            // «превышено время ожидания»: запрос просто ждал сеть.
            if urlError.code == .timedOut {
                if await API.offlineNow() { throw APIError.network }
                throw APIError.timeout
            }
            throw APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // Тихое продление access-токена (security-аудит): refresh → один повтор запроса.
            // Позволяет серверу сократить JWT_EXPIRES до часов без массовых разлогинов.
            if !isRetryAfterRefresh, !(req.url?.path.hasSuffix("/auth/refresh") ?? false) {
                // Запрос ушёл со старым токеном, а параллельный запрос уже продлил его:
                // повторяем со свежим, а не продлеваем второй раз (лишний refresh,
                // при ротации refresh-токена на сервере он разлогинил бы человека).
                // Запрос без токена (ушёл, пока человек был гостем), а вход уже
                // выполнен: тоже повтор с текущим токеном. Раньше такой 401 шёл в
                // продление, а при отказе продления — в выход только что вошедшего.
                if let current = TokenStore.access, !current.isEmpty,
                   req.value(forHTTPHeaderField: "Authorization") != "Bearer \(current)" {
                    var retry = req
                    retry.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")
                    // false: если и свежий токен отвергнут, этот повтор сам пойдёт в продление
                    // (заголовок теперь совпадает с текущим — второй раз сюда не попадём).
                    return try await perform(retry, as: type, isRetryAfterRefresh: false)
                }
                switch await refreshAccessToken() {
                case .token(let newToken):
                    var retry = req
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    return try await perform(retry, as: type, isRetryAfterRefresh: true)
                case .unavailable:
                    // Продлить не удалось из-за СЕТИ (таймаут, нет связи, 5xx).
                    // Раньше это считалось отказом, и человека разлогинивало со
                    // стиранием ещё живого refresh-токена. Теперь — «нет связи».
                    throw APIError.network
                case .rejected:
                    break
                }
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            // Запрос ушёл без токена — это гость, а не истёкшая сессия (как Android).
            if req.value(forHTTPHeaderField: "Authorization") == nil { throw APIError.guestNeedsLogin }
            throw APIError.unauthorized
        }

        do {
            let env = try decoder.decode(APIEnvelope<T>.self, from: data)
            // 409 с суммами need/balance/missing — это «не хватает на кошельке».
            // Разбираем ДО общей ветки success == false, иначе экран получил бы
            // только текст и не смог бы дать кнопку «Пополнить».
            if status == 409, let d = env.error?.details,
               let missing = d["missing"].flatMap({ Decimal(string: $0) }) {
                throw APIError.walletShortage(
                    need: d["need"].flatMap { Decimal(string: $0) } ?? 0,
                    balance: d["balance"].flatMap { Decimal(string: $0) } ?? 0,
                    missing: missing,
                    message: env.error?.message ?? "Не хватает денег на кошельке"
                )
            }
            if env.success == false {
                // Ошибки полей (details: {"title": "Слишком короткий заголовок"}) —
                // добавляем первую к общему «Проверьте поля объявления», иначе
                // человек не понимал, что именно исправить.
                // Отказ 4xx без текста — понятная фраза по коду, а не «Ошибка сервера».
                let rawMsg = env.error?.message ?? ""
                var msg = !rawMsg.isEmpty ? rawMsg
                    : ((400..<500).contains(status) ? APIError.httpText(status) : "Ошибка сервера")
                // П-23.5: details {need: "email_code"} — служебный ключ, а не ошибка
                // поля: к тексту не приклеиваем (было «…: email_code»).
                // Машинный код (no_rooms, min_nights…) — не текст для человека:
                // выходило «…: min_nights». Паритет с Android (parseServerError).
                if status == 422, env.error?.details?["need"] == nil,
                   let first = env.error?.details?.values.sorted().first, !first.isEmpty, !msg.contains(first),
                   first.range(of: "^[a-z0-9_]+$", options: .regularExpression) == nil {
                    msg += ": " + first
                }
                // П-23: 4xx — с кодом и details (текст прежний), остальное как было.
                if (400..<500).contains(status) {
                    // П-27.14: код ключа повтора — в details, чтобы sendKeyed
                    // отличил «первый запрос ещё идёт» (409) от прочих отказов.
                    var det = env.error?.details
                    if let code = env.error?.code, code.hasPrefix("idempotency_") {
                        det = (det ?? [:]).merging(["idempotency_code": code]) { old, _ in old }
                    }
                    throw APIError.rejected(status: status, message: msg, details: det)
                }
                throw APIError.server(APIError.serverText(msg, status: status))
            }
            // Ошибочный статус с телом {ok:false,error:"..."} (Response::error): success отсутствует,
            // но текст есть — показываем его (иначе терялось «Минимальная сумма заказа…» → «Ошибка 422»).
            if status >= 400, var msg = env.error?.message, !msg.isEmpty {
                // Сайтовый 422 (Response::validation): общий текст «Проверьте
                // правильность заполнения» + первая ошибка поля из errors, как у v1.
                if status == 422, let first = env.errors?.messages.first, !msg.contains(first) {
                    msg += ": " + first
                }
                if status < 500 { throw APIError.rejected(status: status, message: msg, details: env.error?.details) }
                throw APIError.server(APIError.serverText(msg, status: status))
            }
            // Действие без полезной нагрузки (отмена заказа, удаление…) сервер
            // может закрыть ответом {"success":true,"data":null} — это успех,
            // а не «Не удалось обработать ответ».
            // Только для 2xx: ошибка сервера без success:false / error.message
            // (например {"message":"Server Error"}) не должна стать «успехом».
            if (200..<300).contains(status), env.data == nil, T.self == EmptyResp.self,
               let empty = EmptyResp() as? T { return empty }
            if !(200..<300).contains(status), env.data == nil {
                if status >= 500 { throw APIError.http(status) }
                // П-23: 4xx без текста — тоже с кодом (409 у отзыва на старом сервере).
                if status >= 400 { throw APIError.rejected(status: status, message: APIError.httpText(status), details: nil) }
                throw APIError.server(APIError.httpText(status))
            }
            guard let payload = env.data else { throw APIError.decoding }
            (payload as? PageMetaReceiving)?.receive(meta: env.meta)   // Page<T>: has_more из meta
            return payload
        } catch let e as APIError {
            throw e
        } catch {
            if status >= 500 { throw APIError.http(status) }
            if status >= 400 { throw APIError.rejected(status: status, message: APIError.httpText(status), details: nil) }
            throw APIError.decoding
        }
    }

    // ── Тихое продление access-токена (security-аудит) ──────────────────────
    // Single-flight: параллельные 401 ждут один общий refresh-вызов.
    /// Итог продления: новый токен, отказ сервера (refresh недействителен →
    /// выход) или «сервер недоступен» (сеть/5xx → токены НЕ трогаем).
    enum RefreshOutcome { case token(String), rejected, unavailable }
    /// Очередь продления живёт в actor: раньше `refreshTask` был обычным полем
    /// класса, и два 401 с разных потоков могли одновременно увидеть nil и
    /// отправить два refresh (гонка данных + лишний вызов, который при ротации
    /// refresh-токена на сервере разлогинил бы человека).
    private let refreshGate = RefreshGate()

    private func refreshAccessToken() async -> RefreshOutcome {
        await refreshGate.run { [weak self] () -> RefreshOutcome in
            guard let self = self,
                  let refresh = TokenStore.refresh,
                  !refresh.isEmpty,
                  let url = URL(string: API.base + "/api/v1/auth/refresh") else { return .rejected }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["refresh_token": refresh])
            struct RefreshResp: Decodable { let token: String? }
            guard let (data, resp) = try? await self.session.data(for: req) else { return .unavailable }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 500 || code == 0 || code == 429 { return .unavailable }
            guard code == 200,
                  let env = try? self.decoder.decode(APIEnvelope<RefreshResp>.self, from: data),
                  let token = env.data?.token, !token.isEmpty else { return .rejected }
            // Пока шло продление, человек вышел (или вошёл другой) — старую
            // сессию не возвращаем: иначе после перезапуска снова прежний аккаунт.
            // Паритет с Android (refreshBlocking): вошёл заново — повторяем запрос с
            // токеном текущей сессии, а не показываем «Нет соединения».
            guard TokenStore.refresh == refresh else {
                if let cur = TokenStore.access, !cur.isEmpty { return .token(cur) }
                return .unavailable
            }
            TokenStore.access = token
            return .token(token)
        }
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await send(try makeRequest("GET", path, query: query), as: T.self)
    }
    /// retryKey: true — создание с ключом повтора (П-27.14, см. sendKeyed).
    func post<T: Decodable>(_ path: String, body: Encodable? = nil, retryKey: Bool = false) async throws -> T {
        let req = try makeRequest("POST", path, body: body)
        if retryKey { return try await sendKeyed(req, as: T.self) }
        return try await send(req, as: T.self)
    }
    func put<T: Decodable>(_ path: String, body: Encodable? = nil) async throws -> T {
        try await send(try makeRequest("PUT", path, body: body), as: T.self)
    }
    func list<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> [T] {
        let p: ListPayload<T> = try await send(try makeRequest("GET", path, query: query), as: ListPayload<T>.self)
        return p.items
    }
    /// Страница списка с meta (has_more, per_page). Пример: заказы —
    /// `let p: Page<OrderSummary> = try await API.shared.page("api/v1/orders", query: ["page": "2"])`,
    /// дальше `p.items`, а `p.hasMore` решает, просить ли page+1.
    func page<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Page<T> {
        try await send(try makeRequest("GET", path, query: query), as: Page<T>.self)
    }
    func postVoid(_ path: String, body: Encodable? = nil, retryKey: Bool = false) async throws {
        let req = try makeRequest("POST", path, body: body)
        if retryKey { _ = try await sendKeyed(req, as: EmptyResp.self); return }
        _ = try await send(req, as: EmptyResp.self)
    }

    /// П-27.14: создание (объявление, адрес, возврат, жалоба, отклик) с
    /// заголовком Idempotency-Key. Ключ — один на нажатие; повтор того же
    /// запроса после обрыва связи идёт с тем же ключом и теми же байтами тела,
    /// и сервер отдаёт прежний ответ вместо второй записи. 409
    /// idempotency_in_progress — первый запрос ещё идёт: ждём 2 с и повторяем
    /// один раз. 422 idempotency_key_reused — обычная ошибка с текстом сервера.
    /// Старый сервер заголовок не знает и работает как раньше.
    private func sendKeyed<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let slot = RetryKeys.shared.take(path: req.url?.path ?? "", body: req.httpBody)
        var keyed = req
        keyed.setValue(slot.key, forHTTPHeaderField: "Idempotency-Key")
        keyed.httpBody = slot.body
        let final = keyed
        do {
            let value: T
            do {
                value = try await send(final, as: type)
            } catch let e as APIError where e.idempotencyCode == "idempotency_in_progress" {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                value = try await send(final, as: type)
            }
            RetryKeys.shared.finish(slot)
            return value
        } catch {
            // Ответа нет (сеть, таймаут, 5xx, отмена) или первый запрос ещё
            // идёт — ключ держим для повторного нажатия. Иначе — забываем.
            if !RetryKeys.keepAfter(error) { RetryKeys.shared.finish(slot) }
            throw error
        }
    }

    /// POST с телом application/x-www-form-urlencoded.
    /// Нужен там, где сервер читает поля из `$_POST` (PHP не наполняет $_POST из JSON-тела),
    /// например отклик на вакансию: POST api/v1/jobs/{id}/apply {name, phone}.
    /// Совпадает с Android @FormUrlEncoded — контракт 1:1.
    func postForm<T: Decodable>(_ path: String, form: [String: String], retryKey: Bool = false) async throws -> T {
        guard let url = URLComponents(string: API.base + "/" + path)?.url else { throw APIError.network }
        // percent-кодирование значений (пробелы, кириллица, '+', '&', '=' и т.п.)
        var enc = CharacterSet.urlQueryAllowed
        enc.remove(charactersIn: "+&=")
        let bodyStr = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: enc) ?? value)"
        }.joined(separator: "&")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        req.httpBody = bodyStr.data(using: .utf8)
        if retryKey { return try await sendKeyed(req, as: T.self) }
        return try await send(req, as: T.self)
    }
    func postFormVoid(_ path: String, form: [String: String], retryKey: Bool = false) async throws {
        _ = try await postForm(path, form: form, retryKey: retryKey) as EmptyResp
    }

    /// Multipart-загрузка фото в чат заказа: POST api/v1/orders/{id}/chat/photo (field "photo").
    /// Возвращает относительный путь вложения. Проходит через send() (конверт/401/ретрай).
    func uploadChatPhoto(orderId: Int, jpeg: Data, caption: String = "") async throws -> String? {
        struct PhotoResp: Decodable { let attachment: String? }
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: API.base + "/api/v1/orders/\(orderId)/chat/photo")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        if !caption.isEmpty { field("caption", caption) }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let r: PhotoResp = try await send(req, as: PhotoResp.self)
        return r.attachment
    }
    // ── Доска объявлений (routes/ads.php) ──────────────────────────────────
    //
    // Загрузка фото лежит ЗДЕСЬ, а не в отдельном файле: send() приватный и
    // виден только внутри этого файла, а именно он разбирает конверт ответа,
    // обновляет токен по 401 и повторяет запрос.
    func adCategories() async throws -> AdCategoriesResponse {
        try await get("api/v1/ads/categories")
    }
    func ads(categoryId: Int = 0, q: String = "", cityId: Int = 0,
             priceMin: String = "", priceMax: String = "",
             sort: String = "new", withPhoto: Bool = false, page: Int = 1) async throws -> AdsFeedResponse {
        var query: [String: String] = ["sort": sort, "page": String(page)]
        if categoryId > 0 { query["category_id"] = String(categoryId) }
        if !q.isEmpty { query["q"] = q }
        if cityId > 0 { query["city_id"] = String(cityId) }
        if !priceMin.isEmpty { query["price_min"] = priceMin }
        if !priceMax.isEmpty { query["price_max"] = priceMax }
        if withPhoto { query["with_photo"] = "1" }
        return try await get("api/v1/ads", query: query)
    }
    func ad(_ id: Int) async throws -> AdDetailResponse { try await get("api/v1/ads/\(id)") }
    func myAds() async throws -> MyAdsResponse { try await get("api/v1/ads/my") }
    /// Избранные объявления. Постранично — как обычная лента.
    func adFavorites(page: Int = 1) async throws -> AdsFeedResponse {
        try await get("api/v1/ads/favorites", query: ["page": String(page)])
    }
    // П-27.14: с ключом повтора — обрыв связи и повторное «Сохранить» не дают второй черновик.
    func adCreate(_ body: AdSaveBody) async throws -> AdCreatedResponse { try await post("api/v1/ads", body: body, retryKey: true) }
    func adUpdate(_ id: Int, _ body: AdSaveBody) async throws { try await putVoid("api/v1/ads/\(id)", body: body) }
    /// Оплатить и опубликовать. expectedPrice — сумма с кнопки: цена рубрики изменилась —
    /// 409 price_changed (см. AdPublishBody, priceChangedTo), денег не списано.
    /// Ключа повтора у этой ручки на сервере нет (v1IdemReplay не зовётся): двойное
    /// списание отсекает сам Ads::publish (активное = дубликат, платёж за 2 минуты = повтор).
    func adPublish(_ id: Int, expectedPrice: Decimal? = nil) async throws -> AdPublishResponse {
        try await post("api/v1/ads/\(id)/publish", body: AdPublishBody(renew: nil, expectedPrice: expectedPrice.map { Money.wire($0) }))
    }
    /// Продлить действующее объявление заранее (последние 3 дня срока). Сервер продлевает только по явному renew=true.
    func adRenew(_ id: Int, expectedPrice: Decimal? = nil) async throws -> AdPublishResponse {
        try await post("api/v1/ads/\(id)/publish", body: AdPublishBody(renew: true, expectedPrice: expectedPrice.map { Money.wire($0) }))
    }
    func adArchive(_ id: Int) async throws { _ = try await post("api/v1/ads/\(id)/archive", body: [String: String]()) as EmptyResp }
    func adDelete(_ id: Int) async throws { try await deleteVoid("api/v1/ads/\(id)") }
    func adPhotoDelete(adId: Int, photoId: Int) async throws { try await deleteVoid("api/v1/ads/\(adId)/photos/\(photoId)") }
    func adFavorite(_ id: Int) async throws -> AdFavoriteResponse { try await post("api/v1/ads/\(id)/favorite") }
    func adContact(_ id: Int) async throws -> AdContactResponse { try await post("api/v1/ads/\(id)/contact") }
    func adReport(_ id: Int, reason: String, comment: String?) async throws {
        _ = try await post("api/v1/ads/\(id)/report", body: AdReportBody(reason: reason, comment: comment)) as EmptyResp
    }

    /// Одна фотография объявления: POST api/v1/ads/{id}/photos, поле "photo".
    func uploadAdPhoto(adId: Int, jpeg: Data) async throws -> AdPhoto? {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: API.base + "/api/v1/ads/\(adId)/photos")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let token = TokenStore.access { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"photo.jpg\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let r: AdPhotoUploadedResponse = try await send(req, as: AdPhotoUploadedResponse.self)
        return r.photo
    }

    func deleteVoid(_ path: String) async throws { _ = try await send(try makeRequest("DELETE", path), as: EmptyResp.self) }
    func putVoid(_ path: String, body: Encodable? = nil) async throws { _ = try await send(try makeRequest("PUT", path, body: body), as: EmptyResp.self) }
}

extension API {
    /// П-21.3 (А58): весь список по meta.has_more — для коротких списков без
    /// подвала догрузки (вакансии, записи). Пустая страница = конец (у записей
    /// has_more изредка true при пустой следующей). Дубли на стыке — по `key`.
    /// Первая страница упала — ошибка; сбой на следующих — отдаём собранное.
    /// Старый сервер без meta — одна страница, как раньше.
    func allPages<T: Decodable, K: Hashable>(_ path: String, query: [String: String] = [:],
                                             maxPages: Int = 20, key: (T) -> K) async throws -> [T] {
        let first: Page<T> = try await page(path, query: query)
        var seen = Set<K>()
        var items = first.items.filter { seen.insert(key($0)).inserted }
        var more = first.hasMore && !first.items.isEmpty
        var n = 1
        while more && n < maxPages {
            n += 1
            var q = query; q["page"] = String(n)
            // Отмена (ушли с экрана) — наверх, а не «неполный список»; прочие сбои
            // хвоста — возвращаем то, что успели собрать.
            let p: Page<T>
            do { p = try await page(path, query: q) }
            catch is CancellationError { throw CancellationError() }
            catch { break }
            items += p.items.filter { seen.insert(key($0)).inserted }
            more = p.hasMore && !p.items.isEmpty
        }
        return items
    }
}

// MARK: - Вспомогательные типы транспорта
// (восстановлено: в исходном моторе жили в хвосте API.swift, который был обрезан)

/// Стирание типа для Encodable-тела запроса — чтобы принимать любой Encodable
/// и корректно прогонять через JSONEncoder с .convertToSnakeCase.
struct AnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(_ wrapped: Encodable) { self.encodeFunc = wrapped.encode }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }
}

/// Пустой ответ для запросов без полезной нагрузки (postVoid/putVoid/deleteVoid).
/// Толерантен к пустому data / отсутствию тела.
struct EmptyResp: Decodable {
    init() {}
    init(from decoder: Decoder) throws {}
}

/// Тело регистрации push-токена: POST /api/v1/push/register.
/// camelCase → snake_case автоматически через .convertToSnakeCase.
struct PushBody: Encodable {
    let token: String
    let platform: String
    /// Город, выбранный в приложении. Сервер иначе не знает, где клиент, и не
    /// может прислать «новое заведение в вашем городе». Поле аддитивное:
    /// nil не кодируется, старый сервер его игнорирует.
    var cityId: Int? = nil
    /// А105: статистика установок (core/AppInstalls.php::fromPush) — app_version,
    /// app_build, device_id, device_model, os_version. Все необязательные: nil не
    /// кодируется, старый сервер поля игнорирует.
    var appVersion: String? = nil
    var appBuild: Int? = nil
    var deviceId: String? = nil
    var deviceModel: String? = nil
    var osVersion: String? = nil
}

/// Single-flight для продления токена: все параллельные 401 ждут один вызов.
private actor RefreshGate {
    private var running: Task<API.RefreshOutcome, Never>?

    func run(_ work: @escaping () async -> API.RefreshOutcome) async -> API.RefreshOutcome {
        if let r = running { return await r.value }
        let t = Task { await work() }
        running = t
        let v = await t.value
        running = nil
        return v
    }
}

/// П-27.14: ключи повтора для запросов создания. Ключ живёт, пока на запрос не
/// пришёл ответ: то же нажатие ещё раз (тот же адрес, то же тело) после обрыва
/// связи уходит с тем же ключом и теми же байтами тела — сервер отдаёт прежний
/// ответ. Тело сравниваем без учёта порядка ключей JSON / полей формы: словарь
/// кодируется каждый раз в своём порядке, а отпечаток тела на сервере от
/// порядка полей зависит (иначе был бы 422 idempotency_key_reused).
final class RetryKeys {
    static let shared = RetryKeys()
    struct Slot { let id: String; let key: String; let body: Data? }
    private struct Entry { let key: String; let body: Data?; let at: Date }
    private var entries: [String: Entry] = [:]
    private let lock = NSLock()
    /// Дольше не держим: сервер помнит ответ двое суток, но через полчаса
    /// повторное нажатие — уже новое действие человека.
    private let ttl: TimeInterval = 30 * 60

    func take(path: String, body: Data?) -> Slot {
        let id = path + "\n" + Self.fingerprint(body)
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        entries = entries.filter { now.timeIntervalSince($0.value.at) < ttl }
        if let e = entries[id] { return Slot(id: id, key: e.key, body: e.body) }
        let key = UUID().uuidString.lowercased()
        entries[id] = Entry(key: key, body: body, at: now)
        return Slot(id: id, key: key, body: body)
    }

    func finish(_ slot: Slot) {
        lock.lock(); defer { lock.unlock() }
        if entries[slot.id]?.key == slot.key { entries[slot.id] = nil }
    }

    /// Держать ли ключ после ошибки: ответа не было (сеть, таймаут, 5xx,
    /// отмена) или первый запрос ещё выполняется.
    static func keepAfter(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        guard let e = error as? APIError else { return false }
        switch e {
        case .network, .timeout: return true
        case .http(let c):       return c >= 500
        default:                 return e.idempotencyCode == "idempotency_in_progress"
        }
    }

    private static func fingerprint(_ body: Data?) -> String {
        guard let body = body, !body.isEmpty else { return "" }
        if let obj = try? JSONSerialization.jsonObject(with: body),
           JSONSerialization.isValidJSONObject(obj),
           let sorted = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            return String(decoding: sorted, as: UTF8.self)
        }
        let s = String(decoding: body, as: UTF8.self)
        return s.split(separator: "&").sorted().joined(separator: "&")
    }
}

// MARK: - А79 «Отправить посылку»: сырой ответ (код + тело)

extension API {
    /// Запрос с готовым JSON-телом и ответом «как есть» (HTTP-код + байты).
    /// Нужен экрану посылок: общий разбор отбрасывает error.code и details по
    /// полям (у посылок это списки строк: {"fee": ["…"]}), а без них нельзя
    /// подсветить поле 422 и понять 409 price_changed. Вход, продление токена
    /// по 401 и ошибки сети — как у остальных запросов. Без повторов: это
    /// создание и действия, их повторяет сам экран с тем же ключом.
    /// long: true — сессия с ожиданием ответа до 60 с (помощник, А100).
    func raw(_ method: String, _ path: String, json: Data?, headers: [String: String] = [:],
             query: [String: String] = [:], long: Bool = false) async throws -> (status: Int, data: Data) {
        var req = try makeRequest(method, path, query: query)
        req.httpBody = json
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if long { req.timeoutInterval = 60 }
        return try await rawPerform(req, isRetryAfterRefresh: false, long: long)
    }

    private func rawPerform(_ req: URLRequest, isRetryAfterRefresh: Bool, long: Bool = false) async throws -> (status: Int, data: Data) {
        let data: Data; let resp: URLResponse
        do {
            (data, resp) = try await (long ? longSession : session).data(for: req)
        } catch let urlError as URLError {
            if urlError.code == .cancelled { throw CancellationError() }
            if urlError.code == .timedOut {
                if await API.offlineNow() { throw APIError.network }
                throw APIError.timeout
            }
            throw APIError.network
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw APIError.network
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            // Та же логика, что в perform: свежий токен от параллельного запроса,
            // иначе одно продление и один повтор.
            if !isRetryAfterRefresh {
                if let current = TokenStore.access, !current.isEmpty,
                   req.value(forHTTPHeaderField: "Authorization") != "Bearer \(current)" {
                    var retry = req
                    retry.setValue("Bearer \(current)", forHTTPHeaderField: "Authorization")
                    return try await rawPerform(retry, isRetryAfterRefresh: false, long: long)
                }
                switch await refreshAccessToken() {
                case .token(let newToken):
                    var retry = req
                    retry.setValue("Bearer \(newToken)", forHTTPHeaderField: "Authorization")
                    return try await rawPerform(retry, isRetryAfterRefresh: true, long: long)
                case .unavailable:
                    throw APIError.network
                case .rejected:
                    break
                }
            }
            if let handler = onUnauthorized { await MainActor.run { handler() } }
            if req.value(forHTTPHeaderField: "Authorization") == nil { throw APIError.guestNeedsLogin }
            throw APIError.unauthorized
        }
        return (status, data)
    }
}
