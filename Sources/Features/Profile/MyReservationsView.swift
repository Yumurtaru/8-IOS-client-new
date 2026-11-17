import SwiftUI

//
//  MyReservationsView.swift — «Мои брони столиков» (П-83.15). Профиль → «Мои брони столиков».
//  GET api/v1/profile/reservations?page&per_page (по 20; будущие — ближайшие первыми, затем прошедшие),
//  «Показать ещё» по meta.has_more, «Отменить бронь» при can_cancel
//  (POST api/v1/profile/reservations/{id}/cancel). Только брони, сделанные из аккаунта.
//  Паритет с Android: ui/screens/profile/MyReservationsScreen.kt.
//

// MARK: - Модели (декодер convertFromSnakeCase; числа и флаги — толерантно)

struct MyReservationShop: Decodable {
    @LenientInt var id: Int?
    let name: String?
    let slug: String?
}

struct MyReservation: Decodable {
    @LenientInt var id: Int?
    var shop: MyReservationShop?
    var date: String?
    var time: String?
    @LenientInt var guests: Int?
    var status: String?
    var statusTitle: String?
    var table: String?
    var zone: String?
    var comment: String?
    @LenientBool var canCancel: Bool?

    var rowId: Int { id ?? 0 }
}

/// POST …/cancel → {id, status:"cancelled", status_title}.
struct MyReservationCancelResp: Decodable {
    @LenientInt var id: Int?
    let status: String?
    let statusTitle: String?
}

// MARK: - Чистая логика

