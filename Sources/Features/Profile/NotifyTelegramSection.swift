//
//  NotifyTelegramSection.swift — Настройки → «Уведомления по типам» и «Telegram».
//  Паритет Android (NotifyTelegramSections.kt). Только для вошедшего.
//   • GET/POST api/v1/profile/notify-settings (ключи new_shops, promos, news, rate_order + labels с подписями);
//   • GET api/v1/profile/telegram, POST/DELETE api/v1/profile/telegram/link.
//  Системное разрешение iOS на уведомления остаётся в SettingsView.
//

import SwiftUI
import UIKit

struct NotifyRow: Identifiable {
    let key: String
    let label: String
    var on: Bool
    var id: String { key }
}

/// Ответ notify-settings: флаги 0/1 по ключам + `labels {ключ: подпись}`.
/// Декодер проекта — convertFromSnakeCase, он переписывает и динамические ключи
/// (new_shops -> newShops), поэтому ключи здесь camelCase; на сервер уходят snake_case (`snakeKey`).
struct NotifySettingsDTO: Decodable {
    private struct DynKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    /// Известные ключи (camelCase) и их русские подписи на случай, если сервер не прислал labels.
    static let known: [(key: String, label: String)] = [
        ("newShops", "Новые заведения в моём городе"),
        ("promos", "Акции и скидки"),
        ("news", "Новости площадки"),
        ("rateOrder", "Просьба оценить заказ"),
    ]
    var flags: [String: Bool] = [:]
    var labels: [String: String] = [:]

    /// 1/0, true/false, "1"/"0" — любой вид; nil — не флаг.
    static func flag<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ k: K) -> Bool? {
        if let b = try? c.decode(Bool.self, forKey: k) { return b }
        if let i = try? c.decode(Int.self, forKey: k) { return i != 0 }
        if let d = try? c.decode(Double.self, forKey: k) { return d != 0 }
        if let s = try? c.decode(String.self, forKey: k) {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            case "0", "false", "no", "off", "": return false
            default: return Double(s).map { $0 != 0 }
            }
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: DynKey.self)
        if let lk = DynKey(stringValue: "labels"), let lc = try? c.nestedContainer(keyedBy: DynKey.self, forKey: lk) {
            for k in lc.allKeys {
                if let t = try? lc.decode(String.self, forKey: k) {
                    let tt = t.trimmingCharacters(in: .whitespaces)
                    if !tt.isEmpty { labels[k.stringValue] = tt }
                }
            }
        }
        for k in c.allKeys where k.stringValue != "labels" {
            if let f = NotifySettingsDTO.flag(c, k) { flags[k.stringValue] = f }
        }
    }

    /// Показываемые строки: ключ с подписью (сервера или известной) и значением; порядок стабильный:
    /// сначала известные, затем прочие по алфавиту.
    var rows: [NotifyRow] {
        let knownKeys = NotifySettingsDTO.known.map { $0.key }
        let extra = labels.keys.filter { !knownKeys.contains($0) }.sorted()
        var out: [NotifyRow] = []
        for k in knownKeys + extra {
            guard let on = flags[k] else { continue }
            guard let l = labels[k] ?? NotifySettingsDTO.known.first(where: { $0.key == k })?.label else { continue }
            out.append(NotifyRow(key: k, label: l, on: on))
        }
        return out
    }

    /// newShops -> new_shops (для тела запроса).
    static func snakeKey(_ k: String) -> String {
        var out = ""
        for ch in k {
            if ch.isUppercase { out += "_" + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }
}

struct TelegramStatusDTO: Decodable {
    @LenientBool var enabled: Bool?
    @LenientBool var connected: Bool?
    let bot: String?
}

struct TelegramLinkDTO: Decodable {
    let url: String?
    let code: String?
}

enum NotifyTelegramLogic {
    /// Ссылку открываем только http/https/tg.
    static func isOpenable(_ url: String?) -> Bool {
        guard let u = url?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return u.hasPrefix("https://") || u.hasPrefix("http://") || u.hasPrefix("tg://")
    }
}

struct NotifyTelegramSection: View {
    @EnvironmentObject private var session: Session

    var body: some View {
        if session.isLoggedIn {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                NotifyTypesCard()
                TelegramCard()
            }
        }
    }
}

