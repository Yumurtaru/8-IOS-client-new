import SwiftUI

// «Отправить посылку» — форма (двойник public/parcel.php + assets/js/parcel.js).
// GET /api/v1/parcels/quote — подсказки (перезапрос при смене города, кузова,
// грузчиков, веса, города назначения: с задержкой, устаревший ответ отбрасываем);
// POST /api/v1/parcels — вызов курьера с ключом повтора (Idempotency-Key + idempotency_key).
// Геоточку («Я здесь») не берём: в приложении нет своего запроса геолокации —
// только адрес, как разрешено заданием.

/// Черновик формы: «Выбрать другого водителя» открывает новую посылку с теми же данными.
struct ParcelDraft: Hashable {
    var cityId: Int = 0
    var from = "", senderPhone = "", to = "", recipientName = "", recipientPhone = "", what = ""
    var size = ""
    var trip = "city", vehicleClass = "car", loaders = 0, cargoKg = "", destCityId = 0
    var feeBy = "sender", comment = ""

    init() {}
    init(from p: Parcel, cityId: Int) {
        self.cityId = cityId
        from = p.pickupAddress; senderPhone = p.pickupPhone; to = p.dropAddress
        recipientName = p.recipientName; recipientPhone = p.recipientPhone; what = p.description
        size = p.size ?? ""
        trip = p.trip; vehicleClass = p.vehicleClass; loaders = p.loaders
        cargoKg = p.cargoKg.map(String.init) ?? ""; destCityId = p.destCityId ?? 0
        feeBy = p.feeBy; comment = p.comment
    }
}

@MainActor
final class ParcelFormModel: ObservableObject {
    // Подсказки сервера
    @Published private(set) var quote: ParcelQuote?
    @Published private(set) var firstLoadError: String?
    /// Посылки выключили (или раздел недоступен), пока форма открыта.
    @Published private(set) var closedText: String?
    @Published private(set) var quoting = false
    @Published private(set) var originCities: [City] = []
    @Published private(set) var allCities: [City] = []

    // Поля
    @Published var cityId = 0
    @Published var from = ""
    @Published var senderPhone = ""
    @Published var to = ""
    @Published var recipientName = ""
    @Published var recipientPhone = ""
    @Published var what = ""
    @Published var size = ""
    @Published var fee = ""
    @Published var feeBy = "sender"
    @Published var whenMin = 0
    @Published var comment = ""
    @Published var confirm = false
    // Машина (А80)
    @Published private(set) var trip = "city"
    @Published private(set) var vehicleClass = "car"
    @Published private(set) var loaders = 0
    @Published private(set) var cargoKg = ""
    @Published private(set) var destCityId = 0
    @Published private(set) var courierId = 0

    @Published var fieldErrors: [String: String] = [:]
    @Published var submitError: String?
    @Published private(set) var sending = false
    /// Повод перезапросить подсказки без смены полей (409 price_changed).
    @Published private(set) var refreshTick = 0

    /// Последняя цена, подставленная автоматически: свою цену человека не перетираем.
    private var lastAuto = ""
    /// Цена выбранного водителя — только для чтения.
    @Published private(set) var feeLocked = false
    /// Ключ повтора живёт с формой: тот же вызов после обрыва связи уходит с тем
    /// же ключом; после ответа по существу — новый.
    private var idemKey = ParcelFormModel.newKey()
    private var seq = 0
    private var loadedOnce = false

    init(draft: ParcelDraft?, sessionCity: Int?) {
        if let d = draft {
            cityId = d.cityId > 0 ? d.cityId : (sessionCity ?? 0)
            from = d.from; senderPhone = d.senderPhone; to = d.to
            recipientName = d.recipientName; recipientPhone = d.recipientPhone; what = d.what
            size = d.size; trip = d.trip; vehicleClass = d.vehicleClass; loaders = d.loaders
            cargoKg = d.cargoKg; destCityId = d.destCityId; feeBy = d.feeBy; comment = d.comment
        } else {
            cityId = sessionCity ?? 0
        }
    }

    static func newKey() -> String { "pc-" + UUID().uuidString.lowercased() }