enum MyReservationsLogic {
    private static let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                                 "июля", "августа", "сентября", "октября", "ноября", "декабря"]

    /// Без id показать и отменить нечего.
    static func valid(_ list: [MyReservation]) -> [MyReservation] { list.filter { $0.rowId > 0 } }

    /// Слияние страниц: новые в конец, дубли по id отбрасываются, порядок сервера сохраняется.
    static func merge(_ current: [MyReservation], _ incoming: [MyReservation]) -> [MyReservation] {
        var seen = Set<Int>()
        var out: [MyReservation] = []
        for x in current + incoming where seen.insert(x.rowId).inserted { out.append(x) }
        return out
    }

    /// "2026-11-20" + "19:30:00" → «20 ноября, 19:30». Не разобралось — как пришло.
    static func whenLabel(_ date: String?, _ time: String?) -> String {
        let d0 = (date ?? "").trimmingCharacters(in: .whitespaces)
        let t0 = (time ?? "").trimmingCharacters(in: .whitespaces)
        let p = d0.split(separator: "-").map(String.init)
        var d = d0
        if p.count == 3, let day = Int(p[2]), let mon = Int(p[1]), mon >= 1, mon <= 12 {
            d = "\(day) \(months[mon - 1])"
        }
        var t = t0
        let tp = t0.split(separator: ":").map(String.init)
        if tp.count >= 2, !tp[0].isEmpty, !tp[1].isEmpty { t = tp[0] + ":" + tp[1] }
        return [d, t].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    /// «стол 5 · Веранда»; нет обоих — nil.
    static func placeLabel(_ table: String?, _ zone: String?) -> String? {
        var parts: [String] = []
        if let t = table?.trimmingCharacters(in: .whitespaces), !t.isEmpty { parts.append("стол " + t) }
        if let z = zone?.trimmingCharacters(in: .whitespaces), !z.isEmpty { parts.append(z) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func isCancelled(_ s: String?) -> Bool { s == "cancelled" || s == "rejected" || s == "no_show" }
    static func isGood(_ s: String?) -> Bool { s == "confirmed" || s == "seated" }
}

// MARK: - Экран

struct MyReservationsView: View {
    /// Задан, когда экран показан листом поверх заведения (кнопка «Закрыть»).
    var onClose: (() -> Void)? = nil

    @State private var rows: [MyReservation]? = nil
    @State private var error: String?
    @State private var hasMore = false
    @State private var nextPage = 2
    /// Поколение выдачи: ответ «Показать ещё», запрошенный до обновления, отбрасывается.
    @State private var gen = 0
    @State private var moreBusy = false
    @State private var askCancel: MyReservation?
    @State private var cancelBusy = false
    @State private var toast: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                content
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои брони столиков")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                if let onClose { Button("Закрыть") { onClose() } }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Отменить бронь?",
                            isPresented: Binding(get: { askCancel != nil }, set: { if !$0 { askCancel = nil } }),
                            titleVisibility: .visible) {
            Button("Отменить бронь", role: .destructive) {
                if let r = askCancel { Task { await cancel(r) } }
            }
            Button("Не отменять", role: .cancel) {}
        } message: {
            if let r = askCancel {
                Text([r.shop?.name ?? "", MyReservationsLogic.whenLabel(r.date, r.time)]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !Session.shared.isLoggedIn {
            Text("Войдите, чтобы увидеть свои брони").font(YMFont.body).foregroundStyle(YMColor.muted)
        } else if let list = rows {
            if let t = toast {
                Text(t).font(YMFont.callout).foregroundStyle(YMColor.muted)
            }
            if list.isEmpty {
                Text("У вас пока нет броней").font(YMFont.body).foregroundStyle(YMColor.muted)
                    .padding(.top, YMSpace.lg)
            } else {
                ForEach(list, id: \.rowId) { r in card(r) }
                if hasMore {
                    Button { Task { await loadMore() } } label: { Text(moreBusy ? "Загружаем…" : "Показать ещё") }
                        .buttonStyle(YMSecondaryButtonStyle())
                        .disabled(moreBusy)
                }
            }
        } else if let e = error {
            ErrorRetryView(message: e) { Task { await load() } }
        } else {
            Text("Загружаем брони…").font(YMFont.body).foregroundStyle(YMColor.muted)
        }
    }

    private func statusColor(_ s: String?) -> Color {
        if MyReservationsLogic.isCancelled(s) { return YMColor.statusCancel }
        if MyReservationsLogic.isGood(s) { return YMColor.statusDone }
        return YMColor.accent
    }

    @ViewBuilder private func card(_ r: MyReservation) -> some View {
        let title = (r.statusTitle ?? "").isEmpty ? (r.status ?? "") : (r.statusTitle ?? "")
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    shopTitle(r)
                    Text(MyReservationsLogic.whenLabel(r.date, r.time))
                        .font(YMFont.body).foregroundStyle(YMColor.text)
                }
                Spacer(minLength: 0)
                if !title.isEmpty {
                    Text(title)
                        .ymFont(10.5, weight: .bold)
                        .foregroundStyle(statusColor(r.status))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(statusColor(r.status).opacity(0.16), in: Capsule())
                }
            }
            details(r)
            if r.canCancel == true {
                Button { Haptics.light(); askCancel = r } label: { Text("Отменить бронь") }
                    .buttonStyle(YMSecondaryButtonStyle())
                    .disabled(cancelBusy)
                    .padding(.top, 4)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ymCard(radius: 20)
    }

    @ViewBuilder private func shopTitle(_ r: MyReservation) -> some View {
        let name = (r.shop?.name ?? "").isEmpty ? "Заведение" : (r.shop?.name ?? "")
        let slug = r.shop?.slug ?? ""
        if slug.isEmpty {
            Text(name).ymFont(17, weight: .semibold).foregroundStyle(YMColor.text).lineLimit(2)
        } else {
            NavigationLink(destination: OrgView(shopSlug: slug)) {
                Text(name).ymFont(17, weight: .semibold).foregroundStyle(YMColor.text).lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func details(_ r: MyReservation) -> some View {
        let bits = bitsLine(r)
        if !bits.isEmpty {
            Text(bits).font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        if let c = r.comment?.trimmingCharacters(in: .whitespaces), !c.isEmpty {
            Text("Комментарий: " + c).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(3)
        }
    }

    private func bitsLine(_ r: MyReservation) -> String {
        var bits: [String] = []
        if let g = r.guests, g > 0 { bits.append("гостей: \(g)") }
        if let p = MyReservationsLogic.placeLabel(r.table, r.zone) { bits.append(p) }
        return bits.joined(separator: " · ")
    }

    // MARK: Загрузка

    private func load() async {
        guard Session.shared.isLoggedIn else { return }
        gen += 1
        let my = gen
        moreBusy = false
        do {
            let p: Page<MyReservation> = try await API.shared.page(
                "api/v1/profile/reservations", query: ["page": "1", "per_page": "20"])
            if my != gen || Task.isCancelled { return }
            rows = MyReservationsLogic.merge([], MyReservationsLogic.valid(p.items))
            hasMore = p.hasMore
            nextPage = 2
            error = nil
        } catch {
            if my != gen || Task.isCancelled { return }
            if rows == nil { self.error = error.userMessage ?? "Не удалось загрузить брони" }
            else { toast = error.userMessage ?? "Не удалось обновить брони" }
        }
    }

    private func loadMore() async {
        if moreBusy || !hasMore { return }
        moreBusy = true
        let my = gen
        let page = nextPage
        do {
            let p: Page<MyReservation> = try await API.shared.page(
                "api/v1/profile/reservations", query: ["page": "\(page)", "per_page": "20"])
            if my != gen { return }
            rows = MyReservationsLogic.merge(rows ?? [], MyReservationsLogic.valid(p.items))
            hasMore = p.hasMore && !p.items.isEmpty
            nextPage = page + 1
        } catch {
            if my == gen { toast = error.userMessage ?? "Не удалось загрузить ещё" }
        }
        if my == gen { moreBusy = false }
    }

    private func cancel(_ r: MyReservation) async {
        if cancelBusy { return }
        cancelBusy = true
        defer { cancelBusy = false; askCancel = nil }
        do {
            let resp: MyReservationCancelResp = try await API.shared.post("api/v1/profile/reservations/\(r.rowId)/cancel")
            let title = (resp.statusTitle ?? "").trimmingCharacters(in: .whitespaces)
            rows = rows?.map { x in
                guard x.rowId == r.rowId else { return x }
                var y = x
                y.status = "cancelled"
                y.statusTitle = title.isEmpty ? "Отменена" : title
                y.canCancel = false
                return y
            }
            toast = "Бронь отменена"
            Haptics.success()
        } catch {
            toast = error.userMessage ?? "Не удалось отменить бронь"
            // 409: бронь уже нельзя отменить (заведение подтвердило/посадило гостей) — список устарел, перечитываем.
            if (error as? APIError)?.rejectStatus == 409 { Task { await load() } }
        }
    }
}