private extension View {
    func notifyCard() -> some View {
        self
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

private struct NotifyTypesCard: View {
    @State private var rows: [NotifyRow] = []
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Group {
            if !rows.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Уведомления по типам").ymFont(13, weight: .heavy).foregroundStyle(YMColor.text)
                    ForEach(rows) { row in
                        Toggle(row.label, isOn: Binding(
                            get: { row.on },
                            set: { save(row.key, $0) }
                        ))
                        .disabled(saving)
                    }
                    Text("Статусы заказов и сообщения в чате заказа не отключаются — они нужны для заказа.")
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                    if let error, !error.isEmpty {
                        Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    }
                }
                .notifyCard()
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let r: NotifySettingsDTO = try? await API.shared.get("api/v1/profile/notify-settings", fresh: true) {
            rows = r.rows
        }
    }

    private func setRow(_ key: String, _ on: Bool) {
        if let i = rows.firstIndex(where: { $0.key == key }) { rows[i].on = on }
    }

    /// Частичный POST: уходит только один изменённый ключ.
    private func save(_ key: String, _ next: Bool) {
        guard !saving else { return }
        let prev = rows.first(where: { $0.key == key })?.on
        setRow(key, next)          // сразу
        saving = true; error = nil
        Task { @MainActor in
            do {
                let r: NotifySettingsDTO = try await API.shared.post(
                    "api/v1/profile/notify-settings",
                    body: [NotifySettingsDTO.snakeKey(key): next ? 1 : 0])
                if let v = r.flags[key] { setRow(key, v) }
            } catch {
                if let p = prev { setRow(key, p) }  // откат
                self.error = error.localizedDescription
            }
            saving = false
        }
    }
}

private struct TelegramCard: View {
    @State private var enabled = false
    @State private var connected = false
    @State private var busy = false
    @State private var waiting = false
    @State private var error: String?
    @State private var confirmOff = false

    var body: some View {
        Group {
            if enabled {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Telegram").ymFont(13, weight: .heavy).foregroundStyle(YMColor.text)
                    Text(connected ? "Telegram подключён" : "Telegram не подключён")
                        .ymFont(15, weight: .semibold).foregroundStyle(YMColor.text)
                    Text(connected
                         ? "Поддержка отвечает вам и в Telegram."
                         : "Подключите Telegram, чтобы общаться с поддержкой в мессенджере.")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    if waiting && !connected {
                        Text("Нажмите «Start» в Telegram, затем вернитесь сюда и нажмите «Проверить».")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    if let error, !error.isEmpty {
                        Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    }
                    actions
                }
                .notifyCard()
            }
        }
        .task { await reload() }
        .alert("Отключить Telegram?", isPresented: $confirmOff) {
            Button("Отключить", role: .destructive) { unlink() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ответы поддержки перестанут приходить в Telegram. Подключить снова можно в любой момент.")
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 16) {
            if connected {
                Button("Отключить") { confirmOff = true }
                    .ymFont(14.5, weight: .semibold)
                    .foregroundStyle(YMColor.statusCancel)
                    .disabled(busy)
            } else {
                Button(busy ? "Подождите…" : "Подключить") { link() }
                    .ymFont(14.5, weight: .semibold)
                    .foregroundStyle(YMColor.accent)
                    .disabled(busy)
                if waiting {
                    Button("Проверить") { Task { await reload() } }
                        .ymFont(14.5, weight: .semibold)
                        .foregroundStyle(YMColor.accent)
                        .disabled(busy)
                }
            }
        }
    }

    private func reload() async {
        if let r: TelegramStatusDTO = try? await API.shared.get("api/v1/profile/telegram", fresh: true) {
            enabled = r.enabled ?? false
            connected = r.connected ?? false
        }
    }

    private func link() {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            do {
                let r: TelegramLinkDTO = try await API.shared.post("api/v1/profile/telegram/link")
                if NotifyTelegramLogic.isOpenable(r.url),
                   let u = URL(string: (r.url ?? "").trimmingCharacters(in: .whitespaces)) {
                    waiting = true
                    UIApplication.shared.open(u)
                } else {
                    error = "Не удалось получить ссылку на бота"
                }
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func unlink() {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            do {
                try await API.shared.deleteVoid("api/v1/profile/telegram/link")
                connected = false; waiting = false
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
