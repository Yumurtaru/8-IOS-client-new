//
//  ProfileDetailView.swift — Адреса / Мои записи (premium-клиент)
//
//  Макет ProfileDetailPhone (addresses | bookings). Токены, light+dark,
//  Dynamic Type, Reduce Motion.
//
//  ТОЧКИ ВХОДА (для навигации):
//    • AddressesView()   — карточки Дом/Работа/…, основной адрес (золотая рамка + бейдж),
//                          «＋ Добавить адрес» (пунктир), CRUD через реальные методы.
//    • BookingsView()    — табы Предстоящие/Прошедшие, карточки записи, действия Отменить/Маршрут.
//
//  ПРИВЯЗКА К API (как в старом AddressesView):
//    • GET    api/v1/profile/addresses          → [Address]
//    • POST   api/v1/profile/addresses          ← AddressBody (создание)
//    • DELETE api/v1/profile/addresses/{id}     (удаление)
//    • GET    api/address/suggest?q=            → [AddrSuggest] (Dadata-прокси)
//  Записи (bookings):
//    • GET  api/v1/appointments             → [Appointment] (список записей клиента)
//    • POST api/v1/orders/{orderId}/cancel  (отмена записи; сервер возвращает окно в продажу)
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - АДРЕСА
// ─────────────────────────────────────────────────────────────────────────────

