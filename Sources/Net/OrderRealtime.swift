import Foundation

/// Живые обновления заказа (сервер: Centrifugo, GET api/v1/realtime/token?order_id=N,
/// однонаправленный WebSocket uni_websocket, канал order:N). Событие — подсказка
/// «перечитай»: экран перечитывает заказ тем же кодом, что и опрос. Опрос остаётся
/// запасным. Модуль на сервере выключен / нет прав — тихо ждём 10 минут.

/// Разобранный кадр сервера.
enum RealtimeFrame: Equatable {
    case connected(pingSec: Int)
    case disconnect(code: Int, terminal: Bool)
    case pub(channel: String, orderId: Int)
    case other
}

enum RealtimeLogic {
    /// Коды 3500–3999 и 4500–4999 — «не переподключаться» (протокол Centrifugo).
    static func isTerminal(_ code: Int) -> Bool { (3500..<4000).contains(code) || (4500..<5000).contains(code) }

    /// Число из JSON толерантно: 5, "5", 5.0.
    private static func num(_ v: Any?) -> Int {
        if let n = v as? Int { return n }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let d = Double(s) { return Int(d) }
        return 0
    }

    /// Кадры одним сообщением: JSON-объекты через перевод строки. Битое — пропускаем.
    static func parse(_ text: String) -> [RealtimeFrame] {
        var out: [RealtimeFrame] = []
        for line in text.split(separator: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            guard let data = l.data(using: .utf8),
                  let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if let c = o["connect"] as? [String: Any] {
                out.append(.connected(pingSec: num(c["ping"])))
            } else if let d = o["disconnect"] as? [String: Any] {
                let code = num(d["code"])
                out.append(.disconnect(code: code, terminal: isTerminal(code)))
            } else if let ch = o["channel"] as? String, let pub = o["pub"] as? [String: Any] {
                let body = pub["data"] as? [String: Any]
                out.append(.pub(channel: ch, orderId: num(body?["order_id"])))
            } else {
                out.append(.other)
            }
        }
        return out
    }

    /// Пауза перед переподключением, секунды: 1,2,4,…60 (attempt с 1) × разброс.
    static func backoff(_ attempt: Int, jitter: Double = 1.0) -> Double {
        let base = min(60.0, pow(2.0, Double(min(max(attempt - 1, 0), 6))))
        return base * jitter
    }
}

/// Ответ api/v1/realtime/token (нужные поля; всё необязательное — старый сервер не роняет разбор).
private struct RealtimeBundle: Decodable {
    var enabled: Bool?
    var uniWsUrl: String?
    var uniToken: String?
}

/// Общие поля сторожа и приёмника (простые значения).
private final class RealtimeBox: @unchecked Sendable {
    var last = Date()
    var pingSec: Double = 25
}

enum OrderRealtime {
    private static let offRetry: Double = 600
    private enum Outcome { case terminal, wasLive, neverLive }
    private enum Token { case ok(URL, String), off, retry }

    /// Работает, пока задача не отменена (уход с экрана / в фон). onLive(true) — соединение
    /// установлено (опрос можно делать реже); onEvent — событие по заказу либо связь
    /// восстановилась после обрыва. Колбэки вызываются на главном потоке.
    static func watch(orderId: Int, onLive: @escaping @MainActor (Bool) -> Void, onEvent: @escaping @MainActor () -> Void) async {
        guard orderId > 0 else { return }
        var attempt = 0
        var everLive = false
        while !Task.isCancelled {
            let logged = await MainActor.run { Session.shared.isLoggedIn }
            if !logged { break }
            switch await fetchToken(orderId) {
            case .off:
                attempt = 0
                if await pause(offRetry) { return }
            case .retry:
                attempt += 1
                if await pause(RealtimeLogic.backoff(attempt, jitter: 0.7 + Double.random(in: 0...0.6))) { return }
            case .ok(let url, let token):
                let r = await runSocket(url: url, token: token, orderId: orderId, resync: everLive, onLive: onLive, onEvent: onEvent)
                await MainActor.run { onLive(false) }
                if r != .neverLive { everLive = true }
                if Task.isCancelled { return }
                if r == .terminal {
                    attempt = 0
                    if await pause(offRetry) { return }
                } else {
                    attempt = (r == .wasLive) ? 1 : attempt + 1
                    if await pause(RealtimeLogic.backoff(attempt, jitter: 0.7 + Double.random(in: 0...0.6))) { return }
                }
            }
        }
        await MainActor.run { onLive(false) }
    }

    /// Пауза; true — задачу отменили, выходим.
    private static func pause(_ sec: Double) async -> Bool {
        try? await Task.sleep(nanoseconds: UInt64(sec * 1_000_000_000))
        return Task.isCancelled
    }

    private static func fetchToken(_ orderId: Int) async -> Token {
        do {
            let b: RealtimeBundle = try await API.shared.get("api/v1/realtime/token", query: ["order_id": String(orderId)])
            guard b.enabled == true, let u = b.uniWsUrl, let url = URL(string: u),
                  let t = b.uniToken, !t.isEmpty else { return .off }
            return .ok(url, t)
        } catch let e as APIError {
            if case .unauthorized = e { return .off }
            if case .guestNeedsLogin = e { return .off }
            if let s = e.rejectStatus, [401, 403, 404, 422].contains(s) { return .off }
            return .retry
        } catch {
            return .retry
        }
    }

    private static func runSocket(url: URL, token: String, orderId: Int, resync: Bool,
                                  onLive: @escaping @MainActor (Bool) -> Void,
                                  onEvent: @escaping @MainActor () -> Void) async -> Outcome {
        let ws = URLSession.shared.webSocketTask(with: url)
        ws.resume()
        let helloData = try? JSONSerialization.data(withJSONObject: ["token": token, "name": "ios"])
        let hello = helloData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let box = RealtimeBox()
        var live = false
        var result: Outcome = .neverLive
        return await withTaskCancellationHandler(operation: { () async -> Outcome in
            do {
                try await ws.send(.string(hello))
                // Ни кадра (даже пинга) дольше двух интервалов — связь мертва: закрываем сокет.
                let watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 5_000_000_000)
                        if Task.isCancelled { return }
                        if Date().timeIntervalSince(box.last) > box.pingSec * 2 + 10 {
                            ws.cancel(with: .goingAway, reason: nil)
                            return
                        }
                    }
                }
                defer { watchdog.cancel() }
                while !Task.isCancelled {
                    let msg = try await ws.receive()
                    box.last = Date()
                    var text = ""
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
                    @unknown default: break
                    }
                    for f in RealtimeLogic.parse(text) {
                        switch f {
                        case .connected(let p):
                            if p > 0 { box.pingSec = max(5.0, Double(p)) }
                            live = true
                            result = .wasLive
                            await MainActor.run { onLive(true) }
                            if resync { await MainActor.run { onEvent() } }
                        case .disconnect(_, let terminal):
                            ws.cancel(with: .normalClosure, reason: nil)
                            return terminal ? .terminal : (live ? .wasLive : .neverLive)
                        case .pub(_, let oid):
                            if oid == orderId { await MainActor.run { onEvent() } }
                        case .other:
                            break
                        }
                    }
                }
            } catch {
                // обрыв / отмена — выходим с тем, что успели
            }
            ws.cancel(with: .normalClosure, reason: nil)
            return result
        }, onCancel: {
            ws.cancel(with: .goingAway, reason: nil)
        })
    }
}
