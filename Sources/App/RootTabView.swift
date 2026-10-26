import SwiftUI

/// Корневой таб-бар premium-клиента: Главная / Поиск / Корзина / Заказы / Объявления.
/// Активная вкладка — золото (YMColor.accent через .tint). Фон бара — материал.
///
/// Навигация:
///  • Каждый таб — самодостаточный экран со своим NavigationStack
///    (HomeView / SearchScreen / CartFlow / OrdersView / AdsBoardView).
///    Внутренние переходы (организация → товар, заказ → деталь → чат) живут
///    внутри соответствующего стека — RootTabView их не дублирует.
///  • Кросс-таб переходы (плашка поиска → таб Поиск, «Повторить заказ» → Заказы)
///    идут через DeepLinkRouter.requestedTab.
///  • Глобальный флоу корзины (Корзина→Оформление→Успех) и чат показываются
///    ПОВЕРХ активного таба через NavCoordinator (Cart — синглтон, доступ к нему
///    нужен из любого экрана: StickyCartBar в Org и т.д.).
struct RootTabView: View {
    @EnvironmentObject private var cart: Cart
    @EnvironmentObject private var net: NetworkMonitor
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var coord: NavCoordinator
    @EnvironmentObject private var session: Session
    /// Код из ссылки …/r/КОД. Раньше его записывали в роутер, но никто не
    /// читал — бонус за приглашение по ссылке не начислялся.
    @State private var referralPrompt: ReferralPrompt?
    @State private var tab = 0
    /// Организация из пуша РЕАЛЬНО на экране. Раньше корневые окна отключались
    /// по pendingOrgSlug: если шторка организации не смогла открыться, корзина
    /// и чат не работали до перезапуска приложения.
    @State private var orgShown = false
    /// П-52: мягкое окно «Вышла новая версия» ждёт «Главной» без окон и онбординга.
    @ObservedObject private var updates = AppUpdateStore.shared
    @AppStorage(AppStorageKey.onboarded) private var onboarded = false

    init() {
        // Фон таб-бара — системный материал (blur), тонкая золотая линия сверху.
        let appearance = UITabBarAppearance()
        appearance.configureWithDefaultBackground()
        UITabBar.appearance().scrollEdgeAppearance = appearance
        UITabBar.appearance().standardAppearance = appearance
    }

