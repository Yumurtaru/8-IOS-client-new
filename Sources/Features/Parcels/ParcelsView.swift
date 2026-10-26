import SwiftUI
import MapKit

// «Мои посылки» и карточка посылки (волна А79 + А80).
//   GET  /api/v1/parcels?status=active|closed|all&page=  — список, meta.total
//   GET  /api/v1/parcels/{id}                             — карточка
//   POST /api/v1/parcels/{id}/cancel {reason?} | unassign | fee {fee?} | rate {rating, comment?}
//   POST /api/v1/parcels/{id}/complaint {reason, comment?} — А81, ParcelComplaintSheet
// Посылка в пути — опрос раз в 15 с, пока экран виден и приложение активно;
// push pool_parcel перечитывает сразу.

/// Переходы раздела внутри стека профиля.
enum ParcelRoute: Hashable {
    case send(ParcelDraft?)
    case list(canSend: Bool)
    case detail(Int)
}

/// Экран по маршруту. open — следующий экран поверх, replace — вместо текущего
/// (после вызова курьера форма сменяется карточкой посылки).
struct ParcelRouteView: View {
    let route: ParcelRoute
    let open: (ParcelRoute) -> Void
    let replace: (ParcelRoute) -> Void

    var body: some View {
        switch route {
        case .send(let draft):
            ParcelFormView(draft: draft) { id in replace(.detail(id)) }
        case .list(let canSend):
            ParcelsListView(canSend: canSend, open: open)
        case .detail(let id):
            ParcelDetailView(id: id, open: open)
        }
    }
}

/// Какая карточка посылки сейчас на экране: push по ней же не открывает
/// вторую такую же, а только перечитывает открытую.
enum ParcelLive {
    static var cardId: Int?
}

/// Цвет статуса посылки.
private func parcelStatusColor(_ s: String) -> Color {
    switch s {
    case "searching": return YMColor.statusPending
    case "accepted", "picked": return YMColor.accent
    case "delivered": return YMColor.statusDone
    default: return YMColor.statusCancel
    }
}

private let parcelStatusFallback: [String: String] = [
    "searching": "Ищем курьера", "accepted": "Курьер едет за посылкой", "picked": "Курьер везёт посылку",
    "delivered": "Доставлено", "failed": "Не доставлено — курьер вернёт посылку", "cancelled": "Отменено",
    "expired": "Никто не взял",
]
private func parcelStatusText(_ p: Parcel) -> String {
    !p.statusLabel.isEmpty ? p.statusLabel : (parcelStatusFallback[p.status] ?? p.status)
}

// MARK: - Мои посылки

struct ParcelsListView: View {
    let canSend: Bool
    let open: (ParcelRoute) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var filter = "all"
    @State private var items: [Parcel] = []
    @State private var total = 0
    @State private var page = 1
    @State private var loading = true
    @State private var loadingMore = false
    @State private var loadError: String?
    /// Счётчик загрузок — следующий тик опроса планируется после каждой.
    @State private var loads = 0
    @State private var loadedFilter: String?

    private var hasLive: Bool { items.contains { $0.isLive } }

