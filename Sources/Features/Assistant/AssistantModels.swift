//
//  AssistantModels.swift — «Помощник Yumurta» (ИИ, волна сайта А100): модели,
//  запросы, разбор ответа и тексты ошибок. Экран — AssistantView.swift.
//
//  Ручки api/v1/assistant/… (routes/assistant.php, core/Assistant.php), конверт v1
//  {success, data, meta, error: {message, details}}. POST-ручки висят под middleware
//  csrf, но Middleware::csrf пропускает запрос с «Authorization: Bearer <токен из 20+
//  знаков>» — его ставит API.makeRequest. Без входа POST получил бы 403
//  «Недействительный CSRF-токен», поэтому гостю экран сначала предлагает войти.
//
//  Паритет с Android: ui/screens/assistant/AssistantText.kt (AssistantMd,
//  AssistantErrors) и AssistantScreen.kt.
//

import Foundation

// MARK: - Модели (все поля необязательные; числа и флаги — терпимо)

/// GET api/v1/assistant/status?audience=client.
struct AssistantStatus: Decodable {
    @LenientBool var enabled: Bool?
    /// client | seller | guest — guest у вошедшего = access-токен уже не принят.
    let audience: String?
    let name: String?
    let greeting: String?
    let disclaimer: String?
    let suggestions: [String]?
    @LenientBool var canHandoff: Bool?
    @LenientBool var loginRequired: Bool?
    /// nil — без дневного лимита.
    @LenientInt var leftToday: Int?
    @LenientInt var maxLength: Int?
}

/// Статья базы знаний, на которую опирался ответ. url — от корня сайта ("/help/slug").
struct AssistantSource: Decodable {
    let title: String?
    let url: String?
    /// true — ссылка на статью уже есть в тексте ответа.
    @LenientBool var cited: Bool?
}

/// Сообщение переписки (Assistant::present). role: user | assistant.
struct AssistantMessage: Decodable {
    @LenientInt var id: Int?
    let role: String?
    let text: String?
    let sources: [AssistantSource]?
    /// 1 | -1 | nil
    @LenientInt var rating: Int?
    let createdAt: String?
}

struct AssistantAskResp: Decodable {
    let chatId: String?
    let question: AssistantMessage?
    let reply: AssistantMessage?
    @LenientInt var leftToday: Int?
}

struct AssistantChatInfo: Decodable {
    let id: String?
    /// open | handed
    let status: String?
    let handoffKind: String?
}

/// GET api/v1/assistant/chat?id=&audience= — последние 100 сообщений по порядку.
struct AssistantChatResp: Decodable {
    let chat: AssistantChatInfo?
    let messages: [AssistantMessage]?
}

struct AssistantRateResp: Decodable { @LenientInt var rating: Int? }

/// kind: ticket (покупатель — обращение в поддержку) | shop_support (организация).
struct AssistantHandoffResp: Decodable {
    let kind: String?
    @LenientInt var id: Int?
    let url: String?
    @LenientBool var already: Bool?
}

/// Тело вопроса. chatId = nil — новая переписка (nil не кодируется).
private struct AssistantAskBody: Encodable {
    let chatId: String?
    let text: String
    let audience: String
    let page: String?
}
private struct AssistantRateBody: Encodable {
    let chatId: String
    let messageId: Int
    let rating: Int
    let audience: String
}
private struct AssistantHandoffBody: Encodable {
    let chatId: String
    let audience: String
}

/// Отказ на вопрос: код, текст для человека и chat_id из 502 (переписка сохранена).
struct AssistantFailure: LocalizedError {
    let status: Int
    let message: String
    let chatId: String?
    var errorDescription: String? { message }
}

// MARK: - Запросы