    var body: some View {
        VStack(spacing: 0) {
            if !net.online {
                Text("Нет подключения к интернету")
                    .font(YMFont.caption).fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(YMColor.statusCancel)
            }
            TabView(selection: $tab) {
                HomeView()
                    .sheet(item: $referralPrompt) { p in
                        NavigationStack {
                            ReferralView(prefillCode: p.code)
                                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { referralPrompt = nil } } }
                        }
                        .environmentObject(Session.shared)
                    }
                    .tabItem { Label("Главная", systemImage: "house.fill") }
                    .tag(0)

                SearchScreen()
                    .tabItem { Label("Поиск", systemImage: "magnifyingglass") }
                    .tag(1)

                // Корзина как вкладка (Корзина → Оформление → Успех) через CartFlow.
                CartFlow(
                    onClose: { tab = 0 },
                    onTrackOrder: { id in coord.pendingOrderDetail = id; tab = 3 },
                    // Во вкладке «Меню» вело на Главную, а не в заведение корзины.
                    openShopOnMenu: true
                )
                    .tabItem { Label("Корзина", systemImage: "cart.fill") }
                    .tag(2)
                    .badge(cart.count == 0 ? 0 : cart.count)

                OrdersView(onOpen: { _ in })
                    .tabItem { Label("Заказы", systemImage: "bag.fill") }
                    .tag(3)

                // Профиль убран из вкладок — открывается из шапки Главной.
                //
                // Пятую вкладку занимает доска объявлений. «Избранное» переехало
                // в профиль (сразу после «Мои записи»): экран FavoritesScreen
                // остался тем же, поменялось только место входа.
                AdsBoardView()
                    .tabItem { Label("Объявления", systemImage: "megaphone.fill") }
                    .tag(4)
            }
            // ── Раздел «Жильё» (поиск → объект → мои поездки) ──
            // Вход — чип «Жильё» на Главной; отдельной нижней вкладки нет,
            // там уже пять. Внутри своя NavigationStack, дальше каждый экран
            // раздела ведёт навигацию сам (по одному navigationDestination).
            //
            // ВАЖНО: cover навешен на TabView, а не на внешний VStack, где
            // уже висят корзина и организация-из-пуша. Несколько
            // fullScreenCover на ОДНОЙ вьюхе — известный способ получить
            // «шторка не открывается»: побеждает последняя. Разные уровни
            // иерархии этой проблемы не имеют.
            .fullScreenCover(isPresented: $coord.showLodging) {
                NavigationStack {
                    LodgingSearchView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { coord.showLodging = false }
                            }
                        }
                }
                .environmentObject(cart)
                .environmentObject(router)
                .environmentObject(coord)
                .environmentObject(Session.shared)
                // Заведение из «Жилья»: общие корзина/диалог отсюда не видны —
                // экран заведения показывает их сам (см. ymNestedPresentation).
                .environment(\.ymNestedPresentation, true)
            }
        }
        .tint(YMColor.accent)
        .animation(.easeInOut, value: net.online)
        .onChange(of: router.requestedTab) { newTab in
            if let t = newTab { tab = t; router.requestedTab = nil }
        }
        // «Следить за заказом» из флоу корзины → таб «Заказы» открывает деталь сам.
        .onChange(of: coord.pendingOrderDetail) { pending in
            if pending != nil { tab = 3 }
        }
        // Холодный старт из пуша о заказе: значение выставлено до появления
        // экрана, onChange на него не срабатывает.
        .onAppear {
            if coord.pendingOrderDetail != nil { tab = 3 }
            // П-21.1: холодный старт из push объявления — вкладка выставлена до
            // появления экрана, onChange(requestedTab) на неё не сработал.
            else if let t = router.requestedTab { tab = t; router.requestedTab = nil }
            presentReferralIfPossible()
        }
        .onChange(of: router.referralCode) { _ in presentReferralIfPossible() }
        // Гость перешёл по ссылке — код ждёт входа.
        .onChange(of: session.isLoggedIn) { _ in presentReferralIfPossible() }
        .onChange(of: coord.showCart) { _ in presentReferralIfPossible() }
        .onChange(of: coord.showLodging) { _ in presentReferralIfPossible() }
        .onChange(of: orgShown) { _ in presentReferralIfPossible() }
        .onChange(of: coord.profileOpen) { _ in presentReferralIfPossible() }
        // ── Корзина, конфликт корзины и чат ──
        // Пока открыта организация из пуша/ссылки (cover ниже), эти окна
        // показывает сам cover: SwiftUI не открывает второй cover/sheet с той
        // вьюхи, которая уже что-то показывает. Раньше в такой организации
        // плашка корзины и кнопка чата не делали ничего, а диалог «очистить
        // корзину?» рисовался под шторкой и всплывал уже после её закрытия.
        .modifier(GlobalPresenters(
            coord: coord, cart: cart, router: router,
            enabled: !orgShown,
            onTrackOrder: { id in coord.pendingOrderDetail = id }
        ))
        // ── Организация из уведомления «новое заведение в городе» ──
        // Отдельный cover, а не маршрут внутри таба: у табов по одному
        // navigationDestination, второй в SwiftUI просто не срабатывает.
        .fullScreenCover(isPresented: Binding(
            get: { coord.pendingOrgSlug != nil },
            set: { if !$0 { coord.pendingOrgSlug = nil } }
        ), onDismiss: { orgShown = false }) {
            NavigationStack {
                Group {
                    if let slug = coord.pendingOrgSlug, !slug.isEmpty {
                        // id: второй push/ссылка на другое заведение показывали прежнее.
                        OrgView(shopSlug: slug).id(slug)
                    } else {
                        EmptyView()
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { coord.pendingOrgSlug = nil }
                    }
                }
            }
            // Сбрасываем только по закрытию обложки: onDisappear срабатывал и
            // при показе корзины поверх организации.
            .onAppear { orgShown = true }
            .modifier(GlobalPresenters(
                coord: coord, cart: cart, router: router,
                enabled: true,
                // «Следить за заказом»: закрываем организацию, таб «Заказы» откроет деталь.
                onTrackOrder: { id in coord.pendingOrgSlug = nil; coord.pendingOrderDetail = id }
            ))
            .environmentObject(cart)
            .environmentObject(router)
            .environmentObject(coord)
            .environmentObject(Session.shared)
        }
        // ── П-52: «Вышла новая версия» (мягкое окно). Не поверх входа, шторок, обложек,
        // диалога корзины и онбординга — ждёт, пока человек окажется на «Главной».
        .modifier(SoftUpdatePrompt(store: updates, canShow: {
            onboarded && tab == 0 && !orgShown && referralPrompt == nil
                && !coord.showCart && !coord.cartConflict && !coord.showLodging
                && !coord.profileOpen && coord.chatOrderId == nil && coord.pendingOrgSlug == nil
        }, presentationKey: updatePresentationKey))
    }
}

