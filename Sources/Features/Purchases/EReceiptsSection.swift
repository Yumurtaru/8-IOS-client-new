import SwiftUI

//
//  EReceiptsSection.swift — Настройки → «Электронные чеки вместо бумажных» (П-84).
//  GET api/v1/profile → e_receipts, e_receipt_contact; PUT api/v1/profile {e_receipts: Bool}.
//  422 «Подтвердите почту…» — показываем текст сервера и откатываем переключатель.
//

struct EReceiptsSection: View {
    @EnvironmentObject private var session: Session

    @State private var isOn = false
    @State private var contact: String?
    @State private var loaded = false
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        if session.isLoggedIn {
            VStack(alignment: .leading, spacing: 10) {
                Text("Чеки").ymFont(13, weight: .heavy).foregroundStyle(YMColor.text)
                Toggle("Электронные чеки вместо бумажных",
                       isOn: Binding(get: { isOn }, set: { v in change(v) }))
                    .disabled(busy || !loaded)
                Text(subtitle).font(YMFont.caption).foregroundStyle(YMColor.muted)
                if let m = message {
                    Text(m).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Text("Бумажный чек можно попросить на кассе всегда")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            .task { await load() }
        }
    }

    private var subtitle: String {
        if let c = contact, !c.isEmpty { return "Чеки будут приходить на \(c)" }
        return "Чтобы получать чеки на почту, укажите и подтвердите её в профиле"
    }

    private func load() async {
        guard let p: Profile = try? await API.shared.get("api/v1/profile") else { return }
        isOn = p.eReceipts ?? false
        contact = p.eReceiptContact
        loaded = true
    }

    private func change(_ value: Bool) {
        guard !busy else { return }
        Task { await save(value) }
    }

    private func save(_ value: Bool) async {
        let before = isOn
        busy = true
        message = nil
        isOn = value
        defer { busy = false }
        do {
            try await API.shared.putVoid("api/v1/profile", body: EReceiptsBody(eReceipts: value))
            Haptics.success()
        } catch {
            // Откат: сервер не принял (например, почта не подтверждена).
            isOn = before
            Haptics.warning()
            message = error.userMessage ?? "Не удалось сохранить. Попробуйте ещё раз"
        }
    }
}