enum AssistantAPI {
    static let audience = "client"
    /// Где человек: сервер оставляет буквы, цифры и « /?=&._-» (запятые и «→» срезает).
    static let page = "Приложение Yumurta для iPhone - Профиль / Поддержка"

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d
    }()

    /// Статус. Ручка без обязательного входа: просроченный access-токен сервер не
    /// отвергает (401 и продления не будет), а молча считает человека гостем —
    /// audience = guest, и у вошедшего не было бы кнопки. Тогда один запрос профиля
    /// (на нём 401 → тихое продление) и статус ещё раз.
    static func status() async throws -> AssistantStatus {
        let s: AssistantStatus = try await API.shared.get("api/v1/assistant/status", query: ["audience": audience])
        let logged = await MainActor.run { Session.shared.isLoggedIn }
        guard logged, s.audience == "guest" else { return s }
        _ = try? await API.shared.get("api/v1/profile") as EmptyResp
        guard await MainActor.run(body: { Session.shared.isLoggedIn }) else { return s }
        return try await API.shared.get("api/v1/assistant/status", query: ["audience": audience])
    }

    static func chat(id: String) async throws -> AssistantChatResp {
        try await API.shared.get("api/v1/assistant/chat", query: ["id": id, "audience": audience])
    }

    /// Вопрос. Своя сессия с ожиданием до 60 с (ответ модели — 10–30 с); ответ
    /// разбираем сами — общий разбор теряет details.chat_id у 502.
    static func ask(chatId: String?, text: String) async throws -> AssistantAskResp {
        let body = try API.encoder.encode(AssistantAskBody(chatId: chatId, text: text, audience: audience, page: page))
        let r = try await API.shared.raw("POST", "api/v1/assistant/messages", json: body, long: true)
        return try decodeAsk(status: r.status, data: r.data)
    }

    /// Разбор ответа на вопрос (отдельно — проверяется без сети).
    static func decodeAsk(status: Int, data: Data) throws -> AssistantAskResp {
        let env = try? decoder.decode(APIEnvelope<AssistantAskResp>.self, from: data)
        if (200..<300).contains(status), env?.success != false, let d = env?.data { return d }
        // Ошибка: текст сервера (лимит, выключен, пусто/длинно), 502 — свой текст и chat_id.
        let code = (200..<300).contains(status) ? 0 : status
        let msg = env?.error?.message
        throw AssistantFailure(status: code,
                               message: (200..<300).contains(status) && msg == nil
                                   ? "Не удалось обработать ответ"
                                   : AssistantText.askError(code, msg),
                               chatId: AssistantText.chatIdFrom502(code, env?.error?.details?["chat_id"]))
    }

    static func rate(chatId: String, messageId: Int, rating: Int) async throws -> AssistantRateResp {
        try await API.shared.post("api/v1/assistant/rate",
                                  body: AssistantRateBody(chatId: chatId, messageId: messageId, rating: rating, audience: audience))
    }

    static func handoff(chatId: String) async throws -> AssistantHandoffResp {
        try await API.shared.post("api/v1/assistant/handoff", body: AssistantHandoffBody(chatId: chatId, audience: audience))
    }
}

// MARK: - Разбор ответа модели (короткий markdown)

/// Кусок строки: текст + начертание + адрес (nil — не ссылка).
struct MdSpan: Equatable {
    var text: String
    var bold = false
    var italic = false
    var url: String? = nil
}

/// Блок ответа. marker: nil — абзац, «•» — пункт списка, «1.» — пункт нумерованного.
struct MdBlock: Equatable {
    let marker: String?
    let spans: [MdSpan]
}

/// Порт render()/linkify() веб-виджета (assets/js/assistant.js), 1:1 с Android.
/// Абзацы, списки «- » / «* » / «• » и «1. » / «1) », **жирный**, *курсив*, `код`
/// (текстом), заголовки «# » (без решёток), ссылки полным адресом. Нажимаются ТОЛЬКО
/// ссылки на сам сайт (yumurta.ru и API.base) и относительные /help/…: модель могла бы —
/// по подсказке из вопроса или из названия заведения — вывести чужую (фишинговую)
/// ссылку; она остаётся текстом.
enum AssistantMd {
    private static func rx(_ p: String) -> NSRegularExpression? { try? NSRegularExpression(pattern: p, options: []) }
    private static let bullet = rx("^[-*•]\\s+(.*)$")
    private static let number = rx("^(\\d+)[.)]\\s+(.*)$")
    private static let header = rx("^#{1,6}\\s+")
    private static let bold = rx("\\*\\*([^*]+)\\*\\*")
    // Слово вокруг звёздочек — латиница/цифры: \w в ICU шире, чем в Java (Android).
    private static let italic = rx("(?<![*A-Za-z0-9_])\\*([^*\\s][^*]*)\\*(?![*A-Za-z0-9_])")
    private static let code = rx("`([^`]+)`")
    // Как в веб-виджете: последний знак адреса — не точка, запятая, скобка и т. п.
    private static let url = try? NSRegularExpression(pattern: "https?://[^\\s<>\"')«»]+[^\\s<>\"').,;:!?«»]", options: [.caseInsensitive])
    private static let help = rx("(^|[ \\t(«])(/help/[a-z0-9\\-]+)")