extension RootTabView {
    /// П-52: слепок того, что push/ссылка/экраны открывают поверх вкладок. Изменился, пока на
    /// экране окно «Вышла новая версия», — окно убирается (без «Позже»), чтобы не мешать.
    fileprivate var updatePresentationKey: String {
        "\(coord.showCart)|\(coord.cartConflict)|\(coord.showLodging)|\(coord.profileOpen)|"
            + "\(coord.chatOrderId ?? 0)|\(coord.pendingOrgSlug ?? "")|\(coord.pendingOrderDetail ?? 0)|\(coord.pendingProductId ?? 0)|"
            + "\(router.requestedTab ?? -1)|\(router.referralCode ?? "")|\(referralPrompt?.code ?? "")"
    }
}

/// Корзина (Корзина → Оформление → Успех), диалог конфликта корзины и чат —
/// окна, которые открываются из любого экрана через NavCoordinator.
/// enabled = false — сейчас их показывает другой уровень (cover организации).
private struct GlobalPresenters: ViewModifier {
    @ObservedObject var coord: NavCoordinator
    let cart: Cart
    let router: DeepLinkRouter
    let enabled: Bool
    let onTrackOrder: (Int) -> Void

    func body(content: Content) -> some View {
        content
            // ── Глобальный флоу корзины ──
            .fullScreenCover(isPresented: Binding(
                get: { enabled && coord.showCart },
                set: { if !$0 { coord.showCart = false } }
            )) {
                CartFlow(
                    onClose: { coord.showCart = false },
                    onTrackOrder: onTrackOrder
                )
                .environmentObject(cart)
                .environmentObject(router)
                .environmentObject(coord)
                .environmentObject(Session.shared)
            }
            // ── Глобальный диалог конфликта корзины (single-store) ──
            .cartConflictDialog(
                isPresented: Binding(
                    get: { enabled && coord.cartConflict },
                    set: { coord.cartConflict = $0 }
                ),
                currentShop: coord.conflictCurrentShop,
                newShop: coord.conflictNewShop,
                onConfirm: { coord.conflictConfirm?(); coord.conflictConfirm = nil }
            )
            // ── Глобальный чат (из Org-FAB и из деталей заказа) ──
            .sheet(isPresented: Binding(
                get: { enabled && coord.chatOrderId != nil },
                set: { if !$0 { coord.chatOrderId = nil } }
            )) {
                NavigationStack {
                    Group {
                        if let id = coord.chatOrderId, id > 0 {
                            // .id: push о чате ДРУГОГО заказа при открытой шторке —
                            // новый экран, иначе @StateObject держал прежний чат.
                            ChatView(orderId: id).id(id)
                        } else {
                            ChatView.list          // id == -1 → общий список чатов
                        }
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { coord.chatOrderId = nil }
                        }
                    }
                }
                .environmentObject(Session.shared)
            }
    }
}

/// Код приглашения из ссылки для листа «Пригласить друга».
struct ReferralPrompt: Identifiable { let code: String; var id: String { code } }

extension RootTabView {
    fileprivate func presentReferralIfPossible() {
        // Под обложкой (организация, корзина, жильё) лист не покажется — ждём.
        // Профиль — тоже шторка: под ней лист приглашения не открывался, а код
        // уже был снят с роутера и пропадал (бонус за приглашение не начислялся).
        guard let c = router.referralCode, !c.isEmpty, session.isLoggedIn,
              !orgShown, !coord.showCart, !coord.showLodging, !coord.profileOpen else { return }
        router.referralCode = nil
        tab = 0
        referralPrompt = ReferralPrompt(code: c)
    }
}