    var body: some View {
        ScrollView {
            VStack(spacing: YMSpace.md) {
                YMSegmented(options: ["all", "active", "closed"], selection: $filter,
                            title: { $0 == "all" ? "Все" : ($0 == "active" ? "В пути" : "Завершённые") })
                if loading && items.isEmpty {
                    ProgressView().padding(.top, 40)
                } else if let e = loadError, items.isEmpty {
                    ErrorRetryView(message: e) { Task { await load(silent: false, fresh: true) } }.padding(.top, 20)
                } else if items.isEmpty {
                    VStack(spacing: YMSpace.md) {
                        Text("📦").font(.system(size: 44))
                        Text(filter == "active" ? "Посылок в пути нет." : "Посылок пока не было.")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        if canSend {
                            Button("Отправить посылку") { open(.send(nil)) }
                                .buttonStyle(YMPrimaryButtonStyle())
                                .padding(.horizontal, YMSpace.xxxl)
                        }
                    }
                    .padding(.top, 40)
                } else {
                    ForEach(items) { p in
                        Button { Haptics.light(); open(.detail(p.id)) } label: { row(p) }
                            .buttonStyle(.plain)
                    }
                    if items.count < total {
                        Button { Task { await more() } } label: {
                            HStack(spacing: 8) {
                                if loadingMore { ProgressView() }
                                Text("Показать ещё").font(YMFont.subhead).foregroundStyle(YMColor.accent)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .disabled(loadingMore)
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.vertical, YMSpace.lg)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои посылки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canSend {
                ToolbarItem(placement: .primaryAction) {
                    Button { open(.send(nil)) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Отправить посылку")
                }
            }
        }
        .refreshable { await load(silent: true, fresh: true) }
        .task(id: filter) {
            // Смена вкладки — с чистого листа; возврат из карточки — тихо, без мигания.
            if loadedFilter != filter { items = []; total = 0; page = 1; loadError = nil }
            loadedFilter = filter
            await load(silent: !items.isEmpty)
        }
        // Опрос раз в 15 с: только пока есть посылка в пути, экран виден (task
        // снимается при уходе с экрана) и приложение активно.
        .task(id: "\(loads)|\(scenePhase == .active)|\(hasLive)") {
            guard scenePhase == .active, hasLive else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            await load(silent: true)
        }
        .onChange(of: scenePhase) { ph in
            if ph == .active, !items.isEmpty { Task { await load(silent: true) } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ymParcelPushed)) { _ in
            Task { await load(silent: true) }
        }
    }

    private func row(_ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Посылка №\(p.id)").font(YMFont.headline).foregroundStyle(YMColor.text)
                Spacer(minLength: 8)
                ParcelBadge(text: parcelStatusText(p), color: parcelStatusColor(p.status))
            }
            Text(p.pickupAddress + " → " + p.dropAddress)
                .font(YMFont.callout).foregroundStyle(YMColor.text).lineLimit(2)
            Text(rowMeta(p)).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(2)
            if let c = p.cargoLine { Text(c).font(YMFont.caption).foregroundStyle(YMColor.text) }
            // А101: вызов «на потом» — до конца поиска больше часа: «Ищем курьера до 15:30».
            // Часы раз в 30 с: строка гаснет, когда остался час, даже если ответ опроса тот же.
            if p.status == "searching", p.target == nil, ParcelFmt.searchUntil(p.expiresAt) != nil {
                TimelineView(.periodic(from: .now, by: 30)) { tl in
                    if let u = ParcelFmt.searchUntil(p.expiresAt, now: tl.date) {
                        Text(u).font(YMFont.caption).foregroundStyle(YMColor.text)
                    }
                }
            }
            if let cp = p.complaint { Text(cp.line).font(YMFont.caption).foregroundStyle(YMColor.muted) }
        }
        .padding(YMSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ymCard(radius: 18)
    }

    private func rowMeta(_ p: Parcel) -> String {
        var parts: [String] = []
        if !p.description.isEmpty { parts.append(p.description) }
        if let f = p.fee { parts.append(ParcelFmt.rub(f)) }
        let t = ParcelFmt.time(p.createdAt)
        if !t.isEmpty { parts.append(t) }
        return parts.joined(separator: " · ")
    }

    /// silent — без крутилки; перечитываем все уже показанные страницы.
    /// Только первая страница. silent — без крутилки; если догружены ещё
    /// страницы, первую вливаем по id (догруженное не теряем и не перекачиваем).
    /// fresh — заново с первой страницы (потянули вниз, сменили вкладку).
    @MainActor private func load(silent: Bool, fresh: Bool = false) async {
        if !silent { loading = true }
        defer { loading = false; loads &+= 1 }
        let f = filter
        do {
            let pg = try await ParcelAPI.list(status: f, page: 1)
            guard f == filter else { return }
            let tot = pg.meta?.total ?? pg.items.count
            if fresh || page <= 1 || items.isEmpty {
                var first: [Parcel] = []
                for p in pg.items where !first.contains(where: { $0.id == p.id }) { first.append(p) }
                items = first; page = 1
                total = max(tot, first.count)
            } else {
                var merged = items
                var fresh1: [Parcel] = []
                for p in pg.items {
                    if let i = merged.firstIndex(where: { $0.id == p.id }) { merged[i] = p }
                    else if !fresh1.contains(where: { $0.id == p.id }) { fresh1.append(p) }
                }
                items = fresh1 + merged
                total = max(tot, items.count)
            }
            loadError = nil
        } catch is CancellationError {
        } catch {
            if !silent || items.isEmpty { loadError = error.userMessage }
        }
    }

    @MainActor private func more() async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let f = filter
        do {
            let pg = try await ParcelAPI.list(status: f, page: page + 1)
            guard f == filter else { return }
            page += 1
            for p in pg.items where !items.contains(where: { $0.id == p.id }) { items.append(p) }
            if let t = pg.meta?.total { total = t }
            if pg.items.isEmpty { total = items.count }
        } catch {}
    }
}

// MARK: - Карточка посылки

private struct ParcelPin: Identifiable {
    let id = 0
    let coordinate: CLLocationCoordinate2D
}

struct ParcelDetailView: View {
    let id: Int
    let open: (ParcelRoute) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var p: Parcel?
    @State private var loadError: String?
    @State private var busy = false
    @State private var message: String?
    @State private var loads = 0
    @State private var region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 55.75, longitude: 37.62),
                                                   span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))
    // Диалоги действий
    @State private var askCancel = false
    @State private var askUnassign = false
    @State private var askFee = false
    @State private var askRetry = false
    @State private var feeText = ""
    @State private var showRate = false
    @State private var showComplaint = false

