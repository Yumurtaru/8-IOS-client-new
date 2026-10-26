import SwiftUI

//  OrdersView.swift
//  Yumurta — premium iOS-клиент. Экран 6 (list) — точка входа таба «Заказы».
//
//  Init-сигнатура: OrdersView(onOpen: (Int) -> Void)
//    onOpen(orderId) — открыть деталь заказа (навигацию решает вызывающая сторона).
//
//  Данные 1:1 со старым клиентом (3 IOS-client OrdersView):
//    GET api/v1/orders → [Order]  (id, dailyNumber, status, total:Double?, createdAt, shopName, shopLogo,
//                                  is_appointment — записи на услугу отфильтровываются в «Мои записи»).
//  Деньги — Double? в модели → Money.format(Money.parse(x)) (Decimal, канон нового клиента).
//
//  Signature-элемент: «золотая живая лента статуса» — GoldStatusRibbon (прогресс + мягкий пульс),
//  сквозной визуальный язык через список / таймлайн / шапку чата / пин курьера.

// MARK: - Общая машина статусов заказа (единый источник для списка, детали и таймлайна)

/// Каноническая машина статусов: new → accepted → preparing → ready → in_delivery → done; cancelled.
/// Сервер отдаёт разные синонимы — нормализуем в один из 6 шагов (+ cancelled).
enum OrderFlow {
    /// Упорядоченные шаги «нормального» пути (без cancelled).
    static let steps: [String] = ["new", "accepted", "preparing", "ready", "in_delivery", "done"]

    /// Заголовки шагов для таймлайна. `shopType` — shop | cafe | service:
    /// шаги одни и те же, слова разные (кафе готовит, магазин собирает,
    /// салон работает). Параметр необязательный — старые вызовы не ломаются.
    static func stepTitle(_ key: String, shopType: String? = nil) -> String {
        // А64: бронь жилья — «Бронь создана / Подтверждена / Завершена».
        if shopType == "lodging", let l = OrderStatus.lodgingLabel(key) { return l }
        switch key {
        case "new":
            return shopType == "service" ? "Запись создана" : "Заказ оформлен"
        case "accepted":    return "Заведение приняло заказ"
        case "preparing":
            switch shopType {
            case "cafe":    return "Готовится"
            case "service": return "В работе"
            case "shop":    return "Собирается"
            default:        return "Готовится"
            }
        case "ready":
            switch shopType {
            case "service": return "Услуга выполнена"
            case "shop":    return "Собран, ждёт выдачи"
            default:        return "Готов к выдаче"
            }
        case "in_delivery": return "Курьер в пути"
        case "done":
            return shopType == "service" ? "Завершена" : "Доставлен"
        default:            return OrderStatus.label(key, shopType: shopType)
        }
    }

    /// Нормализация сырого статуса сервера в индекс шага (0…5). -1 = неизвестно.
    static func stepIndex(_ raw: String?) -> Int {
        switch normalize(raw) {
        case "new":         return 0
        case "accepted":    return 1
        case "preparing":   return 2
        case "ready":       return 3
        case "in_delivery": return 4
        case "done":        return 5
        default:            return -1
        }
    }

    /// Сведение синонимов сервера к канону машины.
    static func normalize(_ raw: String?) -> String {
        switch (raw ?? "").lowercased() {
        case "new", "pending", "created":                 return "new"
        case "accepted", "confirmed":                     return "accepted"
        case "preparing", "cooking", "processing":        return "preparing"
        case "ready", "cooked", "ready_for_pickup":       return "ready"
        case "in_delivery", "delivering", "on_the_way",
             "en_route", "shipping":                      return "in_delivery"
        case "done", "delivered", "completed", "finished":return "done"
        case "cancelled", "canceled", "rejected":         return "cancelled"
        default:                                          return (raw ?? "").lowercased()
        }
    }

    static func isCancelled(_ raw: String?) -> Bool { normalize(raw) == "cancelled" }
    static func isDone(_ raw: String?) -> Bool { normalize(raw) == "done" }
    static func isEnRoute(_ raw: String?) -> Bool { normalize(raw) == "in_delivery" }
    static func isActive(_ raw: String?) -> Bool { !isDone(raw) && !isCancelled(raw) }

