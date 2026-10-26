import SwiftUI

//
//  CartFlow.swift — контейнер флоу корзины (Корзина → Оформление → Успех).
//
//  Собирает три самодостаточных экрана в один NavigationStack и связывает их
//  готовыми колбэками (onCheckout / onSuccess / onBack / onTrack / onHome):
//
//    CartView(onCheckout:onClose:)
//      → CheckoutView(onSuccess: (OrderCreateResult) -> Void, onBack:)
//        → SuccessView(order:, onTrack:, onHome:)
//
//  Показывается ГЛОБАЛЬНО из RootTabView как fullScreenCover (доступ к корзине
//  из любого места: StickyCartBar в Org, badge и т.п.). Контракт API не трогаем —
//  создание заказа делает CheckoutView сам.
//
//  Навигация наружу:
//    onClose          — закрыть весь флоу (‹ / «На главную» из пусто-состояния).
//    onTrackOrder(id) — «Следить за заказом»: родитель откроет таб «Заказы» + деталь.
//
struct CartFlow: View {
    /// Закрыть весь флоу корзины.
    var onClose: () -> Void
    /// Открыть трекинг заказа после успешного оформления.
    var onTrackOrder: (Int) -> Void
    /// «Меню» в корзине открывает заведение корзины (вкладка «Корзина»). В
    /// шторке поверх заведения — false: «Меню» просто закрывает шторку.
    var openShopOnMenu: Bool = false

    private enum Step: Hashable { case checkout, success }

    @State private var path: [Step] = []
    /// Гость нажал «Оформить» — сначала вход: без токена оформление получало
    /// 401 и «Сессия истекла», а войти из корзины было нельзя.
    @State private var showAuth = false
    // Результат создания заказа — источник данных для SuccessView.
    @State private var result: OrderCreateResult?
    @ObservedObject private var cart = Cart.shared

    var body: some View {
        NavigationStack(path: $path) {
            CartView(
                onCheckout: {
                    if Session.shared.isLoggedIn { path.append(.checkout) } else { showAuth = true }
                },
                onClose: { onClose() },
                onMenu: menuAction
            )
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .checkout:
                    CheckoutView(
                        onSuccess: { r in
                            result = r
                            path.append(.success)
                        },
                        onBack: { if !path.isEmpty { path.removeLast() } }
                    )
                case .success:
                    successScreen
                        .navigationBarBackButtonHidden(true)
                }
            }
        }
        // Ушли с «Заказ оформлен» через таб-бар — при возврате на вкладку
        // показываем корзину, а не прошлый успех (оттуда не было пути назад).
        .onDisappear { if path.last == .success { path.removeAll() } }
        // Корзину опустошили вне оформления (выход из аккаунта в профиле,
        // «Очистить и начать новую» в другом заведении) — вкладка «Корзина»
        // оставалась на пустом оформлении с серой кнопкой. Возвращаем в корзину.
        // После успешного заказа корзина тоже пустеет, но там стек уже на .success.
        .onChange(of: cart.isEmpty) { empty in
            if empty && path.last == .checkout { path.removeAll() }
        }
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: {
                    showAuth = false
                    path.append(.checkout)
                })
            }
            .environmentObject(Session.shared)
        }
    }

    /// «Меню» во вкладке: заведение корзины поверх вкладок (как из ссылки).
    private var menuAction: (() -> Void)? {
        guard openShopOnMenu else { return nil }
        return {
            if let slug = Cart.shared.shopSlug, !slug.isEmpty {
                NavCoordinator.shared.openOrg(slug: slug)
            } else {
                onClose()
            }
        }
    }

    @ViewBuilder private var successScreen: some View {
        if let r = result {
            SuccessView(
                order: r,
                onTrack: {
                    let id = r.resolvedId ?? 0
                    // Стек обязательно сбрасываем: вкладка «Корзина» живёт всё
                    // время работы приложения, и без этого при возврате на неё
                    // снова показывался экран «Заказ оформлен» от прошлого
                    // заказа — выйти оттуда можно было только на другую вкладку,
                    // а второй заказ через корзину не оформлялся вовсе.
                    path.removeAll()
                    result = nil
                    onClose()
                    // Номер заказа в ответе не пришёл: раньше открывалась деталь
                    // заказа 0 («Заказ не найден»). Тогда — просто список заказов.
                    if id > 0 {
                        onTrackOrder(id)
                    } else {
                        NavCoordinator.shared.revealForPush(closeAll: true) {
                            DeepLinkRouter.shared.requestedTab = 3
                        }
                    }
                },
                onHome: {
                    path.removeAll()
                    result = nil
                    onClose()
                }
            )
        } else {
            // Теоретически недостижимо: success пушится только после onSuccess.
            Color.clear.onAppear { onClose() }
        }
    }
}