    var body: some View {
        ScrollView {
            if let p {
                card(p)
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.vertical, YMSpace.lg)
            } else if let e = loadError {
                ErrorRetryView(message: e) { Task { await load() } }.padding(.top, 60)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Посылка №\(id)")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        // Опрос раз в 15 с, пока посылка в пути, экран виден и приложение активно.
        .task(id: "\(loads)|\(scenePhase == .active)|\(p?.isLive == true)") {
            guard scenePhase == .active, p?.isLive == true else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { return }
            await load()
        }
        .onChange(of: scenePhase) { ph in
            if ph == .active, p != nil { Task { await load() } }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ymParcelPushed)) { n in
            guard (n.object as? Int) == id else { return }
            Task { await load() }
        }
        .onAppear { ParcelLive.cardId = id }
        .onDisappear { if ParcelLive.cardId == id { ParcelLive.cardId = nil } }
        .onChange(of: p?.courier?.lat) { _ in recenter() }
        .onChange(of: p?.courier?.lng) { _ in recenter() }
        .confirmationDialog("Отменить вызов курьера?", isPresented: $askCancel, titleVisibility: .visible) {
            Button("Отменить вызов", role: .destructive) { act("cancel") }
            Button("Не отменять", role: .cancel) {}
        }
        .confirmationDialog("Снять курьера и искать другого?", isPresented: $askUnassign, titleVisibility: .visible) {
            Button("Курьер не едет — искать другого", role: .destructive) { act("unassign") }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Поднять цену", isPresented: $askFee) {
            TextField("Цена, ₽", text: $feeText).keyboardType(.decimalPad)
            Button("Отмена", role: .cancel) {}
            Button("Сохранить") { act("fee", fee: feeText, required: true) }
        } message: {
            Text("Новая цена доставки. Чем выше — тем быстрее возьмут.")
        }
        .alert("Повторить поиск", isPresented: $askRetry) {
            TextField("Цена, ₽", text: $feeText).keyboardType(.decimalPad)
            Button("Отмена", role: .cancel) {}
            Button("Искать снова") { act("fee", fee: feeText, required: false) }
        } message: {
            Text("Можно оставить прежнюю цену или предложить больше.")
        }
        .sheet(isPresented: $showRate) {
            ParcelRateSheet { rating, comment in
                var b: [String: Any] = ["rating": rating]
                if !comment.isEmpty { b["comment"] = comment }
                act("rate", body: b)
            }
        }
        // А81: «Пожаловаться» на курьера.
        .sheet(isPresented: $showComplaint) {
            ParcelComplaintSheet(parcelId: id, onSent: { fresh in
                p = fresh
                message = "Жалоба отправлена администратору"
                // Список «Мои посылки» и эта карточка перечитываются (строка «Жалоба: …»).
                NotificationCenter.default.post(name: .ymParcelPushed, object: id)
            }, onExists: { text in
                message = text
                Task { await load() }
            }, onStale: {
                Task { await load() }
            })
        }
        .errorToast($message)
    }

    // MARK: Карточка