    /// Смена любого из этих полей — новый запрос подсказок.
    var quoteKey: String { "\(cityId)|\(trip)|\(vehicleClass)|\(loaders)|\(cargoKg)|\(destCityId)|\(refreshTick)" }

    var hasPicker: Bool { !(quote?.vehicles.isEmpty ?? true) }
    var selectedVehicle: ParcelVehicle? {
        guard let vs = quote?.vehicles else { return nil }
        return vs.first { $0.code == vehicleClass } ?? vs.first
    }
    var selectedDriver: ParcelDriver? {
        guard trip == "intercity", courierId > 0 else { return nil }
        return quote?.drivers.first { $0.courierId == courierId }
    }
    var showsSize: Bool { !(quote?.sizes.isEmpty ?? true) && (!hasPicker || vehicleClass == "car") }

    var whenOptions: [(min: Int, label: String)] {
        // Межгород заказывают заранее — до 7 суток (pickup_in_min ≤ 10080), по городу — до 240 мин.
        // А101: с quote.scheduled_search — ещё «на потом» (1,5 / 3 / 4 ч); старый сервер — как было.
        ParcelSchedule.options(intercity: trip == "intercity", sched: quote?.scheduledSearch)
    }
    /// А101: «Ищем курьера до 15:30 — за 15 мин до забора» под выбором; nil — старый сервер или «Сейчас».
    var whenHint: String? {
        guard let q = quote else { return nil }
        return ParcelSchedule.hint(q.scheduledSearch, pickIn: whenMin, searchMinutes: q.searchMinutes, targetDriver: selectedDriver != nil)
    }

    /// Город отправления: города с заведениями (как на сайте) + текущий, если его там нет.
    var originOptions: [(id: Int, name: String)] {
        var list = originCities
        if cityId > 0, !list.contains(where: { $0.id == cityId }), let c = allCities.first(where: { $0.id == cityId }) { list.insert(c, at: 0) }
        return Self.named(list)
    }
    var originName: String {
        if let c = originOptions.first(where: { $0.id == cityId }) { return c.name }
        return cityId > 0 && cityId == Session.shared.cityId ? (Session.shared.cityName ?? "") : ""
    }
    /// Город назначения — все города, кроме города отправления.
    var destOptions: [(id: Int, name: String)] { Self.named(allCities.filter { $0.id != cityId }) }
    var destName: String { destOptions.first { $0.id == destCityId }?.name ?? (quote?.cargo?.destCity ?? "") }

    /// Одинаковые названия в разных областях — с областью в скобках.
    private static func named(_ list: [City]) -> [(id: Int, name: String)] {
        var cnt: [String: Int] = [:]
        for c in list { cnt[c.name ?? "", default: 0] += 1 }
        return list.map { c in
            let n = c.name ?? "Город \(c.id)"
            if (cnt[c.name ?? ""] ?? 0) > 1, let r = c.region, !r.isEmpty { return (c.id, n + " (" + r + ")") }
            return (c.id, n)
        }
    }

    // MARK: Загрузка

    func loadCities() async {
        async let orgReq: [City]? = try? await API.shared.list("api/v1/cities", query: ["with_orgs": "1"])
        async let allReq: [City]? = try? await API.shared.list("api/v1/cities")
        let org = await orgReq, all = await allReq
        if let org { originCities = org }
        if let all { allCities = all }
    }

    /// Подсказки по текущим полям. Вызывается из .task(id: quoteKey): смена
    /// полей отменяет прежний запрос, а seq отбрасывает запоздавший ответ.
    func requery() async {
        if loadedOnce { try? await Task.sleep(nanoseconds: 350_000_000) }
        if Task.isCancelled { return }
        seq += 1
        let my = seq
        var q: [String: String] = [:]
        if cityId > 0 { q["city_id"] = String(cityId) }
        q["trip"] = trip
        q["vehicle_class"] = vehicleClass
        q["loaders"] = String(loaders)
        if let kg = Int(cargoKg), kg > 0 { q["cargo_kg"] = String(kg) }
        if trip == "intercity", destCityId > 0 { q["dest_city_id"] = String(destCityId) }
        quoting = true
        do {
            let r = try await ParcelAPI.quote(q)
            guard my == seq, !Task.isCancelled else { return }
            quoting = false
            loadedOnce = true
            firstLoadError = nil
            closedText = nil
            apply(r)
        } catch is CancellationError {
            if my == seq { quoting = false }
        } catch {
            guard my == seq else { return }
            quoting = false
            if quote == nil {
                firstLoadError = error.userMessage ?? "Не удалось загрузить форму"
                return
            }
            // Сбой сети — оставляем прежние подсказки; отказ сервера (409 disabled,
            // 503) — посылки сейчас недоступны.
            if let e = error as? APIError {
                switch e {
                case .network, .timeout, .http: return
                default: break
                }
            }
            closedText = error.userMessage
        }
    }

