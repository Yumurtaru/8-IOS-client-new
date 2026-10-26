import Combine
import Foundation
import SwiftUI

/// Централизованный координатор навигации premium-клиента.
///
/// Зачем нужен: экраны, открытые глубоко внутри стека таба (например OrgView,
/// созданный из Home / Discover / Listing), не получают колбэков от RootTabView
/// напрямую. Cart — глобальный синглтон, поэтому и «показать корзину / чат»
/// делаем через общий синглтон-координатор (тот же паттерн `.shared`
/// + `@EnvironmentObject`, что у Cart / Session / DeepLinkRouter).
///
/// RootTabView наблюдает эти флаги и показывает флоу корзины и чат ГЛОБАЛЬНО
/// поверх активного таба. Контракт API не затрагивается — это чистый UI-слой.
final class NavCoordinator: ObservableObject {
    static let shared = NavCoordinator()
    private init() {}

    /// Показать полноэкранный флоу корзины (Корзина → Оформление → Успех).
    @Published var showCart = false

    /// Открыть чат: nil — не показывать; -1 — общий список чатов; иначе — по orderId.
    @Published var chatOrderId: Int?

    /// Заказ, который нужно открыть в табе «Заказы» (после успешного оформления,
    /// кнопка «Следить за заказом»). OrdersView наблюдает и пушит деталь у себя.
    @Published var pendingOrderDetail: Int?

    /// Организация, которую нужно открыть по slug — приходит из тапа по
    /// уведомлению «новое заведение в вашем городе» или из внешней ссылки.
    /// RootTabView показывает её поверх активного таба: у табов по одному
    /// navigationDestination (см. предупреждение в HomeView), поэтому втиснуть
    /// туда ещё один маршрут нельзя.
    @Published var pendingOrgSlug: String?

    /// Показать раздел «Жильё» (поиск → карточка объекта → мои поездки).
    /// Как и корзина, он открывается ПОВЕРХ активного таба: вход — чип «Жильё»
    /// на Главной, отдельной нижней вкладки нет (там уже пять).
    @Published var showLodging = false

    /// Открыт профиль (шторка с Главной). Пуш и ссылка раньше открывали заказ,
    /// чат или заведение ПОД этой шторкой: вкладка переключалась незаметно, а
    /// чат и обложка заведения не показывались вовсе (с вьюхи, под которой уже
    /// открыта шторка, SwiftUI второе окно не показывает). HomeView держит
    /// шторку на этом флаге, и переходы из пуша сначала её закрывают.
    @Published var profileOpen = false

    /// Товар из пуша «цена снизилась / снова в наличии» (ключ product_id без
    /// type). Раньше тап открывал приложение и ничего не показывал. Главная
    /// открывает карточку и сбрасывает значение.
    @Published var pendingProductId: Int?

    // ── Диалог конфликта корзины (single-store) ──
    /// Показать ли диалог конфликта.
    @Published var cartConflict = false
    /// Имя магазина, который сейчас в корзине (для текста диалога).
    @Published var conflictCurrentShop: String?
    /// Имя магазина, товар из которого добавляют.
    @Published var conflictNewShop: String?
    /// Действие «Очистить и начать новую» (очищает корзину и добавляет товар).
    var conflictConfirm: (() -> Void)?

    /// Попросить подтверждение при смене магазина корзины. Диалог покажет
    /// RootTabView через `.cartConflictDialog`. onConfirm выполняется по «Очистить».
    func requestCartConflict(currentShop: String?, newShop: String?, onConfirm: @escaping () -> Void) {
        conflictCurrentShop = currentShop
        conflictNewShop = newShop
        conflictConfirm = onConfirm
        cartConflict = true
    }

    /// Удобные хелперы (читабельные точки вызова из экранов).
    func openCart() { showCart = true }
    func openLodging() { showLodging = true }
    /// Слаг из ссылки или push идёт в путь запроса к API — только «правильные» символы.
    func openOrg(slug: String) {
        guard slug.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil else { return }
        // Открыты корзина или чат — сначала закрываем их: с одной вьюхи SwiftUI
        // не покажет вторую шторку, и организация из пуша не открылась бы.
        // То же с «Жильём» и профилем: ссылка или пуш при них не открывали
        // заведение, а обложка всплывала позже сама, когда человек их закрывал.
        if showCart || chatOrderId != nil || showLodging || profileOpen {
            showCart = false
            chatOrderId = nil
            showLodging = false
            profileOpen = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.pendingOrgSlug = slug
            }
        } else {
            pendingOrgSlug = slug
        }
    }
    /// Тап по push, когда поверх вкладок что-то открыто. Раньше «статус заказа»
    /// переключал вкладку «Заказы» ПОД открытой корзиной/«Жильём»/организацией —
    /// человек ничего не видел; чат не открывался из-под корзины и «Жилья» (с
    /// одной вьюхи вторую шторку SwiftUI не показывает). Сначала закрываем, потом
    /// переходим. closeAll = false — для чата: организацию не закрываем, у её
    /// обложки свой показ чата.
    func revealForPush(closeAll: Bool, then action: @escaping () -> Void) {
        let covered = showCart || showLodging || profileOpen
            || (closeAll && (pendingOrgSlug != nil || chatOrderId != nil))
        guard covered else { action(); return }
        showCart = false
        showLodging = false
        profileOpen = false
        if closeAll { pendingOrgSlug = nil; chatOrderId = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { action() }
    }
    func openChat(orderId: Int) { chatOrderId = orderId }
    func openChatList() { chatOrderId = -1 }
    func closeChat() { chatOrderId = nil }
}

/// Экран открыт внутри шторки/обложки поверх вкладок (профиль, «Жильё»).
/// Общие окна корзины и диалог «очистить корзину?» висят на корне вкладок и
/// оттуда, пока открыта шторка, не показываются: «Корзина» в заведении из
/// «Избранного» и «В корзину» с товаром другого заведения молчали. Такие
/// экраны показывают эти окна сами.
private struct YMNestedPresentationKey: EnvironmentKey {
    static let defaultValue = false
}
extension EnvironmentValues {
    var ymNestedPresentation: Bool {
        get { self[YMNestedPresentationKey.self] }
        set { self[YMNestedPresentationKey.self] = newValue }
    }
}