struct AddressesView: View {
    @State private var items: [Address] = []
    @State private var loading = true
    @State private var showAdd = false
    /// Удаление не прошло — раньше ошибка глоталась, и адрес просто оставался.
    @State private var deleteError: String?
    /// Загрузка не прошла — это не «адресов нет».
    @State private var loadError: String?
    /// Адреса, которые уже удаляются: двойной выбор «Удалить» слал второй
    /// DELETE, тот отвечал 404, и после удачного удаления всплывала ошибка.
    @State private var deletingIds = Set<Int>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if loading {
                    ForEach(0..<3, id: \.self) { _ in SkeletonBox(radius: 18).frame(height: 78) }
                } else if let e = loadError, items.isEmpty {
                    ErrorRetryView(message: e) { Task { await load() } }
                } else if items.isEmpty {
                    emptyState
                } else {
                    // Перечитать не удалось (после добавления, возврат на экран),
                    // а список уже есть — раньше сбой был не виден, и только что
                    // добавленного адреса «не было».
                    if let e = loadError {
                        Text("Не удалось обновить: " + e)
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    }
                    ForEach(Array(items.enumerated()), id: \.element.id) { _, a in
                        // «Изменить» убран: у пункта не было экрана правки, нажатие
                        // ничего не делало. Поменять адрес — удалить и добавить.
                        AddressCard(address: a,
                                    onDelete: { Task { await remove(a) } })
                    }
                }
                addButton
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Адреса доставки")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd, onDismiss: { Task { await load() } }) { AddAddressView() }
        .task { await load() }
        .alert("Адрес не удалён", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("Понятно", role: .cancel) { deleteError = nil }
        } message: { Text(deleteError ?? "") }
    }

    /// П-25 №6: сервер хранит не больше 50 адресов — на пределе вместо кнопки
    /// объясняем, что делать (раньше форма заполнялась и падала с ошибкой).
    @ViewBuilder private var addButton: some View {
        if items.count >= 50 {
            Text("Сохранено 50 адресов — это максимум. Удалите ненужный, чтобы добавить новый.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            addButtonCore
        }
    }

    private var addButtonCore: some View {
        Button { Haptics.light(); showAdd = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                Text("Добавить адрес").font(.system(size: 14.5, weight: .heavy))
            }
            .foregroundStyle(YMColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(YMColor.hairline)
            )
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("📍").font(.system(size: 44))
            Text("Адресов пока нет").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Добавьте адрес доставки, чтобы оформлять заказы быстрее.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.vertical, 30)
    }

    private func load() async {
        loading = true; loadError = nil
        do { items = try await API.shared.list("api/v1/profile/addresses") }
        catch is CancellationError {}
        catch { loadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить адреса" }
        // Основной — первым (золотая рамка/бейдж по isDefaultBool).
        items.sort { ($0.isDefaultBool ? 0 : 1) < ($1.isDefaultBool ? 0 : 1) }
        loading = false
    }
    private func remove(_ a: Address) async {
        let aid = a.id
        guard !deletingIds.contains(aid) else { return }
        deletingIds.insert(aid)
        defer { deletingIds.remove(aid) }
        do {
            try await API.shared.deleteVoid("api/v1/profile/addresses/\(aid)")
            await MainActor.run { items.removeAll { $0.id == aid } }
        } catch {
            // 404 — адрес уже удалён (на сайте, другим устройством): убираем из
            // списка, а не показываем «Адрес не удалён».
            if (error as? APIError)?.rejectStatus == 404 {
                await MainActor.run { items.removeAll { $0.id == aid } }
                return
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось удалить адрес"
            await MainActor.run { deleteError = msg }
        }
    }
}

/// Карточка адреса: иконка по типу, название, «Основной»-бейдж, адрес, свайп-удаление.
private struct AddressCard: View {
    let address: Address
    var onEdit: (() -> Void)? = nil
    var onDelete: () -> Void = {}

    private var isMain: Bool { address.isDefaultBool }
    private var icon: String {
        let l = (address.label ?? "").lowercased()
        if l.contains("дом") { return "🏠" }
        if l.contains("работ") || l.contains("офис") { return "💼" }
        return "📍"
    }
    /// Пустое название (поле «Название» стёрли при добавлении — сервер хранит
    /// пустую строку) давало карточку без заголовка: подставляем «Адрес».
    private var title: String {
        let l = (address.label ?? "").trimmingCharacters(in: .whitespaces)
        return l.isEmpty ? "Адрес" : l
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Text(icon)
                .font(.system(size: 18))
                .frame(width: 40, height: 40)
                .background(isMain ? YMColor.accent.opacity(0.14) : YMColor.surface2,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    if isMain {
                        Text("Основной")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(YMColor.accent)
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                }
                Text(address.display.isEmpty ? "—" : address.display)
                    .font(.system(size: 13))
                    .foregroundStyle(YMColor.muted)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Menu {
                if let onEdit {
                    Button { onEdit() } label: { Label("Изменить", systemImage: "pencil") }
                }
                Button(role: .destructive) { onDelete() } label: { Label("Удалить", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                    .frame(width: 30, height: 30)
            }
        }
        .padding(15)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isMain ? YMColor.accent : YMColor.hairline, lineWidth: isMain ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)\(isMain ? ", основной" : ""), \(address.display)")
    }
}

/// Тело создания адреса (POST api/v1/profile/addresses). camelCase → snake_case автоматически.
private struct AddressBody: Encodable {
    let label: String
    let city: String?
    let street: String
    let house: String?
    let apartment: String?
    let entrance: String?
    let floor: String?
    let intercom: String?
    let lat: Double?
    let lng: Double?
}

/// Добавление адреса: живые подсказки Dadata (api/address/suggest), валидация координат.
private struct AddAddressView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var label = "Дом"
    @State private var street = ""
    @State private var house = ""
    @State private var apartment = ""
    @State private var entrance = ""
    @State private var floor = ""
    @State private var intercom = ""
    @State private var lat: Double?
    @State private var lng: Double?
    /// Адрес выбран из подсказки (даже если у неё нет координат).
    @State private var picked = false
    @State private var suggestions: [AddrSuggest] = []
    @State private var suggestTask: Task<Void, Never>?
    @State private var suppress = false
    @State private var saving = false
    @State private var error: String?

    private var cityName: String { Session.shared.cityName ?? "" }

    var body: some View {
        NavigationStack {
            Form {
                // П-25 №6: пределы полей адреса — как хранит сервер (лишнее он режет молча).
                Section { TextField("Название (Дом, Работа…)", text: $label).ymMaxLength($label, 100) }
                Section("Адрес") {
                    if !cityName.isEmpty {
                        HStack { Text("Город"); Spacer(); Text(cityName).foregroundStyle(YMColor.muted) }
                    }
                    TextField("Улица и дом", text: $street)
                        .onChange(of: street) { v in scheduleSuggest(v) }
                        .ymMaxLength($street, 190)
                    ForEach(suggestions) { s in
                        Button { pick(s) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "mappin.circle").foregroundStyle(YMColor.muted)
                                Text(s.value ?? "").foregroundStyle(YMColor.text)
                                Spacer()
                            }
                        }
                    }
                    TextField("Дом", text: $house).ymMaxLength($house, 30)
                    TextField("Квартира (по желанию)", text: $apartment).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($apartment, 30)
                    TextField("Подъезд (по желанию)", text: $entrance).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($entrance, 20)
                    TextField("Этаж (по желанию)", text: $floor).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($floor, 20)
                    TextField("Домофон (по желанию)", text: $intercom).keyboardType(.numbersAndPunctuation)
                        .ymMaxLength($intercom, 50)
                }
                if let e = error { Text(e).foregroundStyle(YMColor.statusCancel).font(YMFont.caption) }
                Section {
                    Button(action: save) {
                        HStack { Spacer()
                            if saving { ProgressView() } else { Text("Сохранить").fontWeight(.bold) }
                            Spacer() }
                    }
                    .disabled(saving)
                }
            }
            .navigationTitle("Новый адрес")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) } }
        }
        .tint(YMColor.accent)
        // Пока адрес сохраняется, окно не закрывается: закрытое смахиванием
        // перечитывало список раньше ответа — адреса в нём не было, и его
        // добавляли второй раз (дубль), а ошибка сохранения терялась.
        .interactiveDismissDisabled(saving)
    }

    private func scheduleSuggest(_ text: String) {
        suggestTask?.cancel()
        if suppress { suppress = false; suggestions = []; return }
        // Улицу правят руками — координаты прежней подсказки больше не её.
        // Раньше адрес сохранялся с новой улицей и старой точкой: зона, цена
        // доставки и точка для курьера были от другого адреса.
        lat = nil; lng = nil; picked = false
        let q = text.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { suggestions = []; return }
        let query = cityName.isEmpty ? q : "\(cityName), \(q)"
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let res: [AddrSuggest] = (try? await API.shared.get("api/address/suggest", query: ["q": query])) ?? []
            if Task.isCancelled { return }
            await MainActor.run { suggestions = res }
        }
    }
    private func pick(_ s: AddrSuggest) {
        // Флаг «не искать» ставим, только если улица реально сменится: иначе
        // onChange не срабатывал, флаг оставался взведённым, и следующая ручная
        // правка улицы не сбрасывала координаты подсказки (адрес уходил с
        // точкой другого дома). Запоздавший ответ подсказок тоже гасим.
        suggestTask?.cancel()
        let newStreet = s.street ?? street
        suppress = newStreet != street
        street = newStreet
        if let h = s.house, !h.isEmpty { house = h }
        lat = s.lat; lng = s.lng; picked = true
        suggestions = []
    }
    private func save() {
        // Двойное нажатие до перерисовки кнопки сохраняло адрес дважды.
        guard !saving else { return }
        if street.trimmingCharacters(in: .whitespaces).isEmpty { error = "Укажите улицу и дом"; return }
        // Подсказка Dadata бывает без координат (улица, новый дом): раньше её выбор
        // всё равно отвечал «Выберите адрес из подсказок». Сервер сам находит точку
        // по тексту адреса, если координат нет (POST profile/addresses, api_v1.php).
        if !picked && (lat == nil || lng == nil) { error = "Выберите адрес из подсказок"; return }
        saving = true; error = nil
        let body = AddressBody(label: label,
                               city: cityName.isEmpty ? nil : cityName,
                               street: street,
                               house: house.isEmpty ? nil : house,
                               apartment: apartment.isEmpty ? nil : apartment,
                               entrance: entrance.isEmpty ? nil : entrance,
                               floor: floor.isEmpty ? nil : floor,
                               intercom: intercom.isEmpty ? nil : intercom,
                               lat: lat, lng: lng)
        Task {
            // Раньше ошибка (лимит 50 адресов, нет сети) глушилась, а окно
            // закрывалось так, будто адрес сохранён.
            do {
                // П-27.14: ключ повтора — повтор после обрыва связи не создаёт второй адрес.
                try await API.shared.postVoid("api/v1/profile/addresses", body: body, retryKey: true)
                await MainActor.run { Haptics.success(); dismiss() }
            } catch {
                await MainActor.run {
                    saving = false
                    self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось сохранить адрес"
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - МОИ ЗАПИСИ (bookings)
// ─────────────────────────────────────────────────────────────────────────────

/// Модель карточки записи. Маппится из Appointment (GET api/v1/appointments);
/// поля 1:1 с макетом ProfileDetail (bookings) плюс то, что нужно кнопкам:
/// orderId — для отмены, address/coords — для маршрута.
struct BookingItem: Identifiable {
    let id: Int
    let orderId: Int?
    let service: String
    let org: String
    let date: Date?
    let time: String
    let status: BookingStatus
    let address: String?
    let lat: Double?
    let lng: Double?
    /// Адрес выездной услуги — куда приедет мастер. У услуги в заведении пусто:
    /// туда, наоборот, едет клиент, и работает кнопка «Маршрут».
    let visitAddress: String?
    /// А63: комментарий мастеру, который клиент оставил при записи.
    let clientComment: String?
    /// Визит уже прошёл (сервер) / начало визита по Москве — после него сервер
    /// отмену не принимает (П-25 №4).
    let isPast: Bool
    let startsAt: Date?
    /// Отменять можно только предстоящую и ещё не начатую запись — те же статусы,
    /// что принимает сервер в POST api/v1/orders/{id}/cancel.
    var canCancel: Bool {
        guard orderId != nil, status == .confirmed || status == .pending, !isPast else { return false }
        guard let s = startsAt else { return true }
        return s > Date()
    }

    init(from a: Appointment) {
        id = a.id
        orderId = a.orderId
        service = a.service ?? "Услуга"
        org = a.shop ?? ""
        date = BookingItem.parse(a.date)
        time = String((a.timeStart ?? "").prefix(5))
        let note = (a.clientComment ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        clientComment = note.isEmpty ? nil : note
        isPast = a.isPast == true
        startsAt = BookingItem.start(a.date, a.timeStart)
        switch (a.status ?? "").lowercased() {
        case "cancelled", "canceled": status = .cancelled
        case "accepted", "confirmed": status = .confirmed
        case "new", "pending":        status = .pending
        // Запись — это заказ и проходит те же статусы. «В работе» (preparing) и
        // «Выполнена» (ready) раньше показывались как «Ожидает» с кнопкой
        // «Отменить», которую сервер отклоняет (как в Android-клиенте).
        case "preparing":             status = .inWork
        case "ready":                 status = .ready
        // Состоявшийся визит раньше подписывался «Подтверждена» и показывал
        // кнопку «Отменить» (сервер такую отмену всё равно отклоняет).
        case "done", "completed":     status = .done
        // П-25 №4: прочие коды (in_delivery — мастер выехал, незнакомые) —
        // «В работе» и без «Отменить»: сервер отменяет только new/accepted.
        default:                      status = .inWork
        }
        address = (a.shopAddress?.isEmpty == false) ? a.shopAddress : nil
        // Нулевые координаты — «координат нет» (так их отдаёт пустая колонка):
        // «Маршрут» вёл в точку 0,0 в океане. Тогда строим по адресу.
        let hasCoords = (a.shopLat ?? 0) != 0 && (a.shopLng ?? 0) != 0
        lat = hasCoords ? a.shopLat : nil
        lng = hasCoords ? a.shopLng : nil
        visitAddress = (a.address?.isEmpty == false) ? a.address : nil
    }

    /// Дата визита приходит как "2026-09-06" — разбираем фиксированной локалью,
    /// иначе на телефоне с другим календарём получится nil и плашка будет пустой.
    private static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return dayIn.date(from: s)
    }
    /// Начало визита: дата + "HH:MM" по Москве (время площадки). Не разобрали — nil.
    private static func start(_ day: String?, _ time: String?) -> Date? {
        guard let d = day, d.count >= 10, let t = time, t.count >= 5 else { return nil }
        return startIn.date(from: String(d.prefix(10)) + " " + String(t.prefix(5)))
    }
    private static let startIn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()
    /// Один форматтер на все записи: раньше новый создавался на каждую запись
    /// при каждой загрузке списка (DateFormatter дорогой).
    private static let dayIn: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
enum BookingStatus { case confirmed, pending, cancelled, done, inWork, ready
    var title: String {
        switch self {
        case .confirmed: return "Подтверждена"
        case .pending:   return "Ожидает"
        case .cancelled: return "Отменена"
        case .done:      return "Завершена"
        case .inWork:    return "В работе"
        case .ready:     return "Выполнена"
        }
    }
}

private enum BookingTab: String, CaseIterable, Hashable {
    case upcoming, past
    var title: String { self == .upcoming ? "Предстоящие" : "Прошедшие" }
}

struct BookingsView: View {
    @State private var tab: BookingTab = .upcoming
    @State private var upcoming: [BookingItem] = []
    @State private var past: [BookingItem] = []
    @State private var loading = true
    @State private var cancelError: String?
    @State private var bookingsLoadError: String?

    private var current: [BookingItem] { tab == .upcoming ? upcoming : past }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                YMSegmented(options: BookingTab.allCases, selection: $tab) { $0.title }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.bottom, YMSpace.lg)

                if loading {
                    VStack(spacing: YMSpace.lg) {
                        ForEach(0..<2, id: \.self) { _ in SkeletonBox(radius: 20).frame(height: 150) }
                    }
                    .padding(.horizontal, YMSpace.xl)
                } else if let e = bookingsLoadError, upcoming.isEmpty && past.isEmpty {
                    ErrorRetryView(message: e) { Task { await load() } }
                } else if current.isEmpty {
                    emptyState
                } else {
                    // Перечитать не удалось (после отмены, возврат на экран), а
                    // записи уже есть — раньше сбой был не виден.
                    if let e = bookingsLoadError {
                        Text("Не удалось обновить: " + e)
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .padding(.horizontal, YMSpace.xl)
                            .padding(.bottom, YMSpace.sm)
                    }
                    VStack(spacing: YMSpace.lg) {
                        ForEach(current) { b in
                            BookingCard(booking: b, onCancel: { await cancel(b) })
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                }
            }
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои записи")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(cancelError ?? "", isPresented: Binding(
            get: { cancelError != nil },
            set: { if !$0 { cancelError = nil } }
        // «Понятно», как в остальных окнах приложения, а не английское «OK».
        )) { Button("Понятно", role: .cancel) {} }
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("📅").font(.system(size: 44))
            Text(tab == .upcoming ? "Нет предстоящих записей" : "Нет прошедших записей")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Запишитесь на услугу в разделе организаций.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 40)
    }

    private func load() async {
        loading = true; bookingsLoadError = nil
        // Ошибка загрузки раньше выглядела как «Нет предстоящих записей».
        let list: [Appointment]
        // П-21.3 (А58): записи постранично — собираем все страницы (пустая = конец).
        // Ключ дубля — окно + заказ: одно окно могли отменить и занять снова.
        do { list = try await API.shared.allPages("api/v1/appointments") { (a: Appointment) in "\(a.id)-\(a.orderId ?? 0)" } }
        catch is CancellationError { loading = false; return }
        catch { bookingsLoadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить записи"; loading = false; return }
        // Делим по серверному признаку is_past: он уже учитывает и время окончания
        // визита, и статусы done/cancelled. Если поля нет (старый сервер) — запись
        // считается предстоящей, чтобы не пропасть из виду.
        upcoming = list.filter { $0.isPast != true }.map(BookingItem.init(from:))
        past     = list.filter { $0.isPast == true }.map(BookingItem.init(from:))
        loading = false
    }

    /// Отмена записи. Сервер тем же вызовом возвращает окно в продажу
    /// (POST api/v1/orders/{id}/cancel → releaseServiceSlotForOrder).
    private func cancel(_ b: BookingItem) async {
        guard let oid = b.orderId else { return }
        // «Заказ уже готовится — отмена недоступна» и сетевые ошибки раньше
        // глушились: список просто перезагружался, запись оставалась.
        do { try await API.shared.postVoid("api/v1/orders/\(oid)/cancel") }
        catch { cancelError = (error as? LocalizedError)?.errorDescription ?? "Не удалось отменить запись" }
        await load()
    }
}

/// Карточка записи: дата-плашка, услуга, организация, время, статус, действия Отменить/Маршрут.
private struct BookingCard: View {
    let booking: BookingItem
    /// Отмена записи — выполняет владелец экрана (BookingsView), он же перезагружает список.
    var onCancel: () async -> Void = {}
    @Environment(\.openURL) private var openURL
    @State private var confirmCancel = false
    @State private var working = false

    // Форматтеры — один раз на приложение: раньше каждая карточка на каждой
    // перерисовке создавала по два DateFormatter (это дорого). «d» — в той же
    // русской локали: в локали телефона с другими цифрами день выглядел чужим.
    private static let monthOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "MMM"; return f
    }()
    private static let dayOut: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateFormat = "d"; return f
    }()
    private var monthText: String {
        guard let d = booking.date else { return "" }
        return Self.monthOut.string(from: d).uppercased()
    }
    private var dayText: String {
        guard let d = booking.date else { return "—" }
        return Self.dayOut.string(from: d)
    }
    /// Год — только у записи не этого года: в «Прошедших» прошлогодний визит
    /// «ОКТ. 14» читался как нынешний октябрь.
    private var yearText: String? {
        guard let d = booking.date else { return nil }
        let cal = Calendar.current
        let y = cal.component(.year, from: d)
        return y == cal.component(.year, from: Date()) ? nil : String(y)
    }
    private var statusColor: Color {
        switch booking.status {
        case .confirmed: return YMColor.statusDone
        case .pending:   return YMColor.accent
        case .cancelled: return YMColor.statusCancel
        case .done:      return YMColor.muted
        case .inWork:    return YMColor.statusDone
        case .ready:     return YMColor.muted
        }
    }

    /// Маршрут строим по координатам организации, а если их нет — по адресу.
    private var hasRoute: Bool {
        // Выездная услуга: едет мастер, клиенту маршрут до собственного дома не нужен.
        guard booking.visitAddress == nil else { return false }
        return (booking.lat != nil && booking.lng != nil) || (booking.address?.isEmpty == false)
    }

    private func openRoute() {
        var url: URL?
        if let lat = booking.lat, let lng = booking.lng {
            url = URL(string: "http://maps.apple.com/?daddr=\(lat),\(lng)&dirflg=d")
        } else if let addr = booking.address,
                  let q = addr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            url = URL(string: "http://maps.apple.com/?daddr=\(q)&dirflg=d")
        }
        if let url { openURL(url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(spacing: 0) {
                    Text(monthText).font(.system(size: 11, weight: .bold)).foregroundStyle(YMColor.accent)
                    Text(dayText).font(.system(size: 22, weight: .heavy)).foregroundStyle(YMColor.text)
                    if let y = yearText {
                        Text(y).font(.system(size: 10, weight: .semibold)).foregroundStyle(YMColor.muted)
                    }
                }
                .frame(width: 56)
                .padding(.vertical, 8)
                .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(booking.service).font(.system(size: 15.5, weight: .heavy)).foregroundStyle(YMColor.text).lineLimit(1)
                    Text(booking.org).font(.system(size: 12.5)).foregroundStyle(YMColor.muted).lineLimit(1)
                    HStack(spacing: 8) {
                        Label(booking.time, systemImage: "clock")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(YMColor.text)
                            .labelStyle(.titleAndIcon)
                        Text(booking.status.title)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 9).padding(.vertical, 3)
                            .background(statusColor.opacity(0.16), in: Capsule())
                    }
                    .padding(.top, 5)

                    if let visit = booking.visitAddress {
                        Label("Мастер приедет: \(visit)", systemImage: "location.fill")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(YMColor.muted)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(2)
                            .padding(.top, 4)
                    }
                    // А63: комментарий мастеру, оставленный при записи.
                    if let note = booking.clientComment {
                        Label(note, systemImage: "text.bubble")
                            .font(.system(size: 11.5))
                            .foregroundStyle(YMColor.muted)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(3)
                            .padding(.top, 4)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(15)

            if booking.canCancel || hasRoute { Divider().overlay(YMColor.hairline) }

            HStack(spacing: 0) {
                if booking.canCancel {
                    Button {
                        Haptics.light(); confirmCancel = true
                    } label: {
                        Text(working ? "Отменяем…" : "Отменить")
                            .font(.system(size: 13.5, weight: .bold))
                            .foregroundStyle(YMColor.muted)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .disabled(working)
                    if hasRoute { Rectangle().fill(YMColor.hairline).frame(width: 1, height: 44) }
                }
                if hasRoute {
                    Button {
                        Haptics.light(); openRoute()
                    } label: {
                        Text("Маршрут")
                            .font(.system(size: 13.5, weight: .heavy))
                            .foregroundStyle(YMColor.accent)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .confirmationDialog("Отменить запись? Время освободится и станет доступно другим клиентам.",
                            isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Отменить запись", role: .destructive) {
                working = true
                Task { await onCancel(); working = false }
            }
            Button("Оставить", role: .cancel) {}
        }
        .ymCard(radius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(booking.service), \(booking.org), \(booking.time), \(booking.status.title)")
    }
}