    private func apply(_ q: ParcelQuote) {
        quote = q
        if cityId == 0, let c = q.cityId, c > 0 { cityId = c }
        if !q.vehicles.isEmpty, !q.vehicles.contains(where: { $0.code == vehicleClass }) { vehicleClass = q.vehicles[0].code }
        if trip == "intercity", !q.intercityEnabled { trip = "city" }
        // Выбранный водитель пропал из списка (сменили кузов, вес, город) — выбор снимаем.
        if courierId > 0, !q.drivers.contains(where: { $0.courierId == courierId }) { courierId = 0 }
        if let first = q.sizes.first, !q.sizes.contains(where: { $0.code == size }) { size = first.code }
        if !whenOptions.contains(where: { $0.min == whenMin }) { whenMin = 0 }
        autoFee()
    }

    /// Цена: у выбранного водителя — его total (только чтение); иначе подсказка
    /// для машины или общая; свою цену человека не трогаем.
    private func autoFee() {
        guard let q = quote else { return }
        let untouched = fee.trimmingCharacters(in: .whitespaces).isEmpty || fee == lastAuto || feeLocked
        let drv = selectedDriver
        feeLocked = drv != nil
        guard let auto = drv?.total ?? q.cargo?.suggestedFee ?? q.suggestedFee else { return }
        if drv != nil || untouched {
            fee = NSDecimalNumber(decimal: ParcelFmt.whole(auto)).stringValue
            lastAuto = fee
        }
    }

    var feeHint: String {
        guard let q = quote else { return "" }
        if let d = selectedDriver {
            return "Цена — по тарифу водителя: \(d.name), \(ParcelFmt.rub(d.kmPrice)) за км."
        }
        if q.cargo?.suggestedFee != nil {
            var t = "Подсказка для выбранной машины"
            if let km = q.cargo?.distanceKm, km > 0 { t += " (≈ \(Int(km.rounded())) км)" }
            return t + ". Можно предложить больше — быстрее возьмут."
        }
        var t = "Предлагаем \(ParcelFmt.rub(q.suggestedFee))"
        if q.base != nil, let pk = q.perKm, pk > 0 { t += " (\(ParcelFmt.rub(q.base)) + \(ParcelFmt.rub(pk)) за км, если известно расстояние)" }
        return t + ". Можно предложить больше — быстрее возьмут."
    }
    var feeRange: String? {
        guard let q = quote, let mn = q.minFee, let mx = q.cargo?.maxFee ?? q.maxFee, mx > 0 else { return nil }
        return "Допустимо от \(ParcelFmt.rub(mn)) до \(ParcelFmt.rub(mx))"
    }
    var onlineText: String {
        guard let q = quote else { return "" }
        let n = q.couriersOnline ?? 0
        if n > 0 { return "Курьеров на линии в городе: \(n). Кто первый возьмёт — тот и повезёт." }
        // А101 (как сайт): вызов «на потом» ждёт до времени забора.
        let later = q.scheduledSearch != nil ? ", а если забрать позже — до времени забора" : ""
        return "Сейчас на линии никого нет — вызов получит первый, кто выйдет на линию (ждём \(q.searchMinutes ?? 5) мин\(later))."
    }

    // MARK: Выбор

