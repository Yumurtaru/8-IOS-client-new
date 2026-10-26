import SwiftUI
import MapKit
import SafariServices

//  OrderDetailView.swift
//  Yumurta — premium iOS-клиент. Экран 6 (detail) «Заказ №…».
//
//  Init-сигнатура: OrderDetailView(id: Int, onChat: @escaping (Int) -> Void)
//    id     — orderId.
//    onChat — открыть чат с заведением по этому заказу (навигацию решает вызывающая сторона).
//
//  Данные 1:1 со старым клиентом:
//    GET  api/v1/orders/{id}          → OrderDetail  (status, items, суммы Double?…)
//    GET  api/v1/orders/{id}/track    → TrackData    (courierLat/Lng, courierName/Phone, etaMinutes, status)
//    GET  api/v1/orders/{id}/reorder  → ReorderData  (повтор заказа: shopId/Name/Slug + items)
//  Деньги — Double? → Money.format(Money.parse(x)) (Decimal).
//
//  Таймлайн статусов строится машиной OrderFlow (new→accepted→preparing→ready→in_delivery→done; cancelled).
//  Пин курьера и таймлайн говорят на том же «золотом» визуальном языке, что лента в списке.

extension Notification.Name {
    /// Пришёл/нажат push о заказе (object — id заказа, Int). Открытые деталь
    /// заказа и чат по нему перечитываются сразу, а не ждут опроса (до 24 с).
    static let ymOrderPushed = Notification.Name("ym.orderPushed")
}

// MARK: - CourierPoint (аннотация карты)

private struct CourierPoint: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

// MARK: - Локальные типы действий (Models.swift не трогаем — контракт аддитивный)

/// Обёртка ссылки оплаты для .sheet(item:) (openURL/SafariView).
struct PayLink: Identifiable {
    let id = UUID()
    let url: URL
}

/// Тело отзыва: POST api/v1/reviews {order_id, rating, text}.
/// camelCase → snake_case через API.encoder (.convertToSnakeCase) — 1:1 с Android createReview.
private struct OrderReviewBody: Encodable {
    let orderId: Int
    let rating: Int
    let text: String?
}

// MARK: - OrderDetailViewModel

@MainActor
final class OrderDetailViewModel: ObservableObject {
    let id: Int
    @Published var order: OrderDetail?
    @Published var track: TrackData?
    @Published var loading = true
    @Published var reorderInFlight = false
    @Published var reorderDone = false     // сервер повторил заказ → корзина обновлена

    // Действия по заказу (паритет с Android): отмена / онлайн-оплата / отзыв / NPS.
    @Published var actionBusy = false      // общий busy для одиночных действий (cancel/pay/review/nps)
    @Published var toast: String?          // единый тост-результат действия
    @Published var reviewSent = false      // локальный флаг «отзыв отправлен» (сервер флага не отдаёт)
    @Published var reviewAlready = false   // П-23.1: 409 при отправке — отзыв уже оставлен
    @Published var npsSent = false         // локальный флаг «NPS отправлен»
    @Published var payLink: PayLink?       // ссылка YooKassa → открыть во внешнем браузере

    private var pollTimer: Timer?
    private var pollTick: Int = 0
    /// Тик опроса ещё идёт (медленная сеть, повторы до ~60 с) — следующий
    /// не ставим поверх: раньше запросы копились каждые 8 с.
    private var pollBusy = false

    init(id: Int) { self.id = id }

    /// Заказ не загрузился (сеть, 5xx). Раньше это показывалось как «Заказ не
    /// найден» без кнопки повтора, а повторная загрузка с ошибкой стирала уже
    /// открытый заказ.
    @Published var loadError: String?

    func load() async {
        loading = true
        async let t: TrackData?   = try? await API.shared.get("api/v1/orders/\(id)/track")
        do {
            let o: OrderDetail = try await API.shared.get("api/v1/orders/\(id)")
            order = o
            loadError = nil
        } catch is CancellationError {
        } catch {
            if order == nil {
                loadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить заказ"
            }
        }
        track = await t
        loading = false
    }

    /// Перезагрузка после действия (отмена меняет статус → перерисовать таймлайн/кнопки).
    func reload() async {
        if let o: OrderDetail = try? await API.shared.get("api/v1/orders/\(id)") { order = o }
        if let t: TrackData   = try? await API.shared.get("api/v1/orders/\(id)/track") { track = t }
    }

    // MARK: Действия

