//
//  NotifyTelegramSection.swift — Настройки → «Уведомления по типам» и «Telegram».
//  Паритет Android (NotifyTelegramSections.kt). Только для вошедшего.
//   • GET/POST api/v1/profile/notify-settings (сейчас один ключ new_shops);
//   • GET api/v1/profile/telegram, POST/DELETE api/v1/profile/telegram/link.
//  Системное разрешение iOS на уведомления остаётся в SettingsView.
//

import SwiftUI
import UIKit

struct NotifySettingsDTO: Decodable {
    @LenientBool var newShops: Bool?
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
    @State private var newShops: Bool?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Group {
            if let on = newShops {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Уведомления по типам").ymFont(13, weight: .heavy).foregroundStyle(YMColor.text)
                    Toggle("Новые заведения в моём городе", isOn: Binding(
                        get: { on },
                        set: { save($0) }
                    ))
                    .disabled(saving)
                    Text("Статусы заказов и сообщения заведений отключаются в настройках уведомлений iPhone.")
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
            newShops = r.newShops
        }
    }

    private func save(_ next: Bool) {
        guard !saving else { return }
        let prev = newShops
        newShops = next          // сразу
        saving = true; error = nil
        Task { @MainActor in
            do {
                let r: NotifySettingsDTO = try await API.shared.post(
                    "api/v1/profile/notify-settings", body: ["new_shops": next ? 1 : 0])
                if let v = r.newShops { newShops = v }
            } catch {
                newShops = prev  // откат
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