    func selectCity(_ id: Int) {
        guard id != cityId else { return }
        cityId = id
        if destCityId == id { destCityId = 0 }
        courierId = 0
    }
    func selectTrip(_ t: String) {
        guard t != trip else { return }
        trip = t; courierId = 0
        if !whenOptions.contains(where: { $0.min == whenMin }) { whenMin = 0 }
        autoFee()
    }
    func selectVehicle(_ c: String) { guard c != vehicleClass else { return }; vehicleClass = c; courierId = 0 }
    func selectLoaders(_ n: Int) { guard n != loaders else { return }; loaders = n; courierId = 0 }
    func setCargoKg(_ s: String) {
        let v = String(s.filter(\.isNumber).prefix(5))
        guard v != cargoKg else { return }
        cargoKg = v; courierId = 0
    }
    func selectDest(_ id: Int) { guard id != destCityId else { return }; destCityId = id; courierId = 0 }
    func selectDriver(_ id: Int) { courierId = id; autoFee() }

    // MARK: Отправка

    /// Вызвать курьера. Успех — id посылки.
    func submit() async -> Int? {
        guard !sending, quote != nil else { return nil }
        let t = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var b: [String: Any] = [
            "pickup_address": t(from), "pickup_phone": t(senderPhone),
            "drop_address": t(to), "recipient_name": t(recipientName), "recipient_phone": t(recipientPhone),
            "description": t(what), "fee_by": feeBy, "pickup_in_min": whenMin, "comment": t(comment),
            "confirm_allowed": confirm,
        ]
        // Город не выбран — сервер возьмёт город аккаунта.
        if cityId > 0 { b["city_id"] = cityId }
        let f = t(fee).replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        if !f.isEmpty { b["fee"] = f }
        // Размер «документы / в руках / на сиденье» — у легковой; у кузова S…XXL его задаёт кузов.
        if !hasPicker || vehicleClass == "car" { b["size"] = size.isEmpty ? "small" : size }
        if hasPicker {
            b["vehicle_class"] = vehicleClass
            b["loaders"] = loaders
            b["trip"] = trip
            if let kg = Int(cargoKg), kg > 0 { b["cargo_kg"] = kg }
            if trip == "intercity" { b["dest_city_id"] = destCityId }
            if let d = selectedDriver {
                b["courier_id"] = d.courierId
                if let tot = d.total { b["expected_fee"] = Money.wire(tot) }
            }
        }
        sending = true
        submitError = nil
        fieldErrors = [:]
        defer { sending = false }
        do {
            let p = try await ParcelAPI.create(b, key: idemKey)
            idemKey = Self.newKey()
            Haptics.success()
            ParcelGate.noteCreated()
            NotificationCenter.default.post(name: .ymParcelPushed, object: p.id)
            return p.id
        } catch let e as ParcelFailure {
            if !e.keepsIdemKey { idemKey = Self.newKey() }
            Haptics.error()
            fieldErrors = e.fields
            var msg = e.message
            if e.isUnknownOutcome {
                // Ключ прежний (keepsIdemKey): повторное нажатие не создаст второй вызов.
                msg = "Посылка по прошлому нажатию, возможно, уже создана — проверьте «Мои посылки»"
                fieldErrors = [:]
                ParcelGate.invalidate()
                NotificationCenter.default.post(name: .ymParcelPushed, object: nil)
            }
            if e.code == "price_changed" {
                // Водитель поменял тариф или уточнилась точка — новые подсказки и цена.
                if let nf = e.fields["fee"], let d = Decimal(string: nf) { fee = NSDecimalNumber(decimal: ParcelFmt.whole(d)).stringValue }
                fieldErrors["fee"] = nil
                refreshTick += 1
            }
            if e.code == "disabled" { closedText = e.message }
            submitError = msg
            return nil
        } catch {
            // Нет ответа (сеть, таймаут, 5xx) — ключ держим: повторное нажатие не создаст второй вызов.
            Haptics.error()
            submitError = error.userMessage
            return nil
        }
    }

    func error(_ field: String) -> String? { fieldErrors[field] }
}

// MARK: - Экран формы

struct ParcelFormView: View {
    @StateObject private var m: ParcelFormModel
    /// Открыть посылку после вызова (вместо формы).
    let onCreated: (Int) -> Void
    @State private var showCity = false
    /// Форма на экране: долгий вызов мог закончиться, когда человек уже ушёл.
    @State private var visible = false
    @FocusState private var focus: Bool