    /// Прогресс 0…1 по машине (для золотой ленты).
    static func progress(_ raw: String?) -> Double {
        if isCancelled(raw) { return 1 }
        let i = stepIndex(raw)
        guard i >= 0 else { return 0.05 }
        return Double(i) / Double(steps.count - 1)
    }

    /// А64: у брони жилья три шага (new → accepted → done), без готовки и
    /// доставки: «Подтверждена» — половина ленты, а не пятая часть.
    static func progress(_ raw: String?, shopType: String?) -> Double {
        guard shopType == "lodging", !isCancelled(raw) else { return progress(raw) }
        switch normalize(raw) {
        case "new":      return 0.05
        case "accepted": return 0.5
        case "done":     return 1
        default:         return progress(raw)
        }
    }

    /// Шаги таймлайна, которые этому заказу не нужны. Бронь жилья: только
    /// new → accepted → done («Готовится», «В пути» у проживания — ошибка).
    static func isLodgingSkipped(_ key: String, shopType: String?) -> Bool {
        guard shopType == "lodging" else { return false }
        return key == "preparing" || key == "ready" || key == "in_delivery"
    }

    /// Семантический цвет статуса (light+dark из токенов).
    static func color(_ raw: String?) -> Color {
        if isCancelled(raw) { return YMColor.statusCancel }
        if isDone(raw)      { return YMColor.statusDone }
        if isEnRoute(raw)   { return YMColor.statusEnRoute } // золото
        return YMColor.statusPending
    }

    /// StatusPill.Kind по статусу.
    static func pillKind(_ raw: String?) -> StatusPill.Kind {
        if isCancelled(raw) { return .cancel }
        if isDone(raw)      { return .done }
        if isEnRoute(raw)   { return .enRoute }
        return .pending
    }
}

// MARK: - GoldStatusRibbon (signature: золотая живая лента статуса)