    @ViewBuilder
    private func card(_ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.lg) {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                HStack(alignment: .firstTextBaseline) {
                    Text(parcelStatusText(p)).font(YMFont.title3).foregroundStyle(parcelStatusColor(p.status))
                    Spacer(minLength: 6)
                    if busy { ProgressView() }
                }
                if p.status == "searching" {
                    // А101: вызов «на потом» — до конца поиска больше часа: «Ищем курьера до 15:30»
                    // (не сегодня — «до 24.10 09:15»). Час и меньше, выбранный водитель — как раньше.
                    // Часы раз в 30 с: строка сменится, даже если ответ опроса тот же.
                    TimelineView(.periodic(from: .now, by: 30)) { tl in
                        let until = p.target == nil ? ParcelFmt.searchUntil(p.expiresAt, now: tl.date) : nil
                        VStack(alignment: .leading, spacing: YMSpace.sm) {
                            if let until {
                                Text(until).font(YMFont.callout.weight(.semibold)).foregroundStyle(YMColor.text)
                            }
                            Text(searchLine(p, until: until != nil)).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        }
                    }
                }
                if let t = p.target, p.status == "searching" {
                    Text("Ждём ответа водителя: \(t.name)" + (t.vehicleLabel.isEmpty ? "" : " · " + t.vehicleLabel))
                        .font(YMFont.callout).foregroundStyle(YMColor.text)
                }
                if p.can.chooseDriver {
                    Text("Водитель не подтвердил — отправьте посылку заново и выберите другого.")
                        .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                }
                if let r = p.failReason, !r.isEmpty {
                    Text(r).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                }
                if p.status == "cancelled", let r = p.cancelReason, !r.isEmpty {
                    Text(r).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            .padding(YMSpace.lg).frame(maxWidth: .infinity, alignment: .leading).ymCard(radius: 18)

            if let c = p.courier { courierBlock(c, p) }

            VStack(alignment: .leading, spacing: YMSpace.md) {
                info("Откуда", p.pickupAddress, sub: [p.pickupName, p.pickupPhone].filter { !$0.isEmpty }.joined(separator: " · "))
                info("Куда", p.dropAddress, sub: [p.recipientName, p.recipientPhone].filter { !$0.isEmpty }.joined(separator: " · "))
                info("Что везём", p.description, sub: p.sizeLabel)
                if let c = p.cargoLine { info("Машина", c, sub: "") }
                info("Цена доставки", ParcelFmt.rub(p.fee),
                     sub: p.feeBy == "recipient" ? "Платит получатель при вручении" : "Платит отправитель, когда курьер заберёт")
                if let at = p.pickupAt, !ParcelFmt.time(at).isEmpty { info("Забрать", ParcelFmt.time(at), sub: "") }
                if !p.comment.isEmpty { info("Комментарий", p.comment, sub: "") }
                if let r = p.rating, r > 0 {
                    info("Ваша оценка", String(repeating: "★", count: min(r, 5)), sub: "")
                }
                if let cp = p.complaint {
                    Text(cp.line).font(YMFont.callout).foregroundStyle(YMColor.muted)
                }
            }
            .padding(YMSpace.lg).frame(maxWidth: .infinity, alignment: .leading).ymCard(radius: 18)

            actions(p)
        }
    }

    /// until — над строкой уже «Ищем курьера до …» (А101): «ждём до» не повторяем.
    private func searchLine(_ p: Parcel, until: Bool) -> String {
        var s = "Предложено курьерам: \(p.offeredTo ?? 0)"
        let t = ParcelFmt.time(p.expiresAt)
        if !t.isEmpty, !until { s += " · ждём до " + t }
        return s
    }