    private static func matches(_ re: NSRegularExpression?, _ s: String) -> [NSTextCheckingResult] {
        guard let re else { return [] }
        return re.matches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Разбор ответа на блоки. base — адрес сайта (API.base).
    static func parse(_ md: String?, base: String) -> [MdBlock] {
        var out: [MdBlock] = []
        for raw in (md ?? "").replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            let ns = l as NSString
            if let m = matches(bullet, l).first {
                out.append(MdBlock(marker: "•", spans: inline(ns.substring(with: m.range(at: 1)), base: base))); continue
            }
            if let m = matches(number, l).first {
                out.append(MdBlock(marker: ns.substring(with: m.range(at: 1)) + ".",
                                   spans: inline(ns.substring(with: m.range(at: 2)), base: base))); continue
            }
            let plainLine = header?.stringByReplacingMatches(in: l, options: [], range: NSRange(location: 0, length: ns.length), withTemplate: "") ?? l
            out.append(MdBlock(marker: nil, spans: inline(plainLine, base: base)))
        }
        return out
    }

    /// Строка → куски: жирный, затем курсив, затем ссылки внутри каждого куска.
    static func inline(_ s: String, base: String) -> [MdSpan] {
        let text = code?.stringByReplacingMatches(in: s, options: [], range: NSRange(location: 0, length: (s as NSString).length), withTemplate: "$1") ?? s
        let ns = text as NSString
        var out: [MdSpan] = []
        var pos = 0
        for m in matches(bold, text) {
            if m.range.location > pos { italics(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), base, &out) }
            links(ns.substring(with: m.range(at: 1)), bold: true, italic: false, base, &out)
            pos = m.range.location + m.range.length
        }
        if pos < ns.length { italics(ns.substring(from: pos), base, &out) }
        return merge(out)
    }

    private static func italics(_ s: String, _ base: String, _ out: inout [MdSpan]) {
        let ns = s as NSString
        var pos = 0
        for m in matches(italic, s) {
            if m.range.location > pos { links(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)), bold: false, italic: false, base, &out) }
            links(ns.substring(with: m.range(at: 1)), bold: false, italic: true, base, &out)
            pos = m.range.location + m.range.length
        }
        if pos < ns.length { links(ns.substring(from: pos), bold: false, italic: false, base, &out) }
    }

    /// Ссылки внутри куска одного начертания. Чужой адрес остаётся текстом.
    private static func links(_ s: String, bold b: Bool, italic i: Bool, _ base: String, _ out: inout [MdSpan]) {
        struct Hit { let start: Int; let end: Int; let url: String; let label: String }
        let ns = s as NSString
        var hits: [Hit] = []
        for m in matches(url, s) {
            let u = ns.substring(with: m.range)
            if isOwn(u, base: base) { hits.append(Hit(start: m.range.location, end: m.range.location + m.range.length, url: u, label: shortLabel(u))) }
        }
        for m in matches(help, s) {
            let g = m.range(at: 2)
            guard g.location != NSNotFound else { continue }
            let st = g.location, en = g.location + g.length
            if !hits.contains(where: { st < $0.end && en > $0.start }) {
                let path = ns.substring(with: g)
                hits.append(Hit(start: st, end: en, url: trimSlash(base) + path, label: path))
            }
        }
        hits.sort { $0.start < $1.start }
        var pos = 0
        for h in hits {
            if h.start < pos { continue }
            if h.start > pos { out.append(MdSpan(text: ns.substring(with: NSRange(location: pos, length: h.start - pos)), bold: b, italic: i)) }
            out.append(MdSpan(text: h.label, bold: b, italic: i, url: h.url))
            pos = h.end
        }
        if pos < ns.length { out.append(MdSpan(text: ns.substring(from: pos), bold: b, italic: i)) }
    }

    /// Соседние куски одного вида склеиваем.
    private static func merge(_ l: [MdSpan]) -> [MdSpan] {
        var out: [MdSpan] = []
        for sp in l where !sp.text.isEmpty {
            if let last = out.last, last.url == nil, sp.url == nil, last.bold == sp.bold, last.italic == sp.italic {
                out[out.count - 1].text += sp.text
            } else { out.append(sp) }
        }
        return out
    }

    private static func trimSlash(_ s: String) -> String {
        var t = s
        while t.hasSuffix("/") { t.removeLast() }
        return t
    }

    /// Адрес самого сайта: yumurta.ru / www.yumurta.ru или хост API.base, дальше «/», «?», «#» или конец.
    static func isOwn(_ u: String, base: String) -> Bool {
        var hosts = ["yumurta.ru"]
        if let hre = try? NSRegularExpression(pattern: "^https?://(?:www\\.)?([^/?#:@]+)", options: [.caseInsensitive]),
           let m = hre.firstMatch(in: base, options: [], range: NSRange(location: 0, length: (base as NSString).length)) {
            let h = (base as NSString).substring(with: m.range(at: 1)).lowercased()
            if !h.isEmpty, !hosts.contains(h) { hosts.append(h) }
        }
        let alt = hosts.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        guard let re = try? NSRegularExpression(pattern: "^https?://(?:www\\.)?(?:\(alt))(?:[/?#]|$)", options: [.caseInsensitive]) else { return false }
        return re.firstMatch(in: u, options: [], range: NSRange(location: 0, length: (u as NSString).length)) != nil
    }

    /// Подпись ссылки — без «https://» и «www.», как на сайте.
    static func shortLabel(_ u: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "^https?://(www\\.)?", options: [.caseInsensitive]) else { return u }
        return re.stringByReplacingMatches(in: u, options: [], range: NSRange(location: 0, length: (u as NSString).length), withTemplate: "")
    }

    /// Абсолютный адрес источника (сервер шлёт "/help/slug"). Не свой — nil.
    static func sourceURL(_ u: String?, base: String) -> String? {
        let s = (u ?? "").trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        let full = s.hasPrefix("/") ? trimSlash(base) + s : s
        return isOwn(full, base: base) ? full : nil
    }

    /// Текст для VoiceOver: блоки построчно, пункты — с маркером.
    static func plain(_ blocks: [MdBlock]) -> String {
        blocks.map { b in (b.marker.map { $0 + " " } ?? "") + b.spans.map(\.text).joined() }.joined(separator: "\n")
    }
}