/// Золотой прогресс-бар с мягким пульсом — сквозной сигнатурный элемент.
/// progress 0…1. Пульс мягко «дышит» на активной части (у статуса «В пути»),
/// деградирует при Reduce Motion (статичная золотая заливка без свечения).
struct GoldStatusRibbon: View {
    var progress: Double
    /// Пульсировать ли (обычно только для активных «в пути» заказов).
    var pulsing: Bool = false
    var height: CGFloat = 6
    var cancelled: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    private var clamped: Double { min(max(progress, 0), 1) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                // Дорожка
                Capsule().fill(YMColor.surface2)
                // Золотая заливка (градиент для «премиального» блеска)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: cancelled
                                ? [YMColor.statusCancel, YMColor.statusCancel]
                                : [YMPalette.goldBright, YMPalette.gold, YMPalette.goldDeep],
                            startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: max(w * clamped, height))
                    // Мягкое золотое свечение-пульс на активной ленте.
                    .shadow(color: (pulsing && !cancelled && !reduceMotion)
                            ? YMPalette.gold.opacity(breathe ? 0.55 : 0.15) : .clear,
                            radius: breathe ? 10 : 4)
                    .opacity((pulsing && !reduceMotion) ? (breathe ? 1 : 0.82) : 1)
            }
        }
        .frame(height: height)
        .onAppear {
            guard pulsing, !cancelled, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// Цветная точка статуса с мягким пульсирующим кольцом (пульс — у «В пути»).
/// Деградирует при Reduce Motion в статичную точку.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    var size: CGFloat = 8

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var ring = false

    var body: some View {
        ZStack {
            if pulsing && !reduceMotion {
                Circle()
                    .stroke(color.opacity(ring ? 0 : 0.5), lineWidth: 2)
                    .frame(width: size + (ring ? 12 : 0), height: size + (ring ? 12 : 0))
            }
            Circle().fill(color).frame(width: size, height: size)
        }
        .frame(width: size + 12, height: size + 12)
        .onAppear {
            guard pulsing, !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ring = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - OrdersViewModel

@MainActor
final class OrdersViewModel: ObservableObject {
    @Published var orders: [Order] = []
    @Published var loading = true
    @Published var loadFailed = false
    private var didLoad = false
    // Догрузка (волна А3): по 100 заказов на страницу, meta.has_more. Активные
    // заказы — свежие и всегда на первой странице; догрузка нужна «Истории».
    @Published var hasMore = false
    @Published var moreFailed = false
    @Published private(set) var page = 1
    private var loadingMore = false
    private var gen = 0

    /// Первый вход в таб — грузим со скелетоном. Возврат в таб (в т.ч. после
    /// оформления заказа) — тихо обновляем список, чтобы новый заказ появился
    /// в «Активных» без pull-to-refresh. Скелетон при этом не мигает: он
    /// показывается только когда orders пуст (см. content).
    func firstLoad() async {
        if !didLoad { didLoad = true }
        await load()
    }

    func load() async {
        loading = true; loadFailed = false
        // Ответ, запрошенный до выхода/входа (reset), не применяем: заказы
        // прежнего аккаунта иначе ложились в список следующего.
        let myGen = gen
        do {
            // Записи на услугу сервер хранит как заказы и отдаёт в этом же списке.
            // Их место — раздел «Мои записи» (BookingsView, GET api/v1/appointments),
            // поэтому здесь они отфильтровываются по аддитивному признаку is_appointment.
            // Старый сервер этого поля не присылает → nil ≠ true → список как раньше.
            let first: Page<Order> = try await API.shared.page("api/v1/orders")
            guard myGen == gen else { loading = false; return }
            let fresh = first.items.filter { $0.isAppointment != true }
            if page > 1 {
                // Уже листали дальше первой страницы (возврат в таб, pull-to-refresh):
                // обновляем первую, а догруженное ниже не выбрасываем.
                let ids = Set(fresh.map(\.id))
                orders = fresh + orders.filter { !ids.contains($0.id) }
            } else {
                orders = fresh
                hasMore = first.hasMore
            }
        } catch is CancellationError {
            // Обновление жестом отменяется самим SwiftUI, когда список
            // перерисовывается. Раньше это показывало экран ошибки вместо
            // уже загруженных заказов.
        } catch {
            if myGen == gen { loadFailed = true }
        }
        loading = false
    }

    /// Сброс при входе/выходе: догруженные страницы прошлого аккаунта не должны
    /// «приклеиться» к списку следующего при обновлении первой страницы.
    func reset() {
        gen += 1
        orders = []; page = 1; hasMore = false; moreFailed = false; loadingMore = false
    }

    /// Следующая страница. Зовёт подвал «Истории», когда он виден.
    func loadMore() async {
        guard hasMore, !loadingMore, !loading else { return }
        loadingMore = true; moreFailed = false
        let myGen = gen, next = page + 1
        do {
            let p: Page<Order> = try await API.shared.page("api/v1/orders", query: ["page": String(next)])
            guard myGen == gen else { return }
            let known = Set(orders.map(\.id))
            orders += p.items.filter { $0.isAppointment != true && !known.contains($0.id) }
            page = next
            hasMore = p.hasMore && !p.items.isEmpty
        } catch {
            if myGen == gen && !(error is CancellationError) { moreFailed = true }
        }
        if myGen == gen { loadingMore = false }
    }

    var active: [Order]  { orders.filter { OrderFlow.isActive($0.status) } }
    var history: [Order] { orders.filter { !OrderFlow.isActive($0.status) } }
}

// MARK: - OrdersView (screen: list)

struct OrdersView: View {
    /// Открыть деталь заказа по id.
    let onOpen: (Int) -> Void

    @EnvironmentObject private var session: Session
    @EnvironmentObject private var coord: NavCoordinator
    @StateObject private var vm = OrdersViewModel()
    @State private var tab: Tab = .active
    // Деталь заказа пушится внутри собственного стека таба (self-contained).
    @State private var pushedOrder: Int?
    /// Деталь реально на экране — тогда новый заказ меняем на месте (.id),
    /// а не закрываем и открываем заново (мигание, на iOS 16 пуш мог потеряться).
    @State private var detailShown = false
    @Environment(\.scenePhase) private var scenePhase
    /// Приложение действительно уходило в фон (а не просто .inactive).
    @State private var wasBg = false

    enum Tab: Hashable { case active, history }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: YMSpace.md) {
                    // Табы Активные / История
                    YMSegmented(options: [Tab.active, Tab.history], selection: $tab) {
                        $0 == .active ? "Активные" : "История"
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, YMSpace.xs)

                    content
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Заказы")
            .navigationBarTitleDisplayMode(.large)
            // Гость: обновление жестом слало запрос без входа (401).
            .refreshable { if session.isLoggedIn { await vm.load() } }
            .task { if session.isLoggedIn { await vm.firstLoad() } }
            // Вернулись в приложение — статусы активных заказов могли смениться,
            // пока оно было свёрнуто: тихо обновляем список (без скелетона).
            // Только после настоящего ухода в фон: .inactive→.active (пункт
            // управления, Face ID) раньше тоже дёргал перезагрузку.
            .onChange(of: scenePhase) { phase in
                if phase == .background { wasBg = true; return }
                guard phase == .active, wasBg else { return }
                wasBg = false
                if session.isLoggedIn, !vm.orders.isEmpty, !vm.loading { Task { await vm.load() } }
            }
            .onChange(of: session.isLoggedIn) { logged in
                vm.reset()
                // Сессия кончилась / выход: открытая деталь заказа прежнего
                // аккаунта оставалась в стеке и после входа другого человека
                // показывала чужой заказ (и опрашивала его каждые 8 с).
                if !logged { pushedOrder = nil }
                if logged { Task { await vm.load() } }
            }
            // Деталь заказа → чат уходит в глобальный координатор.
            .navigationDestination(isPresented: Binding(
                get: { pushedOrder != nil },
                set: { if !$0 { pushedOrder = nil } }
            )) {
                if let id = pushedOrder {
                    // .id: при смене заказа (была открыта деталь A, пришёл пуш о B)
                    // экран должен пересоздаться — иначе @StateObject показывал A.
                    OrderDetailView(id: id, onChat: { orderId in coord.openChat(orderId: orderId) })
                        .id(id)
                        .onAppear { detailShown = true }
                        .onDisappear { detailShown = false }
                }
            }
        }
        // «Следить за заказом» из флоу корзины: RootTabView переключил таб,
        // здесь ПЕРЕЗАГРУЖАЕМ список (новый заказ должен появиться в «Активных»),
        // открываем деталь и сбрасываем сигнал.
        .onChange(of: coord.pendingOrderDetail) { pending in
            if let id = pending { consumePending(id) }
        }
        // Вкладка «Заказы» создаётся лениво: если её ещё не открывали, а заказ
        // уже оформили («Следить за заказом») или приложение запустили из пуша,
        // значение выставлено ДО появления экрана, и onChange не срабатывает.
        .onAppear { if let id = coord.pendingOrderDetail { consumePending(id) } }
    }

    private func consumePending(_ id: Int) {
        tab = .active            // новый заказ активен — показываем нужный таб
        coord.pendingOrderDetail = nil
        // Push о заказе, а вход не выполнен (вышли или сессия кончилась):
        // деталь отвечала «Сессия истекла» с бесконечным «Повторить».
        // Остаёмся на списке — там «Войти».
        guard session.isLoggedIn else { return }
        pushOrder(id)
        Task { await vm.load() } // всегда свежий список после оформления
    }

    /// Открыть деталь заказа (внутренний пуш + внешний колбэк для совместимости).
    private func openDetail(_ id: Int) {
        pushOrder(id)
        onOpen(id)
    }

    /// Повторный тап по вкладке «Заказы» снимает деталь со стека, а сеттер
    /// navigationDestination(isPresented:) SwiftUI не зовёт — pushedOrder
    /// оставался «висеть», и тап по заказу больше ничего не открывал (как на
    /// Главной). Сначала сбрасываем, потом открываем.
    private func pushOrder(_ id: Int) {
        if pushedOrder == nil || detailShown { pushedOrder = id; return }
        pushedOrder = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pushedOrder = id }
    }

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            emptyState(icon: "person.crop.circle.badge.questionmark",
                       title: "Войдите в аккаунт",
                       hint: "Чтобы видеть свои заказы и статусы доставки.")
            // Раньше вкладка была тупиком: просили войти, но кнопки входа не было.
            NavigationLink { AuthView() } label: { Text("Войти") }
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.horizontal, YMSpace.xxxl)
        } else if vm.loading && vm.orders.isEmpty {
            VStack(spacing: YMSpace.md) {
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(radius: YMRadius.card).frame(height: 128)
                }
            }
            .padding(.horizontal, YMSpace.xl)
        } else if vm.loadFailed && vm.orders.isEmpty {
            // Сбой загрузки — это НЕ «заказов нет». Раньше человек в метро
            // открывал «Заказы» во время доставки и видел «Активных заказов
            // нет»: решал, что заказ потерян, и звонил в поддержку.
            ordersErrorState
        } else {
            let list = tab == .active ? vm.active : vm.history
            // Обновление не прошло, а заказы уже на экране: раньше сбой был не
            // виден, и человек принимал устаревший статус за текущий.
            if vm.loadFailed && !vm.loading {
                Text("Не удалось обновить заказы. Потяните вниз, чтобы повторить.")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, YMSpace.xl)
            }
            if list.isEmpty {
                emptyState(icon: tab == .active ? "bag" : "clock.arrow.circlepath",
                           title: tab == .active ? "Активных заказов нет" : "История пуста",
                           hint: tab == .active
                                ? "Оформите заказ — здесь появится живой статус доставки."
                                : "Завершённые заказы будут храниться здесь.")
                // Новый покупатель (заказов ещё нет вовсе): раньше экран советовал
                // «оформите заказ», но вёл в никуда — даём путь в каталог.
                if vm.orders.isEmpty && !vm.loadFailed {
                    Button { Haptics.light(); DeepLinkRouter.shared.requestedTab = 0 } label: {
                        Text("Перейти в каталог")
                    }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .padding(.horizontal, YMSpace.xxxl)
                }
            } else {
                ForEach(list) { order in
                    OrderCard(order: order) { openDetail(order.id) }
                        .padding(.horizontal, YMSpace.xl)
                }
                if tab == .history && vm.hasMore {
                    LoadMoreFooter(page: vm.page, failed: vm.moreFailed) { await vm.loadMore() }
                }
            }
        }
    }

    private var ordersErrorState: some View {
        VStack(spacing: YMSpace.lg) {
            Text("⚠️").font(.system(size: 44))
            Text("Не удалось загрузить заказы")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Заказы на месте — их просто не удалось получить. Проверьте соединение и попробуйте ещё раз.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button { Task { await vm.load() } } label: {
                Text("Повторить").font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xxl).padding(.vertical, 12)
                    .background(YMColor.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 72)
    }

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: YMSpace.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(YMColor.surface2).frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
            }
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(hint)
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, YMSpace.xxxl)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}