    /// Отмена заказа: POST api/v1/orders/{id}/cancel (без тела). По успеху — перезагрузка.
    func cancel() async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            try await API.shared.postVoid("api/v1/orders/\(id)/cancel")
            Haptics.success(); toast = "Заказ отменён"
            await reload()
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отменить заказ"
            // П-20.3: 422 «Заказ уже отменён» / «уже готовится» — статус на экране
            // устарел: перечитываем заказ, чтобы кнопка «Отменить» ушла.
            if let s = (error as? APIError)?.rejectStatus, s == 409 || s == 422 { await reload() }
        }
    }

    /// Онлайн-оплата: POST api/v1/orders/{id}/pay-online → PayOnlineResp(confirmation_url).
    /// По успеху — открываем confirmation_url (система/SafariView через openURL).
    func payOnline() async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            let resp: PayOnlineResp = try await API.shared.post("api/v1/orders/\(id)/pay-online")
            if let link = resp.confirmationUrl, let url = URL(string: link) {
                Haptics.light(); payLink = PayLink(url: url)
            } else {
                Haptics.warning(); toast = "Не удалось открыть оплату"
            }
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Ошибка оплаты"
            // 409/422 («уже оплачен», «заказ отменён») — карточка устарела:
            // перечитываем, иначе «Оплатить» оставалась и отвечала тем же отказом.
            if let s = (error as? APIError)?.rejectStatus, s == 409 || s == 422 { await reload() }
        }
    }

    /// Отзыв: POST api/v1/reviews {order_id, rating, text}. Контракт 1:1 с Android createReview.
    func sendReview(rating: Int, text: String) async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        // Пробелы и пустые строки по краям не отправляем: «   » уходило отзывом-пустышкой.
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await API.shared.postVoid("api/v1/reviews",
                body: OrderReviewBody(orderId: id, rating: rating, text: t.isEmpty ? nil : t))
            Haptics.success(); reviewSent = true; toast = "Спасибо за отзыв!"
        } catch let e as APIError where e.rejectStatus == 409 {
            // П-23.1: 409 — отзыв по заказу уже есть: форму прячем, не «ошибка».
            Haptics.warning(); reviewAlready = true; toast = "Отзыв уже оставлен"
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить отзыв"
        }
    }

    /// NPS (опционально): POST api/v1/orders/{id}/nps {score, comment}. Тело — общий NpsBody.
    func sendNps(score: Int, comment: String) async {
        guard !actionBusy else { return }
        actionBusy = true; defer { actionBusy = false }
        do {
            try await API.shared.postVoid("api/v1/orders/\(id)/nps",
                body: NpsBody(score: score, comment: comment.isEmpty ? nil : comment))
            Haptics.success(); npsSent = true; toast = "Спасибо за оценку!"
        } catch {
            Haptics.error(); toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить оценку"
        }
    }

    /// Живой опрос трекинга (8с) — только пока заказ активен (в пути / готовится).
    func startTrackingIfActive() {
        guard OrderFlow.isActive(order?.status ?? track?.status) else { return }
        pollTimer?.invalidate()
        pollTick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.pollBusy else { return }
                self.pollBusy = true
                defer { self.pollBusy = false }
                if let t: TrackData = try? await API.shared.get("api/v1/orders/\(self.id)/track") {
                    self.track = t
                }
                // Каждый третий тик (24 с) перечитываем заказ: продавец мог
                // изменить состав, и на открытом экране это должно появиться
                // само, а не после выхода и повторного входа.
                self.pollTick &+= 1
                if self.pollTick % 3 == 0,
                   let o: OrderDetail = try? await API.shared.get("api/v1/orders/\(self.id)") {
                    self.order = o
                }
                // Заказ завершён или отменён — опрос больше не нужен (раньше шёл,
                // пока открыт экран). Проверку оплаты это не трогает.
                if let st = self.order?.status ?? self.track?.status, !OrderFlow.isActive(st) {
                    self.pollTimer?.invalidate(); self.pollTimer = nil
                }
            }
        }
    }

    /// Пауза опроса в фоне: только таймер, проверка оплаты идёт дальше.
    /// Возобновляет startTrackingIfActive при возврате в приложение.
    func pauseTracking() { pollTimer?.invalidate(); pollTimer = nil }

    func stopTracking() {
        pollTimer?.invalidate(); pollTimer = nil
        // Проверка оплаты после ухода с экрана не нужна: раньше она ещё до 30 с
        // дёргала сервер, а два наложившихся цикла снимали блокировку «Оплатить»
        // раньше времени.
        paymentRefreshTask?.cancel(); paymentRefreshTask = nil
        checkingPayment = false
    }
    private var paymentRefreshTask: Task<Void, Never>?
    /// До какого момента ждём подтверждения оплаты: ушли на чат и вернулись
    /// в эти ~30 с — проверку продолжаем, иначе «Оплатить» снова было активно.
    private var paymentCheckUntil: Date?
    func resumePaymentCheckIfNeeded() {
        guard let until = paymentCheckUntil, until > Date(),
              (order?.paymentStatus ?? "").lowercased() != "paid" else { paymentCheckUntil = nil; return }
        startPaymentRefresh(resume: true)
    }
    func startPaymentRefresh(resume: Bool = false) {
        if !resume { paymentCheckUntil = Date().addingTimeInterval(30) }
        paymentRefreshTask?.cancel()
        paymentRefreshTask = Task { [weak self] in await self?.refreshAfterPayment() }
    }

    /// Закрыли страницу оплаты — перечитываем заказ. Раньше экран продолжал
    /// показывать «Оплатить», и человек мог заплатить второй раз. Уведомление
    /// ЮKassa доходит до сервера с задержкой, поэтому смотрим ещё раз через 3 с.
    /// Уведомление ЮKassa бывает и через 10–20 с: проверяем до ~30 с, а кнопка
    /// «Оплатить» всё это время заблокирована. Раньше после двух проверок она
    /// снова становилась активной, и можно было создать второй платёж.
    @Published var checkingPayment = false
    func refreshAfterPayment() async {
        checkingPayment = true
        defer { if !Task.isCancelled { checkingPayment = false } }
        for attempt in 0..<10 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
            if Task.isCancelled { return }
            if let o: OrderDetail = try? await API.shared.get("api/v1/orders/\(id)") {
                order = o
                if (o.paymentStatus ?? "").lowercased() == "paid" { return }
            }
        }
    }

    /// Текст ошибки повтора заказа (раньше была только вибрация: кнопка молча
    /// «не срабатывала», и человек не понимал почему).
    @Published var reorderError: String?

    /// Повторить заказ: сервер возвращает состав → кладём в корзину (single-store cart).
    ///
    /// Если корзина занята ДРУГИМ заведением, состав не подменяем молча, а
    /// отдаём его наружу через `pendingReorder` — экран спросит подтверждение
    /// тем же диалогом, что и карточка товара. Раньше набранная корзина другого
    /// заведения исчезала без предупреждения.
    func repeatOrder(cart: Cart) async {
        guard !reorderInFlight else { return }
        // reorderDone сбрасываем: после первого удачного повтора неудачный второй
        // уводил в корзину, а ошибка оставалась на скрытом табе.
        reorderInFlight = true; reorderError = nil; reorderDone = false
        defer { reorderInFlight = false }
        // GET api/v1/orders/{id}/reorder → ReorderData (как в старом клиенте: Reorder.perform).
        // Сбой и «нечего повторять» различаем: раньше на всё — «Проверьте
        // соединение», даже когда сервер ответил текстом или все позиции сняты.
        let data: ReorderData
        do {
            data = try await API.shared.get("api/v1/orders/\(id)/reorder")
        } catch is CancellationError {
            return
        } catch {
            Haptics.warning()
            reorderError = (error as? LocalizedError)?.errorDescription
                ?? "Не удалось повторить заказ. Проверьте соединение и попробуйте ещё раз."
            return
        }
        guard let shopId = data.shopId, let items = data.items, !items.isEmpty else {
            Haptics.warning()
            reorderError = "Позиции этого заказа больше не продаются."
            return
        }
        // Конвертация ReorderItem → CartLine (single-store: одна корзина = один магазин).
        // Ключ строки — с индексом и модификаторами: две строки одного товара
        // (разные добавки) раньше получали один ключ, и +/− меняли только первую.
        let lines: [CartLine] = items.enumerated().compactMap { idx, it in
            guard let pid = it.productId else { return nil }
            let mods = it.modifierIds ?? []
            var line = CartLine(key: "reorder-\(pid)-\(mods.map(String.init).joined(separator: "."))-\(idx)",
                                productId: pid,
                                name: it.name ?? "Товар",
                                unitPrice: it.unitPrice ?? it.price ?? 0,
                                qty: it.qty ?? 1,
                                modifierIds: mods,
                                modsLabel: it.modifiersLabel ?? "",
                                photo: it.photo)
            line.unit = it.unit
            line.qtyFractional = it.qtyFractional
            line.qtyPresets = it.qtyPresets
            return line
        }
        guard !lines.isEmpty else {
            Haptics.warning()
            reorderError = "Позиции этого заказа больше не продаются."
            return
        }
        // Часть состава сервер отфильтровал (товар снят с продажи) — скажем об
        // этом, но ПОСЛЕ применения: иначе текст «добавили остальные» висел бы
        // под диалогом подтверждения, когда ещё ничего не добавлено.
        let partial = lines.count < items.count
        if let cur = cart.shopId, cur != shopId, !cart.isEmpty {
            pendingReorder = (lines, shopId, data.shopName, data.shopSlug, partial)
            conflictShopName = data.shopName
            return
        }
        applyReorder(lines, shopId: shopId, shopName: data.shopName, shopSlug: data.shopSlug, partial: partial, cart: cart)
    }

    /// Состав, ожидающий подтверждения смены заведения корзины.
    @Published var conflictShopName: String?
    var pendingReorder: (lines: [CartLine], shopId: Int, shopName: String?, shopSlug: String?, partial: Bool)?

    func applyReorder(_ lines: [CartLine], shopId: Int, shopName: String?, shopSlug: String?, partial: Bool, cart: Cart) {
        cart.setLines(lines, shopId: shopId, shopName: shopName, shopSlug: shopSlug)
        reorderError = partial ? "Часть позиций больше не продаётся — добавили остальные." : nil
        Haptics.success()
        reorderDone = true
    }

    func confirmPendingReorder(cart: Cart) {
        guard let p = pendingReorder else { return }
        pendingReorder = nil; conflictShopName = nil
        applyReorder(p.lines, shopId: p.shopId, shopName: p.shopName, shopSlug: p.shopSlug, partial: p.partial, cart: cart)
    }

    func cancelPendingReorder() { pendingReorder = nil; conflictShopName = nil }
}