// MARK: - Тексты (коды — routes/assistant.php), 1:1 с Android AssistantErrors

enum AssistantText {
    /// Ошибка вопроса. 502 — модель не ответила (переписка сохранена) — свой текст;
    /// 422/429/503/404 — текст сервера как есть; без текста — по коду.
    static func askError(_ code: Int?, _ serverMsg: String?) -> String {
        if code == 502 { return "Помощник не ответил — попробуйте ещё раз" }
        let m = (serverMsg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !m.isEmpty { return m }
        switch code {
        case 422: return "Проверьте вопрос: он пустой или слишком длинный"
        case 429: return "На сегодня вопросы закончились — напишите в поддержку"
        case 503: return "Помощник сейчас недоступен — попробуйте позже"
        case 404: return "Переписка не найдена — начните новую"
        default:  return "Не получилось получить ответ. Повторите позже"
        }
    }

    /// chat_id из details ответа 502 — строка из 32 hex-знаков, иначе nil.
    static func chatIdFrom502(_ code: Int?, _ detailsChatId: String?) -> String? {
        guard code == 502, let s = detailsChatId?.trimmingCharacters(in: .whitespaces),
              s.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil else { return nil }
        return s
    }

    /// Подпись о лимите: только когда осталось 5 и меньше.
    static func leftLabel(_ left: Int?) -> String? {
        guard let left, (0...5).contains(left) else { return nil }
        return "Осталось вопросов сегодня: \(left)"
    }

    /// Счётчик знаков: показываем с 80 % лимита.
    static func counter(_ len: Int, _ max: Int) -> String? {
        max > 0 && len * 5 >= max * 4 ? "\(len) / \(max)" : nil
    }

    /// Итог «Позвать человека» для покупателя. А102: handoff ответил kind = ticket и номер —
    /// ответ придёт в это обращение («Мои обращения») и в уведомления, под текстом ссылка
    /// «Открыть обращение». Иначе (нет номера, другой kind) — как раньше: «Уведомления».
    static func handoffText(already: Bool, id: Int?, ticket: Bool = false) -> String {
        let n = (id ?? 0) > 0 ? id : nil
        if ticket, let n {
            return already ? "Уже передано — обращение №\(n). Ответ придёт в него и в уведомления."
                : "Обращение №\(n) создано — ответ придёт в него и в уведомления."
        }
        if already {
            return "Уже передано" + (n.map { " — обращение №\($0)" } ?? "") + ". Ответ придёт в «Уведомления»."
        }
        return "Обращение" + (n.map { " №\($0)" } ?? "") + " создано — ответ придёт в «Уведомления»."
    }

    /// А102: номер обращения для перехода — только kind = ticket и id > 0; иначе nil (как раньше).
    static func handoffTicket(kind: String?, id: Int?) -> Int? {
        guard kind == "ticket", let id, id > 0 else { return nil }
        return id
    }

    /// Вопрос остаётся в переписке: 502 (модель не ответила — сервер вопрос сохранил)
    /// и 504 (шлюз не дождался — сервер, скорее всего, дописал). Остальное — не принят.
    static func keepQuestion(_ code: Int?) -> Bool { code == 502 || code == 504 }

    /// Длина в кодовых точках — как mb_strlen на сервере (и как Android).
    static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// Обрезать до max кодовых точек.
    static func clip(_ s: String, _ max: Int) -> String {
        guard max > 0, length(s) > max else { return s }
        var u = String.UnicodeScalarView()
        u.append(contentsOf: s.unicodeScalars.prefix(max))
        return String(u)
    }
}