// MARK: - OrderCard

/// Карточка заказа: лого, название, №, состав·сумма, строка статуса с цветной точкой
/// (пульс у «В пути») + ETA, и золотая живая лента прогресса.
private struct OrderCard: View {
    let order: Order
    var onTap: () -> Void

    private var money: String { Money.format(Money.parse(order.total)) }
    private var number: String { "№\(order.dailyNumber ?? order.id)" }
    private var enRoute: Bool { OrderFlow.isEnRoute(order.status) }
    private var cancelled: Bool { OrderFlow.isCancelled(order.status) }
    /// Подпись статуса: серверная (словами типа организации, знает и новые
    /// коды), иначе — свой словарь. Как в Android OrdersScreen.
    private var statusText: String {
        if let t = order.statusTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return OrderStatus.label(order.status, shopType: order.shopType)
    }

    /// VoiceOver: время предзаказа тоже читается (лейбл карточки заменяет детей).
    private var a11yText: String {
        let base = "\(order.shopName ?? "Заказ") \(number), \(statusText), \(money)"
        guard let pre = preorderText else { return base }
        return base + ", ко времени " + pre
    }

    /// «15 окт, 19:30» у предзаказа; nil — заказ не ко времени или отменён.
    private var preorderText: String? {
        if cancelled { return nil }
        return DateFmt.preorder(order.preorderAt)
    }

