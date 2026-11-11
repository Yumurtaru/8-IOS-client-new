//
//  PasskeysSection.swift — Настройки → «Ключи доступа»: список, создание, удаление.
//  Паритет Android (PasskeysSection.kt). Показывается только вошедшему пользователю.
//

import SwiftUI

struct PasskeysSection: View {
    @EnvironmentObject private var session: Session
    @State private var items: [PasskeyItem] = []
    @State private var busy = false
    @State private var error: String?
    @State private var toDelete: PasskeyItem?

    var body: some View {
        if session.isLoggedIn {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ключи доступа").ymFont(13, weight: .heavy).foregroundStyle(YMColor.text)
                if items.isEmpty {
                    Text("Входите по Face ID / отпечатку без СМС")
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }
                ForEach(items) { k in
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(k.name.isEmpty ? "Ключ доступа" : k.name)
                                .font(YMFont.body)
                                .foregroundStyle(YMColor.text)
                            Text("Создан \(Passkeys.humanDate(k.createdAt))")
                                .font(YMFont.caption)
                                .foregroundStyle(YMColor.muted)
                            if let last = k.lastUsedAt, !last.isEmpty {
                                Text("Последний вход \(Passkeys.humanDate(last))")
                                    .font(YMFont.caption)
                                    .foregroundStyle(YMColor.muted)
                            }
                        }
                        Spacer()
                        Button {
                            toDelete = k
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(YMColor.statusCancel)
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Удалить ключ «\(k.name)»")
                    }
                }
                if let error, !error.isEmpty {
                    Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Button {
                    create()
                } label: {
                    Label(busy ? "Подождите…" : "Создать ключ доступа", systemImage: "person.badge.key.fill")
                        .font(YMFont.subhead)
                        .foregroundStyle(YMColor.accent)
                }
                .disabled(busy)
                .accessibilityLabel("Создать ключ доступа")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            .task { await reload() }
            .alert("Удалить ключ «\(toDelete?.name ?? "")»?", isPresented: Binding(
                get: { toDelete != nil },
                set: { if !$0 { toDelete = nil } }
            )) {
                Button("Удалить", role: .destructive) {
                    if let k = toDelete { remove(k) }
                    toDelete = nil
                }
                Button("Отмена", role: .cancel) { toDelete = nil }
            } message: {
                Text("Войти с ним больше не получится")
            }
        }
    }

    private func reload() async {
        if let list = try? await Passkeys.list() { items = list }
    }

    private func create() {
        guard !busy else { return }
        busy = true; error = nil
        Task { @MainActor in
            switch await Passkeys.register(name: Passkeys.defaultName) {
            case .ok: await reload()
            case .cancelled: break
            case .fail(let m): error = m
            }
            busy = false
        }
    }

    private func remove(_ k: PasskeyItem) {
        Task { @MainActor in
            do { try await Passkeys.delete(k.id); await reload() }
            catch { self.error = error.localizedDescription }
        }
    }
}