    private func info(_ title: String, _ value: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(YMFont.caption).foregroundStyle(YMColor.muted)
            Text(value.isEmpty ? "—" : value).font(YMFont.body).foregroundStyle(YMColor.text)
            if !sub.isEmpty { Text(sub).font(YMFont.caption).foregroundStyle(YMColor.muted) }
        }
    }

    private func courierBlock(_ c: ParcelCourier, _ p: Parcel) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            if let lat = c.lat, let lng = c.lng, p.isLive {
                Map(coordinateRegion: $region,
                    annotationItems: [ParcelPin(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lng))]) { pin in
                    MapAnnotation(coordinate: pin.coordinate) { CourierPin() }
                }
                .allowsHitTesting(false)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .onAppear { recenter() }
            }
            HStack(spacing: YMSpace.md) {
                LogoBadge(url: nil, letter: c.name.prefix(1).uppercased(), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Курьер · " + c.name).font(YMFont.headline).foregroundStyle(YMColor.text)
                    if !c.car.isEmpty { Text(c.car).font(YMFont.caption).foregroundStyle(YMColor.muted) }
                    if let eta = c.etaMinutes, eta > 0, p.isLive {
                        Text("≈ \(eta) мин " + (p.status == "picked" ? "до получателя" : "до вас"))
                            .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                    }
                }
                Spacer(minLength: 6)
                if !c.phone.isEmpty {
                    Button {
                        Haptics.light()
                        if let u = URL(string: "tel://" + c.phone.filter { $0.isNumber || $0 == "+" }) { openURL(u) }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(YMColor.onAccent)
                            .frame(width: 44, height: 44)
                            .background(YMColor.accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Позвонить курьеру")
                }
            }
            if let lat = c.lat, let lng = c.lng, p.isLive {
                Button { openMaps(lat, lng) } label: {
                    Label("Где курьер — открыть в Картах", systemImage: "map")
                        .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(YMSpace.lg).frame(maxWidth: .infinity, alignment: .leading).ymCard(radius: 18)
    }

    @ViewBuilder
    private func actions(_ p: Parcel) -> some View {
        let a = p.can
        VStack(spacing: YMSpace.sm) {
            if a.chooseDriver {
                Button("Выбрать другого водителя") { open(.send(ParcelDraft(from: p, cityId: 0))) }
                    .buttonStyle(YMPrimaryButtonStyle())
            }
            if a.retry {
                Button("Повторить поиск") { feeText = ""; askRetry = true }
                    .buttonStyle(YMPrimaryButtonStyle())
            }
            if a.changeFee {
                secondary("Поднять цену") { feeText = p.fee.map { NSDecimalNumber(decimal: ParcelFmt.whole($0)).stringValue } ?? ""; askFee = true }
            }
            if a.unassign { secondary("Курьер не едет") { askUnassign = true } }
            if a.rate && p.rating == nil { secondary("Оценить курьера") { showRate = true } }
            // А81: только когда сервер разрешил (can.complain).
            if a.complain {
                Button { showComplaint = true } label: {
                    Label("Пожаловаться", systemImage: "exclamationmark.bubble")
                        .font(YMFont.subhead).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if a.cancel {
                Button { askCancel = true } label: {
                    Text("Отменить вызов").font(YMFont.subhead).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(busy)
    }

    private func secondary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(YMFont.headline).foregroundStyle(YMColor.accent)
                .frame(maxWidth: .infinity, minHeight: 48)
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Данные и действия

    @MainActor private func load() async {
        defer { loads &+= 1 }
        do {
            let r = try await ParcelAPI.get(id)
            p = r; loadError = nil
        } catch is CancellationError {
        } catch {
            if p == nil { loadError = error.userMessage }
        }
    }

    private func act(_ name: String, fee: String? = nil, required: Bool = false, body: [String: Any] = [:]) {
        guard !busy else { return }
        var b = body
        if let fee {
            let f = fee.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
            if f.isEmpty && required { message = "Укажите новую цену"; return }
            if !f.isEmpty { b["fee"] = f }
        }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                let r = try await ParcelAPI.action(id, name, b)
                p = r
                Haptics.success()
                message = "Готово"
            } catch {
                Haptics.error()
                if let f = error as? ParcelFailure, let field = f.fields.values.sorted().first, !f.message.contains(field) {
                    message = f.message + ": " + field
                } else {
                    message = error.userMessage
                }
                // Вызов уже изменился (409 changed / bad_status) — показываем свежий.
                await load()
            }
        }
    }

    private func recenter() {
        guard let lat = p?.courier?.lat, let lng = p?.courier?.lng else { return }
        withAnimation(.easeInOut(duration: 0.8)) {
            region.center = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
    }

    /// Точка курьера — в Картах (как «маршрут» у заказа: maps.apple.com).
    private func openMaps(_ lat: Double, _ lng: Double) {
        var c = URLComponents(string: "https://maps.apple.com/")
        c?.queryItems = [URLQueryItem(name: "ll", value: "\(lat),\(lng)"), URLQueryItem(name: "q", value: "Курьер")]
        if let u = c?.url { openURL(u) }
    }
}

// MARK: - Оценка курьера

private struct ParcelRateSheet: View {
    let onSend: (Int, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rating = 5
    @State private var comment = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: YMSpace.lg) {
                Text("Как курьер справился?").font(YMFont.title3).foregroundStyle(YMColor.text)
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { n in
                        Button { Haptics.selection(); rating = n } label: {
                            Image(systemName: n <= rating ? "star.fill" : "star")
                                .font(.system(size: 32)).foregroundStyle(YMColor.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(n) из 5")
                    }
                }
                TextField("Комментарий (необязательно)", text: $comment)
                    .padding(.horizontal, 14).frame(height: 46)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .ymMaxLength($comment, 255)
                Button("Отправить оценку") {
                    onSend(rating, comment.trimmingCharacters(in: .whitespacesAndNewlines))
                    dismiss()
                }
                .buttonStyle(YMPrimaryButtonStyle())
                Spacer()
            }
            .padding(YMSpace.xl)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Оценка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