    init(draft: ParcelDraft?, onCreated: @escaping (Int) -> Void) {
        _m = StateObject(wrappedValue: ParcelFormModel(draft: draft, sessionCity: Session.shared.cityId))
        self.onCreated = onCreated
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Отправить посылку")
        .navigationBarTitleDisplayMode(.inline)
        .task { await m.loadCities() }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: m.quoteKey) { await m.requery() }
        .sheet(isPresented: $showCity) {
            ParcelCitySheet(title: "Город", options: m.originOptions, selected: m.cityId) { m.selectCity($0) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Готово") { focus = false }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if m.quote == nil {
            if let e = m.firstLoadError {
                ErrorRetryView(message: e) { Task { await m.requery() } }.padding(.top, 40)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
            }
        } else {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                Text("Курьер Yumurta заберёт вещь и отвезёт по городу или в другой город: документы, ключи, пакет, а на грузовой машине — мебель, технику, стройматериалы." + (rule == nil ? " Людей и животных курьеры не возят." : ""))
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                // А81: правило сервиса (quote.rule) — плашкой, как на сайте. Старый сервер rule
                // не шлёт — плашки нет, текст выше как раньше.
                if let rule { ruleBanner(rule) }
                if let c = m.closedText {
                    Text(c).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                        .padding(YMSpace.md).frame(maxWidth: .infinity, alignment: .leading)
                        .background(YMColor.statusCancel.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                Text(m.onlineText).font(YMFont.callout).foregroundStyle(YMColor.text)
                    .padding(YMSpace.md).frame(maxWidth: .infinity, alignment: .leading)
                    .background(YMColor.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                section("Откуда") {
                    pickerField("Город", value: m.originName.isEmpty ? "Город аккаунта" : m.originName, error: m.error("city_id")) { showCity = true }
                    field("Адрес", text: $m.from, prompt: "Улица, дом, подъезд", limit: 255, error: m.error("pickup_address"))
                    field("Телефон отправителя", text: $m.senderPhone, prompt: "По умолчанию — телефон аккаунта", limit: 32,
                          keyboard: .phonePad, error: m.error("pickup_phone"))
                }
                section("Куда") {
                    field("Адрес", text: $m.to, prompt: "Улица, дом, квартира", limit: 500, error: m.error("drop_address"))
                    field("Получатель", text: $m.recipientName, prompt: "Имя", limit: 120, error: m.error("recipient_name"))
                    field("Телефон получателя", text: $m.recipientPhone, prompt: "+7 900 000-00-00", limit: 32,
                          keyboard: .phonePad, error: m.error("recipient_phone"))
                }
                section("Что везём") {
                    field("Описание", text: $m.what, prompt: "Ключи, документы, пакет с одеждой", limit: 300, error: m.error("description"))
                    if m.hasPicker {
                        ParcelCargoPicker(m: m)
                        ForEach(["vehicle_class", "loaders", "trip", "dest_city_id", "courier_id", "cargo_kg"], id: \.self) { k in
                            if let e = m.error(k) { ParcelErrorLine(text: e) }
                        }
                    }
                    if m.showsSize, let q = m.quote {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Размер").font(YMFont.subhead).foregroundStyle(YMColor.text)
                            ForEach(q.sizes, id: \.code) { s in
                                radio(s.label, on: m.size == s.code) { m.size = s.code }
                            }
                            if let e = m.error("size") { ParcelErrorLine(text: e) }
                        }
                    }
                }
                section("Оплата курьеру") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Цена доставки, ₽").font(YMFont.subhead).foregroundStyle(YMColor.text)
                        TextField("", text: $m.fee)
                            .keyboardType(.decimalPad)
                            .focused($focus)
                            .disabled(m.feeLocked)
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(m.feeLocked ? YMColor.muted : YMColor.text)
                            .padding(.horizontal, 14).frame(height: 48)
                            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                            .ymMaxLength($m.fee, 10)
                        Text(m.feeHint).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        if let r = m.feeRange { Text(r).font(YMFont.caption).foregroundStyle(YMColor.muted) }
                        if let e = m.error("fee") { ParcelErrorLine(text: e) }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Кто платит курьеру").font(YMFont.subhead).foregroundStyle(YMColor.text)
                        radio("Я, когда курьер заберёт", on: m.feeBy == "sender") { m.feeBy = "sender" }
                        radio("Получатель, при вручении", on: m.feeBy == "recipient") { m.feeBy = "recipient" }
                        if let e = m.error("fee_by") { ParcelErrorLine(text: e) }
                    }
                }
                section("Когда забрать") {
                    Picker("Когда забрать", selection: $m.whenMin) {
                        ForEach(m.whenOptions, id: \.min) { o in Text(o.label).tag(o.min) }
                    }
                    .pickerStyle(.menu)
                    .tint(YMColor.accent)
                    if let h = m.whenHint { Text(h).font(YMFont.caption).foregroundStyle(YMColor.muted) }
                    if let e = m.error("pickup_in_min") { ParcelErrorLine(text: e) }
                    field("Комментарий курьеру", text: $m.comment, prompt: "Подъезд, этаж, домофон", limit: 500, error: m.error("comment"))
                }
                if let rules = rulesText, !rules.isEmpty {
                    Text(rules).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                Button { Haptics.selection(); m.confirm.toggle() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: m.confirm ? "checkmark.square.fill" : "square")
                            .font(.system(size: 20)).foregroundStyle(m.confirm ? YMColor.accent : YMColor.muted)
                        Text("Во вложении нет запрещённого, это вещь — не пассажир и не животное")
                            .font(YMFont.callout).foregroundStyle(YMColor.text)
                            .multilineTextAlignment(.leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if let e = m.error("confirm_allowed") { ParcelErrorLine(text: e) }
                if let e = m.submitError {
                    Text(e).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                }
                Button {
                    focus = false
                    Task { @MainActor in
                        // Ушёл с формы, пока шёл вызов, — экран не подменяем (посылка видна в «Мои посылки»).
                        if let id = await m.submit(), visible { onCreated(id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if m.sending { ProgressView().tint(YMColor.onAccent) }
                        Text(m.sending ? "Вызываем…" : "Вызвать курьера")
                    }
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(m.sending || m.closedText != nil)
                .opacity(m.closedText != nil ? 0.5 : 1)
            }
        }
    }

    // MARK: Элементы

    /// А81: правило сервиса без точки в конце; nil — старый сервер.
    private var rule: String? {
        guard let r = m.quote?.rule?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty else { return nil }
        return r.hasSuffix(".") ? String(r.dropLast()) : r
    }
    /// rules у А81 начинается с правила — оно уже в плашке сверху, не повторяем (как сайт).
    private var rulesText: String? {
        guard let r = m.quote?.rules else { return nil }
        guard let rule else { return r }
        return r.replacingOccurrences(of: rule + ". ", with: "")
    }

    private func ruleBanner(_ rule: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(rule + ".").font(YMFont.callout.weight(.bold)).foregroundStyle(YMColor.text)
            Text("Людей и животных курьеры не возят — для поездок есть такси.")
                .font(YMFont.callout).foregroundStyle(YMColor.text)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(YMSpace.md).frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.statusPending.opacity(0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(YMColor.statusPending.opacity(0.45), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text(title).font(YMFont.headline).foregroundStyle(YMColor.text)
            c()
        }
        .padding(YMSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ymCard(radius: 18)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, limit: Int,
                       keyboard: UIKeyboardType = .default, error: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(YMFont.subhead).foregroundStyle(YMColor.text)
            TextField(prompt, text: text)
                .keyboardType(keyboard)
                .focused($focus)
                .font(YMFont.body)
                .padding(.horizontal, 14).frame(height: 46)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(error != nil ? YMColor.statusCancel : Color.clear, lineWidth: 1))
                .ymMaxLength(text, limit)
            if let error { ParcelErrorLine(text: error) }
        }
    }

    private func pickerField(_ label: String, value: String, error: String?, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(YMFont.subhead).foregroundStyle(YMColor.text)
            Button(action: action) {
                HStack {
                    Text(value).font(YMFont.body).foregroundStyle(YMColor.text)
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(YMColor.muted)
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            if let error { ParcelErrorLine(text: error) }
        }
    }

    private func radio(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.selection(); action() } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 18)).foregroundStyle(on ? YMColor.accent : YMColor.muted)
                Text(title).font(YMFont.callout).foregroundStyle(YMColor.text).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