// MARK: - OrderDetailView (screen: detail)

struct OrderDetailView: View {
    let id: Int
    /// Открыть чат с заведением по этому заказу.
    var onChat: (Int) -> Void

    @EnvironmentObject private var cart: Cart
    @EnvironmentObject private var router: DeepLinkRouter
    @StateObject private var vm: OrderDetailViewModel

    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.751, longitude: 37.618),
        span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02))

    init(id: Int, onChat: @escaping (Int) -> Void) {
        self.id = id
        self.onChat = onChat
        _vm = StateObject(wrappedValue: OrderDetailViewModel(id: id))
    }

    private var courierCoord: CLLocationCoordinate2D? {
        guard let lat = vm.track?.courierLat, let lng = vm.track?.courierLng else { return nil }
        // 0,0 — «точки ещё нет» (курьер назначен, геопозиция не пришла): раньше
        // карта показывала пин в океане у Африки.
        guard lat != 0 || lng != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    var body: some View {
        ScrollView {
            if vm.loading && vm.order == nil {
                VStack(spacing: YMSpace.md) {
                    SkeletonBox().frame(height: 200)
                    SkeletonBox().frame(height: 240)
                }
                .padding(YMSpace.xl)
            } else if let o = vm.order {
                VStack(spacing: YMSpace.lg) {
                    // Паритет с Android: заведение и время заказа под заголовком.
                    if let head = headerLine(o) {
                        Text(head)
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if OrderFlow.isActive(o.status), courierCoord != nil {
                        mapCard
                    }
                    // Паритет с Android: курьер назначен, а точки ещё нет (нет
                    // геопозиции, первая минута смены) — плашку с именем и
                    // звонком всё равно показываем; раньше она пряталась вместе с картой.
                    if OrderFlow.isActive(o.status), courierCoord != nil || courierKnown {
                        courierPlate
                    }
                    timelineCard(o)
                    // А63: комментарий клиента к записи на услугу.
                    if let note = clientNote(o) { clientNoteCard(note) }
                    if canPay(o) { payCard(o) }          // онлайн-оплата (неоплаченный online-заказ)
                    if let ch = o.changes, !ch.isEmpty { changesCard(ch) }
                    itemsCard(o)
                    // П-23.1: форма отзыва — по can_review сервера; NPS — как раньше.
                    if showReviewCard(o) { reviewCard(o) }
                    if showNpsCard(o) { npsCard(o) }      // NPS (для доставленных)
                    actionButtons(o)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.lg)
            } else if let e = vm.loadError {
                // Ошибка загрузки — с повтором, а не «Заказ не найден».
                ErrorRetryView(message: e) {
                    Task { await vm.load(); vm.startTrackingIfActive() }
                }
                .padding(.top, 60)
            } else {
                emptyBox
            }
        }
        // Комментарий к отзыву многострочный: «Ввод» — новая строка, клавиатуру
        // было не убрать, и она закрывала «Отправить отзыв» и оценку. Теперь жестом.
        .scrollDismissesKeyboard(.interactively)
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(); if !Task.isCancelled { vm.startTrackingIfActive(); vm.resumePaymentCheckIfNeeded() } }   // экран успели закрыть — опрос не запускаем
        .onDisappear { visible = false; vm.stopTracking() }
        .onAppear { visible = true }
        // Вернулись в приложение — статус и курьер могли смениться, пока оно
        // было свёрнуто: перечитываем сразу и снова включаем опрос (он
        // останавливается сам, когда заказ завершён).
        .onChange(of: scenePhase) { phase in
            // Ушли в фон — таймер опроса снимаем: иначе при возврате просроченный
            // тик срабатывал сразу вместе с перечитыванием ниже (двойной запрос трека).
            // Проверку оплаты не трогаем — человек может вернуться из приложения банка.
            if phase == .background, vm.order != nil { vm.pauseTracking(); return }
            guard phase == .active, visible, vm.order != nil else { return }
            // Пока шёл reload, экран могли закрыть — без проверки опрос
            // перезапускался после onDisappear и тикал вхолостую.
            Task { await vm.reload(); if visible { vm.startTrackingIfActive() } }
        }
        // Повторный push об ЭТОМ заказе, пока экран открыт: раньше новый статус
        // или состав появлялись только с опросом (заказ — раз в 24 с).
        .onReceive(NotificationCenter.default.publisher(for: .ymOrderPushed)) { n in
            guard (n.object as? Int) == id, visible, vm.order != nil else { return }
            Task { await vm.reload(); if visible { vm.startTrackingIfActive() } }
        }
        .onChange(of: courierCoord?.latitude) { _ in recenter() }
        // Диалог подтверждения отмены заказа.
        .alert("Отменить заказ?", isPresented: $showCancelAlert) {
            Button("Не сейчас", role: .cancel) {}
            Button("Отменить заказ", role: .destructive) { Task { await vm.cancel() } }
        } message: {
            Text("Заказ №\(navNumber) будет отменён. Действие необратимо.")
        }
        // Ссылка YooKassa — открываем во внешнем браузере (SafariView-эквивалент).
        .sheet(item: $vm.payLink, onDismiss: { vm.startPaymentRefresh() }) { link in SafariSheet(url: link.url) }
        // Тост-результат действия (отмена / оплата / отзыв / NPS).
        .overlay(alignment: .bottom) { toastOverlay }
    }

    @State private var showCancelAlert = false
    @Environment(\.scenePhase) private var scenePhase
    /// Экран заказа виден (для перечитывания при возврате из фона).
    @State private var visible = false
    @State private var reviewRating = 5
    @State private var reviewText = ""
    @State private var npsScore = -1

    /// Сервер прислал имя или телефон курьера (только пока заказ в пути).
    private var courierKnown: Bool {
        let n = (vm.track?.courierName ?? "").trimmingCharacters(in: .whitespaces)
        let p = (vm.track?.courierPhone ?? "").trimmingCharacters(in: .whitespaces)
        return !n.isEmpty || !p.isEmpty
    }

    /// «Заведение · 20.09.2026 14:05» — как шапка детали заказа на Android.
    private func headerLine(_ o: OrderDetail) -> String? {
        var parts: [String] = []
        if let s = o.shopName?.trimmingCharacters(in: .whitespaces), !s.isEmpty { parts.append(s) }
        let d = DateFmt.short(o.createdAt)
        if !d.isEmpty { parts.append(d) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var navNumber: String {
        if let n = vm.order?.dailyNumber { return "\(n)" }
        return "\(id)"
    }

    // MARK: Доступность действий по реальным статусам (сверено с OrderFlow/Android)

    /// Отмена: только ранние шаги (new/accepted) — до готовки/доставки; не для done/cancelled.
    /// П-25 №4: только точные коды сервера (незнакомый статус — без «Отменить»)
    /// и пока деньги не приняты. Бронь жилья отменяется по своим правилам
    /// (удержание) — в «Мои поездки», здесь кнопки нет.
    private func canCancel(_ o: OrderDetail) -> Bool {
        let st = (o.status ?? "").lowercased()
        guard st == "new" || st == "accepted" else { return false }
        if (o.paymentStatus ?? "").lowercased() == "paid" { return false }
        return o.shopType != "lodging"
    }

    /// Бронь жилья ещё можно отменить, но не отсюда — подсказка, куда идти.
    private func lodgingCancelHint(_ o: OrderDetail) -> Bool {
        guard o.shopType == "lodging" else { return false }
        let st = (o.status ?? "").lowercased()
        return st == "new" || st == "accepted"
    }

    /// А63: текст клиента к записи (без пробелов по краям); пусто — nil.
    private func clientNote(_ o: OrderDetail) -> String? {
        guard let c = o.clientComment?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
        return c
    }

    private func clientNoteCard(_ note: String) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text("Комментарий мастеру").font(YMFont.headline).foregroundStyle(YMColor.text)
            Text(note).font(YMFont.body).foregroundStyle(YMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    /// Онлайн-оплата: тип оплаты online, заказ не отменён/не завершён.
    /// В контракте OrderDetail нет payment_status → показываем для активного online-заказа
    /// (сервер повторную оплату оплаченного заказа отклонит; UI аддитивен).
    private func canPay(_ o: OrderDetail) -> Bool {
        let pt = (o.paymentType ?? "").lowercased()
        // Только онлайн-оплата. «card_courier» — картой при получении: раньше
        // contains("card") показывал на таких заказах кнопку онлайн-оплаты.
        let isOnline = pt == "online" || pt == "online_card"
        let paid = (o.paymentStatus ?? "").lowercased() == "paid"
        return isOnline && !paid && OrderFlow.isActive(o.status)
    }

    /// Отзыв/NPS: только для доставленного заказа.
    private func canReview(_ o: OrderDetail) -> Bool { OrderFlow.isDone(o.status) }

    /// П-23.1: блок отзыва. Сервер прислал can_review — верим ему (отзыв уже
    /// есть → блока нет); поля нет (старый сервер) — прежняя логика по статусу.
    /// Только что отправленный или «уже оставлен» (409) — блок с итогом.
    private func showReviewCard(_ o: OrderDetail) -> Bool {
        if vm.reviewSent || vm.reviewAlready { return true }
        // Паритет с Android: отзыв уже оставлен (has_review) — у выполненного
        // заказа блок остаётся со «Спасибо за отзыв!», а не пропадает молча.
        if reviewThanks(o) && canReview(o) { return true }
        if let c = o.canReview { return c }
        return canReview(o)
    }

    /// Сервер: отзыв есть, новый оставить нельзя (has_review без can_review).
    private func reviewThanks(_ o: OrderDetail) -> Bool {
        o.hasReview == true && o.canReview != true
    }

    /// П-24 №2 (А62): форма NPS — у завершённого заказа, пока оценки нет
    /// (has_nps). Только что отправили — блок со «Спасибо». Старый сервер без
    /// has_nps — как раньше, по статусу.
    private func showNpsCard(_ o: OrderDetail) -> Bool {
        if vm.npsSent { return true }
        return canReview(o) && o.hasNps != true
    }

    @ViewBuilder private var toastOverlay: some View {
        if let msg = vm.toast {
            Text(msg)
                .font(YMFont.subhead).foregroundStyle(YMColor.text)
                .padding(.horizontal, YMSpace.lg).padding(.vertical, YMSpace.sm)
                .background(YMColor.surface2, in: Capsule())
                .overlay(Capsule().strokeBorder(YMColor.hairline, lineWidth: 1))
                .padding(.bottom, YMSpace.xxxl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                // Таймер на КАЖДОЕ сообщение: раньше таймер первого тоста гасил
                // следующий, пришедший раньше чем через 2 с («Заказ отменён» и т.п.).
                .task(id: msg) {
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    if !Task.isCancelled { vm.toast = nil }
                }
        }
    }

    private var navTitle: String {
        if let n = vm.order?.dailyNumber { return "Заказ №\(n)" }
        return "Заказ №\(id)"
    }

    private func recenter() {
        guard let c = courierCoord else { return }
        // Сглаживание маркера (как в старом TrackView): плавно двигаем центр между опросами.
        withAnimation(.easeInOut(duration: 1.0)) { region.center = c }
    }

    // MARK: Карта с золотым пином курьера

    private var mapCard: some View {
        ZStack {
            Map(coordinateRegion: $region,
                annotationItems: courierCoord.map { [CourierPoint(coordinate: $0)] } ?? []) { p in
                MapAnnotation(coordinate: p.coordinate) {
                    CourierPin()   // золотой пульсирующий пин — единый визуальный язык
                }
            }
            .allowsHitTesting(false)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // MARK: Плашка курьера

    private var courierPlate: some View {
        HStack(spacing: YMSpace.md) {
            LogoBadge(url: nil,
                      letter: (vm.track?.courierName ?? "К").prefix(1).uppercased(),
                      size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Курьер · \(vm.track?.courierName ?? "в пути")")
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                HStack(spacing: 6) {
                    StatusDot(color: YMColor.accent, pulsing: true, size: 6)
                    Text(etaLine).font(YMFont.subhead).foregroundStyle(YMColor.accent)
                }
            }
            Spacer(minLength: 8)
            if let phone = vm.track?.courierPhone, !phone.isEmpty {
                Button {
                    Haptics.light()
                    if let url = URL(string: "tel://\(phone.filter { $0.isNumber || $0 == "+" })") {
                        UIApplication.shared.open(url)
                    }
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
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private var etaLine: String {
        let mins = vm.track?.etaMinutes
        // Подпись сервера — только если трек не ушёл вперёд статуса карточки.
        let st = vm.track?.status ?? vm.order?.status
        let base = OrderStatus.label(st, shopType: vm.order?.shopType,
                                     title: st == vm.order?.status ? vm.order?.statusTitle : nil)
        if let m = mins, m > 0 { return "\(base) · \(m) мин до вас" }
        return base
    }

    // MARK: Таймлайн статусов

    private func timelineCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Статус заказа")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.md)

            // Золотая живая лента-резюме над таймлайном (единый язык со списком).
            GoldStatusRibbon(progress: OrderFlow.progress(o.status, shopType: o.shopType),
                             pulsing: OrderFlow.isEnRoute(o.status),
                             cancelled: OrderFlow.isCancelled(o.status))
                .padding(.bottom, YMSpace.lg)

            // Предзаказ (П-24 №7): время, к которому готовить/доставить. ETA у
            // такого заказа сервер не считает — показываем это время.
            if !OrderFlow.isCancelled(o.status), let pre = DateFmt.preorder(o.preorderAt) {
                Label("Ко времени: \(pre)", systemImage: "clock.fill")
                    .font(YMFont.headline)
                    .foregroundStyle(YMColor.accent)
                    .labelStyle(.titleAndIcon)
                    .padding(.bottom, YMSpace.md)
            }

            if OrderFlow.isCancelled(o.status) {
                HStack(spacing: YMSpace.sm) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YMColor.statusCancel)
                    Text(o.shopType == "lodging" ? "Бронь отменена" : "Заказ отменён")
                        .font(YMFont.headline).foregroundStyle(YMColor.statusCancel)
                }
            } else {
                let current = OrderFlow.stepIndex(o.status)
                // П-25 №4: незнакомый код статуса — подпись сервера (status_title),
                // иначе все шаги серые и непонятно, что с заказом.
                if current < 0, let t = o.statusTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
                    Text(t).font(YMFont.headline).foregroundStyle(YMColor.text)
                        .padding(.bottom, YMSpace.sm)
                }
                // Самовывоз и заказ за столиком в путь не уходят: шаг «Курьер в пути»
                // у них лишний (если заказ вдруг в нём — показываем).
                let dt = o.deliveryType ?? ""
                let noCourier = !dt.isEmpty && dt != "delivery" && current != 4
                ForEach(visibleSteps(o, noCourier: noCourier), id: \.offset) { idx, key in
                    TimelineRow(
                        title: stepTitle(key, o: o, noCourier: noCourier),
                        time: stepTime(idx: idx, current: current, o: o),
                        state: idx < current ? .done : (idx == current ? .active : .todo),
                        isLast: idx == OrderFlow.steps.count - 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    /// Шаги таймлайна с их номером в OrderFlow.steps (номер нужен для времени и
    /// состояния шага). Без «Курьер в пути» у самовывоза; у брони жилья (А64) —
    /// только new → accepted → done.
    private func visibleSteps(_ o: OrderDetail, noCourier: Bool) -> [(offset: Int, element: String)] {
        var out: [(offset: Int, element: String)] = []
        for (i, key) in OrderFlow.steps.enumerated() {
            if noCourier && key == "in_delivery" { continue }
            if OrderFlow.isLodgingSkipped(key, shopType: o.shopType) { continue }
            out.append((offset: i, element: key))
        }
        return out
    }

    /// Подпись шага: серверная из status_timeline (словами типа организации),
    /// иначе свой словарь. Самовывоз — «Выполнен», а не «Доставлен».
    private func stepTitle(_ key: String, o: OrderDetail, noCourier: Bool) -> String {
        if let t = o.statusTimeline?.step(key)?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        // А64: бронь жилья — свои слова («Завершена», а не «Выполнен»).
        if o.shopType == "lodging" { return OrderFlow.stepTitle(key, shopType: "lodging") }
        if noCourier, key == "done", vm.order?.shopType != "service" { return "Выполнен" }
        return OrderFlow.stepTitle(key, shopType: vm.order?.shopType)
    }

    /// Подпись времени шага: время перехода от сервера; для оформления — createdAt;
    /// для активного — «сейчас»; для будущего — ETA (если есть).
    private func stepTime(idx: Int, current: Int, o: OrderDetail) -> String {
        // Время перехода, если сервер его прислал (status_timeline[].at).
        if idx < OrderFlow.steps.count, idx <= current,
           let at = o.statusTimeline?.step(OrderFlow.steps[idx])?.at {
            let t = DateFmt.time(at)
            if !t.isEmpty { return t }
        }
        if idx == 0 { return DateFmt.time(o.createdAt) }
        if idx == current { return "сейчас" }
        // Предзаказ: «ожидается ~N мин» не показываем — заказ ко времени.
        if idx == OrderFlow.steps.count - 1, DateFmt.preorder(o.preorderAt) == nil,
           let m = vm.track?.etaMinutes, m > 0, current < idx {
            return "ожидается ~\(m) мин"
        }
        return ""
    }

    // MARK: Состав + суммы

    private func itemsCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Состав").font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.xs)
            ForEach(o.items ?? []) { it in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: YMSpace.sm) {
                        Text(qtyLabel(it))
                            .font(.system(size: 14, weight: .heavy)).foregroundStyle(YMColor.accent)
                        Text(it.name ?? "—").font(YMFont.body).foregroundStyle(YMColor.text)
                        Spacer(minLength: 8)
                        Text(Money.format(Money.parse(it.price)))
                            .font(YMFont.body).foregroundStyle(YMColor.muted)
                    }
                    if it.quantityChanged {
                        Text("изменено: было \(numText(it.qtyOrdered))\((it.unit ?? "").isEmpty ? "" : " " + (it.unit ?? ""))")
                            .font(YMFont.caption).foregroundStyle(YMColor.accent)
                    }
                }
            }
            Divider().overlay(YMColor.hairline).padding(.vertical, YMSpace.xs)
            sumRow("Товары", o.subtotal)
            if let d = o.deliveryPrice, d > 0 { sumRow("Доставка", d) }
            if let f = o.serviceFee, f > 0 { sumRow("Сервисный сбор", f) }
            if let t = o.tip, t > 0 { sumRow("Чаевые курьеру", t) }
            if let d = o.discount, d > 0 {
                sumRow(o.promoCode.map { "Скидка (\($0))" } ?? "Скидка", d, negative: true, green: true)
            }
            if let ps = o.pointsSpent, ps > 0 { sumRow("Оплачено баллами", ps, negative: true, green: true) }
            HStack {
                Text("Итого").font(YMFont.headline).foregroundStyle(YMColor.text)
                Spacer()
                Text(Money.format(Money.parse(o.total)))
                    .font(.system(size: 17, weight: .heavy)).foregroundStyle(YMColor.text)
            }
            .padding(.top, YMSpace.xs)
            // «Сдача с …», указанная при оплате наличными (payment_note): раньше
            // клиент отправлял её, но в карточке заказа не видел.
            if let note = changeNoteText(o) {
                Text(note).font(YMFont.callout).foregroundStyle(YMColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    /// Строка про сдачу: число → «Сдача с N ₽», иной текст → «Сдача: …», пусто → nil.
    private func changeNoteText(_ o: OrderDetail) -> String? {
        // Сайт шлёт change_from и при оплате картой/СБП — сдача есть только у наличных.
        guard (o.paymentType ?? "cash").lowercased() == "cash" else { return nil }
        let raw = o.paymentNote ?? ""
        let note = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if note.isEmpty { return nil }
        let digitsOnly = note.allSatisfy { ($0.isASCII && $0.isNumber) || $0 == " " }
        if digitsOnly { return "Сдача с " + note + " ₽" }
        return "Сдача: " + note
    }

    // ── Что изменилось в заказе ─────────────────────────────────────────────
    // Продавец мог уменьшить количество (не оказалось товара). Клиент должен
    // видеть не только новый состав, но и чем он отличается от заказанного.
    private func changesCard(_ changes: [OrderChange]) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Заказ изменён").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Продавец скорректировал состав.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
            ForEach(changes) { ch in
                VStack(alignment: .leading, spacing: 4) {
                    Divider().overlay(YMColor.hairline)
                    HStack {
                        Text(DateFmt.short(ch.at)).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        Spacer()
                        if let a = ch.actor, !a.isEmpty {
                            Text(a).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        }
                    }
                    ForEach(ch.lines ?? []) { l in
                        Text(changeLineText(l))
                            .font(YMFont.body).foregroundStyle(YMColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let r = ch.reason, !r.isEmpty {
                        Text("Причина: \(r)").font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    HStack {
                        Text("Сумма заказа").font(YMFont.callout).foregroundStyle(YMColor.muted)
                        Spacer()
                        Text(Money.format(Money.parse(ch.totalBefore)) + " → " + Money.format(Money.parse(ch.totalAfter)))
                            .font(YMFont.callout.weight(.semibold)).foregroundStyle(YMColor.text)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func changeLineText(_ l: OrderChangeLine) -> String {
        let unit = (l.unit ?? "").isEmpty ? "" : " " + (l.unit ?? "")
        let before = numText(l.qtyBefore) + unit
        let after = numText(l.qtyAfter) + unit
        let name = l.name ?? "Позиция"
        return l.op == "remove" ? "\(name) — убрано (было \(before))" : "\(name): \(before) → \(after)"
    }

    private func numText(_ v: Double?) -> String {
        let q = v ?? 0
        if q == q.rounded() { return String(Int(q)) }
        // Дробное — с запятой, как в русском тексте: «1,5 кг», а не «1.5 кг».
        return String(format: "%g", q).replacingOccurrences(of: ".", with: ",")
    }

    private func qtyLabel(_ it: OrderItem) -> String {
        let q = it.qty ?? 1
        let n = numText(q)
        // Весовой товар — с единицей: «0,5 кг» вместо «0.5×».
        if q != q.rounded(), let u = it.unit?.trimmingCharacters(in: .whitespaces), !u.isEmpty {
            return "\(n) \(u)"
        }
        return "\(n)×"
    }

    private func sumRow(_ title: String, _ value: Double?, negative: Bool = false, green: Bool = false) -> some View {
        HStack {
            Text(title).font(YMFont.callout).foregroundStyle(YMColor.muted)
            Spacer()
            Text((negative ? "−" : "") + Money.format(Money.parse(value)))
                .font(YMFont.callout)
                .foregroundStyle(green ? YMColor.statusDone : YMColor.muted)
        }
    }

    // MARK: Баннер онлайн-оплаты

    private func payCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Заказ не оплачен").font(YMFont.headline).foregroundStyle(YMColor.text)
            Text("К оплате: \(Money.format(Money.parse(o.total)))")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
            Button {
                Task { await vm.payOnline() }
            } label: {
                HStack {
                    if vm.actionBusy { ProgressView().tint(YMColor.onAccent) }
                    else if vm.checkingPayment { Text("Проверяем оплату…") }
                    else { Label("Оплатить картой", systemImage: "creditcard.fill") }
                }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(vm.actionBusy || vm.checkingPayment)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.accent.opacity(0.35), lineWidth: 1))
    }

    // MARK: Блок отзыва (звёзды 1–5 + комментарий)

    private func reviewCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Оцените заказ").font(YMFont.title3).foregroundStyle(YMColor.text)
            if vm.reviewSent || reviewThanks(o) {
                Text("Спасибо за отзыв!").font(YMFont.body).foregroundStyle(YMColor.muted)
            } else if vm.reviewAlready {
                // П-23.1: 409 — форму больше не показываем.
                Text("Отзыв уже оставлен").font(YMFont.body).foregroundStyle(YMColor.muted)
            } else {
                HStack(spacing: YMSpace.sm) {
                    ForEach(1...5, id: \.self) { i in
                        Image(systemName: i <= reviewRating ? "star.fill" : "star")
                            .font(.system(size: 28))
                            .foregroundStyle(i <= reviewRating ? YMColor.accent : YMColor.hairline)
                            .onTapGesture { Haptics.light(); reviewRating = i }
                            .accessibilityLabel("\(i) из 5")
                    }
                }
                TextField("Комментарий (необязательно)", text: $reviewText, axis: .vertical)
                    .lineLimit(2...5)
                    // Отзыв сервер хранит до 2000 символов и лишнее режет молча
                    // (POST api/v1/reviews, api_v1.php).
                    .ymMaxLength($reviewText, 2000)
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                    .padding(YMSpace.md)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                Button {
                    Task { await vm.sendReview(rating: reviewRating, text: reviewText) }
                } label: {
                    HStack {
                        if vm.actionBusy { ProgressView().tint(YMColor.onAccent) }
                        else { Text("Отправить отзыв") }
                    }
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(vm.actionBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    // MARK: Блок NPS (0–10, опционально)

    private func npsCard(_ o: OrderDetail) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Оцените сервис").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Насколько вероятно, что порекомендуете нас? (0–10)")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
            if vm.npsSent {
                Text("Спасибо за оценку!").font(YMFont.body).foregroundStyle(YMColor.muted)
                    .padding(.top, YMSpace.xs)
            } else {
                HStack(spacing: 6) {
                    ForEach(0...10, id: \.self) { i in
                        let on = npsScore == i
                        Text("\(i)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(on ? YMColor.onAccent : YMColor.text)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(on ? YMColor.accent : YMColor.surface2,
                                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(on ? YMColor.accent : YMColor.hairline, lineWidth: 1))
                            .onTapGesture { Haptics.light(); npsScore = i }
                    }
                }
                .padding(.top, YMSpace.xs)
                Button {
                    Task { await vm.sendNps(score: npsScore, comment: "") }
                } label: {
                    Text("Отправить оценку")
                        .font(YMFont.headline)
                        .foregroundStyle(npsScore >= 0 ? YMColor.accent : YMColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(npsScore >= 0 ? 0.5 : 0.2), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(vm.actionBusy || npsScore < 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    // MARK: Кнопки действий

    private func actionButtons(_ o: OrderDetail) -> some View {
        VStack(spacing: YMSpace.md) {
            Button {
                Haptics.light(); onChat(id)
            } label: {
                // «Чат с рестораном» писалось и у магазина, и у салона.
                Label(o.shopType == "shop" ? "Чат с магазином" : "Чат с заведением",
                      systemImage: "bubble.left.and.bubble.right.fill")
            }
            .buttonStyle(YMPrimaryButtonStyle())

            if let err = vm.reorderError {
                Text(err)
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // А64: бронь жилья «повторить» как заказ нельзя (сервер отвечал
            // «позиции больше не продаются») — кнопку не показываем.
            if o.shopType != "lodging" {
                Button {
                    Task {
                        await vm.repeatOrder(cart: cart)
                        if vm.reorderDone { router.requestedTab = 2 }  // открыть корзину (таб 2; 3 — «Заказы», где мы и так)
                    }
                } label: {
                    HStack {
                        if vm.reorderInFlight { ProgressView().tint(YMColor.accent) }
                        else { Label("Повторить заказ", systemImage: "arrow.clockwise") }
                    }
                    .font(YMFont.headline).foregroundStyle(YMColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(vm.reorderInFlight)
            }

            if lodgingCancelHint(o) {
                Text("Отменить бронь можно в разделе «Мои поездки» — там видны условия отмены.")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // «Отменить заказ» — только для ранних статусов, сдержанный красный контур + подтверждение.
            if canCancel(o) {
                Button {
                    Haptics.light(); showCancelAlert = true
                } label: {
                    HStack {
                        if vm.actionBusy { ProgressView().tint(YMColor.statusCancel) }
                        else { Text("Отменить заказ") }
                    }
                    .font(YMFont.headline).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.statusCancel.opacity(0.55), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .disabled(vm.actionBusy)
            }
        }
        // Корзина занята другим заведением: спрашиваем, как в карточке товара,
        // вместо молчаливой подмены состава. Алерт висит на ЭТОЙ вложенной вью,
        // а не на общем ScrollView: два одноимённых презентационных модификатора
        // на одной вью — известный способ получить «диалог не открывается».
        .alert("Очистить корзину?", isPresented: Binding(
            // ВАЖНО: в set гасим ТОЛЬКО флаг показа. Если чистить здесь и сам
            // состав, то к моменту выполнения действия кнопки он уже пуст —
            // SwiftUI сначала опускает isPresented и только потом зовёт action,
            // и «Очистить и повторить» срабатывало бы вхолостую.
            get: { vm.conflictShopName != nil },
            set: { if !$0 { vm.conflictShopName = nil } }
        )) {
            Button("Отмена", role: .cancel) { vm.cancelPendingReorder() }
            Button("Очистить и повторить", role: .destructive) {
                vm.confirmPendingReorder(cart: cart)
                if vm.reorderDone { router.requestedTab = 2 }
            }
        } message: {
            Text("В корзине заказ из «\(cart.shopName ?? "другого заведения")». Повтор заменит его на заказ из «\(vm.conflictShopName ?? "этого заведения")».")
        }
    }

    private var emptyBox: some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40)).foregroundStyle(YMColor.muted)
            Text("Заказ не найден").font(YMFont.title3).foregroundStyle(YMColor.text)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - TimelineRow (кружки шагов + соединительная линия)

private struct TimelineRow: View {
    enum StepState { case done, active, todo }
    let title: String
    let time: String
    let state: StepState
    let isLast: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: YMSpace.md) {
            VStack(spacing: 0) {
                circle
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? YMColor.accent : YMColor.hairline)
                        .frame(width: 2, height: 34)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: state == .todo ? .regular : .semibold))
                    .foregroundStyle(state == .todo ? YMColor.muted : YMColor.text)
                if !time.isEmpty {
                    Text(time).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .onAppear {
            guard state == .active, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { pulse = true }
        }
    }

    @ViewBuilder private var circle: some View {
        switch state {
        case .done:
            ZStack {
                Circle().fill(YMColor.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy)).foregroundStyle(YMColor.onAccent)
            }
            .frame(width: 26, height: 26)
        case .active:
            ZStack {
                Circle().fill(YMColor.accent.opacity(0.15))
                Circle().strokeBorder(YMColor.accent, lineWidth: 2)
                Circle().fill(YMColor.accent).frame(width: 9, height: 9)
            }
            .frame(width: 26, height: 26)
            .shadow(color: (pulse && !reduceMotion) ? YMPalette.gold.opacity(0.5) : .clear,
                    radius: pulse ? 8 : 0)
            .scaleEffect((pulse && !reduceMotion) ? 1.06 : 1)
        case .todo:
            Circle()
                .fill(YMColor.surface2)
                .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
                .frame(width: 26, height: 26)
        }
    }
}

// MARK: - CourierPin (золотой пульсирующий пин курьера)

/// Пин курьера на карте — золотой, с мягко пульсирующим кольцом (тот же язык, что лента/точка).
/// Деградирует при Reduce Motion в статичный пин.
struct CourierPin: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(YMPalette.gold.opacity(pulse ? 0 : 0.35))
                    .frame(width: pulse ? 46 : 18, height: pulse ? 46 : 18)
            }
            Circle().fill(YMColor.bg).frame(width: 26, height: 26)
            Circle().fill(YMColor.accent).frame(width: 20, height: 20)
            Image(systemName: "bicycle")
                .font(.system(size: 10, weight: .heavy)).foregroundStyle(YMColor.onAccent)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("Курьер на карте")
    }
}

// MARK: - SafariSheet (встроенный браузер для оплаты YooKassa)

/// Открывает confirmation_url YooKassa во встроенном SFSafariViewController —
/// пользователь не теряет приложение (как в старом клиенте PayLink).
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        // SFSafariViewController падает на ссылке не http(s) — такую не открываем.
        let scheme = url.scheme?.lowercased() ?? ""
        let safe = (scheme == "https" || scheme == "http") ? url : (URL(string: API.base) ?? url)
        let c = SFSafariViewController(url: safe)
        c.preferredControlTintColor = UIColor(YMColor.accent)
        return c
    }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