    /// Подпись справа в строке статуса.
    /// Для отменённых/доставленных — их статус; иначе — реальная дата/время заказа
    /// из created_at в формате «DD.MM, HH:mm» (паритет с Android formatOrderWhen).
    private var etaText: String {
        // А64: бронь жилья — «отменена» / «завершена», а не «доставлен».
        if cancelled { return order.shopType == "lodging" ? "отменена" : "отменён" }
        // Самовывоз, заказ за столиком и запись не «доставлены».
        if OrderFlow.isDone(order.status) {
            if order.shopType == "service" || order.shopType == "lodging" { return "завершена" }
            if let dt = order.deliveryType, !dt.isEmpty, dt != "delivery" { return "выполнен" }
            return "доставлен"
        }
        return Self.formatOrderWhen(order.createdAt)
    }

    /// «2026-07-03 16:00:00» / ISO → «03.07, 16:00». Разбор текстом (без зависимости от локали
    /// парсера) — как в Android: если не удалось — показываем строку как есть.
    static func formatOrderWhen(_ createdAt: String?) -> String {
        guard let s = createdAt, !s.trimmingCharacters(in: .whitespaces).isEmpty else { return "" }
        let time = s.range(of: #"\d{2}:\d{2}"#, options: .regularExpression).map { String(s[$0]) }
        var day: String?
        if let r = s.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) {
            let parts = s[r].split(separator: "-")          // [yyyy, MM, dd]
            if parts.count == 3 { day = "\(parts[2]).\(parts[1])" }
        }
        let joined = [day, time].compactMap { $0 }.joined(separator: ", ")
        return joined.isEmpty ? s.trimmingCharacters(in: .whitespaces) : joined
    }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                // ── Верх: лого + название/№ + сумма ──
                HStack(spacing: YMSpace.md) {
                    LogoBadge(url: API.imageURL(order.shopLogo),
                              letter: (order.shopName ?? "?").prefix(1).uppercased(),
                              size: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(order.shopName ?? "Заказ")
                            .font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(1)
                        Text(number)
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    Spacer(minLength: 8)
                    Text(money).font(.system(size: 16, weight: .heavy)).foregroundStyle(YMColor.text)
                }

                // ── Строка статуса: точка (пульс у «В пути») + текст + ETA ──
                HStack(spacing: YMSpace.sm) {
                    StatusDot(color: OrderFlow.color(order.status), pulsing: enRoute)
                    Text(statusText)
                        .font(YMFont.subhead)
                        .foregroundStyle(OrderFlow.color(order.status))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(etaText).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }

                // Предзаказ (П-24 №7): заказ «ко времени» — время видно сразу,
                // ETA у такого заказа нет. Отменённому строка не нужна.
                if let pre = preorderText {
                    Label("Ко времени: \(pre)", systemImage: "clock.fill")
                        .font(YMFont.subhead.weight(.semibold))
                        .foregroundStyle(YMColor.accent)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                }

                // ── Золотая живая лента статуса ──
                GoldStatusRibbon(progress: OrderFlow.progress(order.status, shopType: order.shopType),
                                 pulsing: enRoute,
                                 cancelled: cancelled)
            }
            .padding(YMSpace.lg)
        }
        .buttonStyle(CardPressStyle())
        .ymCard(radius: YMRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(a11yText)
    }
}

// MARK: - LogoBadge (общий: круглый логотип заведения / буква-заглушка)

/// Круглый логотип заведения: реальное фото через AsyncImage, иначе буква на золотом фоне.
struct LogoBadge: View {
    var url: URL?
    var letter: String
    var size: CGFloat = 46

    var body: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Text(letter)
                .font(.system(size: size * 0.42, weight: .heavy))
                .foregroundStyle(YMPalette.goldInk)
            if let url {
                CachedAsyncImage(url: url) { phase in
                    if case let .success(img) = phase { img.resizable().scaledToFill() }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        // .scaledToFill() делает картинку больше рамки, а clipShape обрезает
        // только рисование — без contentShape аватар ловил бы нажатия далеко
        // за своим кругом, воруя тапы у соседних строк списка.
        .contentShape(Circle())
        .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}
