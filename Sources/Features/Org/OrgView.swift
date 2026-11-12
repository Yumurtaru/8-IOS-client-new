import SwiftUI
import MapKit

//
//  OrgView.swift — карточка организации (магазин / услуга).
//  Блок: Организация + Товар/Услуга + Листинги. Дизайн 1:1 с OrgPhone.dc.html.
//
//  ПУБЛИЧНЫЕ INIT-СИГНАТУРЫ (для централизованной навигации):
//    OrgView(shop: Shop)             // из списка/карточки — есть базовые данные для hero
//    OrgView(shopSlug: String)       // из deep-link — грузим ShopDetail по slug
//
//  Экран самодостаточен: внутренний переход организация → товар/услуга
//  реализован локально через NavigationLink (флоу живёт внутри своего NavigationStack,
//  если экран открыт как корень; при пуше извне переиспользует внешний стек).
//
//  API (реальные методы старого клиента):
//    GET  api/v1/shops/{slug}            -> ShopDetail
//    GET  api/v1/shops/{slug}/products   -> [Product]
//    GET  api/v1/shops/{slug}/services   -> ServicesResponse (masters/services)
//
//  Деньги — только Decimal через Money. Мини-карта — MapKit. Токены — YM*.
//

// MARK: - ViewModel

@MainActor
final class OrgViewModel: ObservableObject {
    @Published var detail: ShopDetail?
    @Published var products: [Product] = []
    @Published var services: [ServiceItem] = []
    /// Где показывать блок услуг: "first" (до меню) или "last" (после).
    /// Значение присылает сервер — продавец задаёт его порядком категории,
    /// в которую положил услуги. До ответа — "first", как было всегда.
    @Published var servicePlacement: String = "first"
    /// Категории товаров магазина (для меню-табов и фильтра) — грузятся отдельным
    /// запросом по shopId, как на Android (Repo.categories(shopId)). НЕ путать с
    /// detail.categories (категории-теги организации).
    @Published var productCategories: [Category] = []
    @Published var loading = true
    @Published var error: String?
    /// Меню не загрузилось при загруженной карточке. Раньше ошибка глоталась
    /// (try?), и меню показывало «В этом разделе пока пусто» без «Повторить».
    @Published var productsError: String?
    @Published var productsReloading = false
    /// ♥ не сохранилось (нет связи, нужно войти, отказ сервера): раньше
    /// сердечко молча возвращалось назад — теперь причина коротким сообщением.
    @Published var favError: String?

    /// В избранном ли эта организация (синхронизируется с сервером при загрузке).
    @Published var isFav = false
    /// Флаг: isFav меняется программно (загрузка с сервера) — не слать тоггл в ответ.
    var favSyncing = false
    /// Запрос избранного ещё идёт: двойной тап по ♥ слал POST и DELETE разом,
    /// и на сервере оставалось не то, что на экране.
    var favBusy = false

    // Отзывы (грузятся в фоне для всех типов организаций).
    @Published var reviews: [Review] = []
    @Published var reviewsLoading = true
    @Published var reviewsError: String?

    /// Slug — единственный ключ загрузки (у Shop и у deep-link он общий).
    let slug: String
    /// Опорные данные для мгновенного hero до прихода detail.
    let seed: Shop?

    /// Догрузка остальных страниц меню: хранится, чтобы отменяться при перезагрузке и уходе.
    private var menuTask: Task<Void, Never>?
    deinit { menuTask?.cancel() }

    init(shop: Shop) { self.slug = shop.slug ?? ""; self.seed = shop }
    init(shopSlug: String) { self.slug = shopSlug; self.seed = nil }

    /// Услуга ли это. Приоритет — серверный признак `mode == "service"` (как на Android);
    /// фолбэк на эвристику (есть услуги и нет товаров) — на случай старого ответа без `mode`.
    var isService: Bool {
        if let m = detail?.mode?.lowercased() { return m == "service" }
        if let sm = seed?.shopMode?.lowercased() { return sm == "service" }
        return !services.isEmpty && products.isEmpty
    }

    func load() async {
        guard !slug.isEmpty else { error = "Нет данных заведения"; loading = false; return }
        loading = true; error = nil
        do {
            async let d: ShopDetail = API.shared.get("api/v1/shops/\(slug)")
            // Меню целиком, со всех страниц (см. fetchShopMenu).
            // Первая страница — сразу (карточка не ждёт всё меню), остальные — в фоне.
            async let p = fetchShopMenu(slug: slug, pages: 1...1)
            detail = try await d
            // Spotlight и воронка: заведение открыто.
            SpotlightIndex.indexOrg(slug: detail?.slug ?? slug, name: detail?.name, about: detail?.description)
            Track.shopOpened(slug: slug, name: detail?.name)
            do {
                let first = try await p
                products = first.items
                productsError = nil
                if first.hasMore {
                    let s = slug
                    menuTask?.cancel()
                    menuTask = Task { @MainActor [weak self] in
                        // Остальные страницы: при сбое — ещё одна попытка через 2 с, иначе
                        // всё после первых 200 позиций молча пропадало до перезахода.
                        var rest: (items: [Product], hasMore: Bool)? = try? await fetchShopMenu(slug: s, pages: 2...20)
                        if rest == nil, !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            rest = try? await fetchShopMenu(slug: s, pages: 2...20)
                        }
                        guard !Task.isCancelled, let self, let rest else { return }
                        let known = Set(self.products.map(\.id))
                        self.products += rest.items.filter { !known.contains($0.id) }
                    }
                }
            } catch is CancellationError {
            } catch {
                productsError = error.localizedDescription
            }
        } catch is CancellationError {
            // отмена — молча
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        // Категории товаров магазина: отдельный запрос по shopId (паритет с Android
        // Repo.categories(shopId)). GET api/v1/categories?shop_id=<id> -> [Category].
        // Нужны для меню-табов и фильтра filteredProducts (product.categoryId == cat.id).
        if let shopId = detail?.id {
            Task { @MainActor in
                if let cats: [Category] = try? await API.shared.list("api/v1/categories", query: ["shop_id": String(shopId)]) {
                    productCategories = cats
                }
            }
        }
        // Услуги догружаем в фоне (нужны только для фолбэк-эвристики isService).
        Task { @MainActor in
            if let r: ServicesResponse = try? await API.shared.get("api/v1/shops/\(slug)/services") {
                services = r.services ?? []
                // Пустой список — блок всё равно скрыт, положение не важно.
                if !services.isEmpty { servicePlacement = r.placement ?? "first" }
            }
        }
        // Избранное организации — в фоне (сердечко станет красным, если она уже в избранном).
        Task { @MainActor in await loadFavState() }
        // Отзывы — в фоне, не задерживая показ карточки.
        Task { @MainActor in await loadReviews() }
    }

    /// «Повторить» под меню, когда карточка загрузилась, а меню — нет.
    func reloadProducts() async {
        guard !productsReloading else { return }
        productsReloading = true
        do {
            products = try await fetchShopMenu(slug: slug).items
            productsError = nil
        } catch is CancellationError {
        } catch {
            productsError = error.localizedDescription
        }
        productsReloading = false
    }

    /// Синхронизация состояния избранного с сервером. Тот же механизм, что в DiscoverView:
    /// GET api/v1/favorites -> [Shop], isFav = содержит ли этот shop.id.
    func loadFavState() async {
        guard let shopId = detail?.id else { return }
        if let favs: [Shop] = try? await API.shared.list("api/v1/favorites") {
            let fav = favs.contains { $0.id == shopId }
            // Программная установка: onChange увидит favSyncing == true и не пошлёт тоггл.
            favSyncing = true
            isFav = fav
            DispatchQueue.main.async { self.favSyncing = false }
        }
    }

    /// Оптимистичный тоггл избранного: POST api/v1/favorites/{id} (добавить) /
    /// DELETE api/v1/favorites/{id} (убрать). Откат при ошибке. isFav уже переключён биндингом.
    func toggleFav() async {
        guard !favSyncing, let shopId = detail?.id else { return }
        let on = isFav
        // Пока запрос идёт, новые тапы по ♥ игнорируются (см. биндинг в OrgView).
        favBusy = true
        defer { favBusy = false }
        do {
            if on { try await API.shared.postVoid("api/v1/favorites/\(shopId)") }
            else  { try await API.shared.deleteVoid("api/v1/favorites/\(shopId)") }
        } catch {
            // Откат — программной установкой: иначе onChange(of: vm.isFav) снова
            // вызывал toggleFav, и у гостя/без сети запросы шли по кругу.
            favSyncing = true
            isFav.toggle()   // откат
            DispatchQueue.main.async { self.favSyncing = false }
            favError = error.userMessage
        }
    }

    /// Отзывы заведения: GET api/v1/shops/{slug}/reviews -> [Review].
    func loadReviews() async {
        guard !slug.isEmpty else { reviewsLoading = false; return }
        reviewsLoading = true; reviewsError = nil
        do {
            reviews = try await API.shared.list("api/v1/shops/\(slug)/reviews")
        } catch is CancellationError {
        } catch {
            reviewsError = error.localizedDescription
        }
        reviewsLoading = false
    }
}

/// Меню заведения целиком. GET api/v1/shops/{slug}/products отдаёт страницами
/// (meta.has_more, справка), а карточка заведения брала только первую — у
/// большого меню хвост позиций просто не показывался.
/// Страницы по 200 (П-23.4: page + per_page). Дубли по id
/// отбрасываем; страница без новых позиций — конец (сервер не знает page);
/// не больше 20 страниц. Сбой догрузки не прячет уже полученное.
func fetchShopMenu(slug: String, pages: ClosedRange<Int> = 1...20) async throws -> (items: [Product], hasMore: Bool) {
    var all: [Product] = []
    var seen = Set<Int>()
    var page = pages.lowerBound
    var more = false
    while true {
        // П-23.4: страницы по 200 (максимум сервера) и догрузка по has_more:
        // первая страница большого меню приходит быстро, остальное — в фоне.
        // Без параметров сервер отдаёт всё одним куском (до 2000) — так было раньше.
        var q: [String: String] = ["per_page": "200"]
        q["page"] = String(page)
        let p: Page<Product>
        do {
            p = try await API.shared.page("api/v1/shops/\(slug)/products", query: q)
        } catch {
            if page == pages.lowerBound || error is CancellationError { throw error }
            break
        }
        let fresh = p.items.filter { seen.insert($0.id).inserted }
        all += fresh
        more = p.hasMore && !fresh.isEmpty
        guard more, page < pages.upperBound else { break }
        page += 1
    }
    let snapshot = all   // var в @Sendable-замыкании MainActor.run — ошибка компиляции; берём копию
    await MainActor.run { CartV2Menu.remember(slug: slug, items: snapshot) }
    return (all, more)
}

// MARK: - OrgView

struct OrgView: View {
    @StateObject private var vm: OrgViewModel
    @StateObject private var cart = Cart.shared
    @EnvironmentObject private var coord: NavCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeCat: Int = 0
    /// Открытая подборка (лист поверх заведения).
    @State private var activePick: QuickPick?
    @State private var pushedProduct: Int?
    @State private var pushedService: ServiceItem?
    @State private var showAuth = false
    /// Этап 4: «+» в плитке — товар, по которому идёт проверка/добавление (индикатор в кнопке).
    @State private var quickBusy: Int?
    @State private var localConflict = false
    @State private var quickPending: ProductDetail?
    @State private var quickTask: Task<Void, Never>?

    /// «+» в плитке: товар без обязательного выбора — сразу в корзину, с выбором — карточка.
    /// Закрыто/пауза/корзина заперта неотвеченным заказом/идёт другой запрос — карточка, как раньше.
    private func onTilePlus(_ p: Product) {
        if quickBusy != nil { return }
        guard vm.detail != nil, isOpen, !isPaused, !Cart.shared.checkLocked() else { openProduct(p.id); return }
        quickBusy = p.id
        quickTask = Task { @MainActor in
            let needs = await QuickAdd.needsCard(p)
            if Task.isCancelled { quickBusy = nil; return }
            if needs == false, let d = await QuickAdd.detail(p.id) {
                if Task.isCancelled { quickBusy = nil; return }
                addQuick(d)
            } else { openProduct(p.id) }
            quickBusy = nil
        }
    }

    /// Тот же путь, что у кнопки «В корзину» на экране товара (ProductView.addToCart/commitAdd):
    /// инвариант «одна корзина = один магазин» с общим диалогом конфликта.
    private func addQuick(_ d: ProductDetail) {
        let newShopId = d.shopId ?? 0
        if let cur = cart.shopId, cur != newShopId, !cart.isEmpty {
            if nested { quickPending = d; localConflict = true; return }
            coord.requestCartConflict(currentShop: cart.shopName, newShop: d.shopName,
                                      onConfirm: { commitQuick(d) })
            return
        }
        commitQuick(d)
    }

    private func commitQuick(_ d: ProductDetail) {
        let ok = Cart.shared.add(product: d, modifierIds: [], options: [],
                                 shopId: d.shopId ?? 0, shopName: d.shopName,
                                 qty: 1)
        if ok { Haptics.success() } else { Haptics.warning(); openProduct(d.id) }
    }

    /// Открыть товар как go() на Главной: если экран товара сняли, не вызвав
    /// сеттер (тап по вкладке, программный возврат), pushedProduct «висел», и
    /// тап по блюду ничего не открывал. Сначала сбрасываем, потом идём.
    private func openProduct(_ id: Int) {
        // Лист подборки закрываем до перехода, иначе экран товара откроется под ним.
        if activePick != nil {
            activePick = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openProduct(id) }
            return
        }
        if pushedProduct == nil && pushedService == nil { pushedProduct = id; return }
        pushedProduct = nil; pushedService = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { pushedProduct = id }
    }
    /// Заведение открыто внутри шторки профиля («Избранное») или «Жилья»: общие
    /// корзина и чат висят на корне вкладок и оттуда сейчас не покажутся —
    /// «Корзина» и 💬 раньше молчали. Тогда показываем их отсюда.
    @Environment(\.ymNestedPresentation) private var nested
    @State private var localCart = false
    @State private var localChat = false
    /// Кнопка «Наверх»: прокручено дальше экрана / счётчик нажатий.
    @State private var showTop = false
    @State private var topTick = 0

    private let heroHeight: CGFloat = 308
    /// «Дыхание» обложки (этап 12): включается один раз, анимация автоповтором.
    @State private var coverBreath = false

    init(shop: Shop) { _vm = StateObject(wrappedValue: OrgViewModel(shop: shop)) }
    init(shopSlug: String) { _vm = StateObject(wrappedValue: OrgViewModel(shopSlug: shopSlug)) }

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            if vm.loading && vm.detail == nil {
                loadingState
            } else if let e = vm.error, vm.detail == nil {
                errorState(e)
            } else {
                content
                // Липкая корзина + чат-FAB поверх контента.
                bottomBar
            }

            topControls
        }
        .navigationBarHidden(true)
        .onAppear {
            guard !reduceMotion, !coverBreath else { return }
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { coverBreath = true }
        }
        // Причина отказа ♥ — над липкой корзиной.
        .errorToast($vm.favError, bottom: 96)
        .cartConflictDialog(
            isPresented: $localConflict,
            currentShop: cart.shopName,
            newShop: quickPending?.shopName,
            onConfirm: { if let d = quickPending { commitQuick(d) } }
        )
        .onDisappear { quickTask?.cancel(); quickTask = nil; quickBusy = nil }
        .task { if vm.detail == nil { await vm.load() } }
        // Внутренние переходы флоу (организация → товар / услуга).
        // ОДИН navigationDestination на экран. Раньше их было два подряд —
        // SwiftUI оставляет в силе только один, а второй перестаёт закрываться
        // при возврате: его @State так и остаётся заполненным. Дальше любая
        // перерисовка экрана (например, переключение сегмента) снова видела
        // «есть куда переходить» и толкала предыдущий экран. Отсюда и брался
        // переход в первую организацию при нажатии на «Товары».
        // Сеттер гасит ОБА состояния — после возврата не остаётся хвостов.
        .navigationDestination(isPresented: Binding(
            get: { pushedProduct != nil || pushedService != nil },
            set: { if !$0 { pushedProduct = nil; pushedService = nil } }
        )) {
            if let id = pushedProduct { ProductView(id: id) }
            else if let s = pushedService { ProductView(service: s, shopName: vm.detail?.name) }
        }
        // Вход для гостя при попытке записи на услугу (self-contained шит).
        .sheet(isPresented: $showAuth) {
            AuthView { showAuth = false }
                .environmentObject(Session.shared)
        }
    }

    // MARK: Content (parallax hero + sheet)

    private var content: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(spacing: 0) {
                // Параллакс-hero: тянется при оттягивании вниз, уезжает вверх при скролле.
                GeometryReader { geo in
                    let minY = geo.frame(in: .named("scroll")).minY
                    let stretch = max(0, minY)
                    // Этап 12 (ТЗ 5.3): видео-обложка без звука по кругу, если оно есть в данных;
                    // иначе фото с «дыханием» (scale 1.0 -> 1.06, 12 с). Reduce Motion — без движения.
                    Group {
                        if let v = coverVideoURL, !reduceMotion {
                            CoverVideoView(url: v)
                        } else {
                            PhotoPlaceholder(
                                url: API.imageURL(vm.detail?.cover ?? vm.detail?.banner ?? seedCover),
                                // Подпись видна, когда у заведения нет обложки: служебное
                                // «· ПАРАЛЛАКС» из макета человеку не показываем.
                                label: "ОБЛОЖКА",
                                radius: 0, tone: 0,
                                maxPixel: 2000
                            )
                            .scaleEffect(coverBreath ? 1.06 : 1.0)
                        }
                    }
                    .frame(width: geo.size.width, height: heroHeight + stretch)
                    .clipped()
                    .overlay(alignment: .bottomLeading) {
                        if let t = serviceTimeText {
                            Text(t)
                                .ymText(YMText.badge)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.black.opacity(0.45), in: Capsule())
                                .padding(.leading, YMSpace.xl)
                                .padding(.bottom, 52)
                        }
                    }
                    .overlay(
                        // Градиент-фейд к фону снизу.
                        LinearGradient(
                            colors: [.clear, .clear, YMColor.bg],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .offset(y: reduceMotion ? -min(0, minY) : (minY > 0 ? -minY : -minY * 0.5))
                }
                .frame(height: heroHeight)
                .id("orgTop")

                sheet
                    .padding(.top, -34)   // sheet поднимается на hero (нахлёст r28)
            }
            .ymTrackScrollFar(space: "scroll", isFar: $showTop)
        }
        .coordinateSpace(name: "scroll")
        .ignoresSafeArea(edges: .top)
        .onChange(of: topTick) { _ in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.4)) { proxy.scrollTo("orgTop", anchor: .top) }
        }
        }
    }

    /// Видео-обложка: в данных заведения поля с видео пока нет, поэтому nil и работает фото.
    /// Когда сервер начнёт отдавать ссылку, подставить её сюда (плеер уже готов).
    private var coverVideoURL: URL? { nil }

    /// Плашка на обложке: «Доставка от N минут» / «Самовывоз от N минут» — только если данные есть.
    private var serviceTimeText: String? {
        let methods = vm.detail?.fulfillment ?? vm.seed?.fulfillment ?? []
        let zoneMin = (vm.detail?.deliveryZones ?? []).compactMap { $0.deliveryTimeMin }.filter { $0 > 0 }.min()
        if methods.contains("delivery"), let m = zoneMin { return "Доставка от \(m) минут" }
        let cook = vm.detail?.avgCookTime ?? vm.seed?.avgCookTime
        if methods.contains("pickup"), let m = cook, m > 0 { return "Самовывоз от \(m) минут" }
        return nil
    }

    private var seedCover: String? { vm.seed?.cover ?? vm.seed?.banner ?? vm.seed?.logo }

    /// «отзыв / отзыва / отзывов». Паритет с Android и с секцией «Отзывы»
    /// ниже: одно и то же reviews_count на экране называлось и «оценками», и «отзывами».
    private static func ratingsWord(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "отзыв" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "отзыва" }
        return "отзывов"
    }

    // MARK: Sheet (поднятая шторка r28)

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Хедер: логотип 72×72 r20 слева, название + статус — рядом справа.
            HStack(alignment: .center, spacing: 14) {
                PhotoPlaceholder(url: API.imageURL(vm.detail?.logo ?? vm.seed?.logo),
                                 label: "ЛОГО", radius: 20, tone: 1)
                    .frame(width: 72, height: 72)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.15), radius: 10, y: 4)

                // Название 25/heavy + бейдж «Открыто» — справа от логотипа.
                VStack(alignment: .leading, spacing: 8) {
                    Text(vm.detail?.name ?? vm.seed?.name ?? "—")
                        .ymFont(25, weight: .heavy)
                        .foregroundStyle(YMColor.text)
                        .lineLimit(2)
                    // Пауза приёма (сервер А719): is_open уже false, но «Закрыто» неверно —
                    // заведение работает, просто не берёт заказы.
                    StatusPill(text: isPaused ? "На паузе" : (isOpen ? "Открыто" : "Закрыто"),
                               kind: (isOpen && !isPaused) ? .open : .cancel, solid: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 20)

            // Пауза приёма: вместо «Сейчас закрыто» и предзаказа — плашка с текстом сервера
            // и причиной; предзаказ при паузе сервер тоже отклонит (409 paused).
            if isPaused, let d = vm.detail {
                ShopPauseBanner(title: ShopPause.title(statusText: d.statusText, until: d.pauseUntil, untilTs: d.pauseUntilTs),
                                reason: ShopPause.reason(d.pauseReason))
                    .padding(.top, 12)
            }
            // Баннер нерабочего времени: «Сейчас закрыто. Откроется <день> в <время>».
            // Корзину собрать можно, оформить — предзаказом ко времени работы.
            else if !isOpen {
                ClosedBanner(opensLabel: OrgHours.nextOpenLabel(vm.detail?.hours, tz: ShopTime.zone(vm.detail?.timezone)), preorder: !vm.isService)
                    .padding(.top, 12)
            }

            // Подзаголовок «Тип · кухня · теги».
            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .ymFont(13.5)
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 6)
            }
            // Паритет с Android: описание, которое продавец написал о заведении,
            // iOS не показывал нигде.
            if let about = vm.detail?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !about.isEmpty {
                Text(about)
                    .ymFont(13.5)
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 6)
            }

            // ★рейтинг · оценки · время.
            HStack(spacing: 12) {
                if let r = rating, r > 0 {
                    HStack(spacing: 5) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                        // Счёт из карточки (у входа по ссылке/push seed нет) и со
                        // склонением: было «1 оценок», «3 оценок».
                        if let rc = vm.detail?.reviewsCount ?? vm.seed?.reviewsCount, rc > 0 {
                            Text("· \(rc) \(Self.ratingsWord(rc))").foregroundStyle(YMColor.muted)
                        }
                    }
                    .ymFont(13.5, weight: .semibold)
                }
                if let t = deliveryTime, !t.isEmpty {
                    HStack(spacing: 4) {
                        Text("🕑")
                        Text(t).foregroundStyle(YMColor.muted)
                    }
                    .ymFont(13.5)
                }
            }
            .padding(.top, 10)

            // Способ получения (Доставка/Самовывоз/За столик) выбирается на оформлении,
            // на странице организации сегмент не показываем.

            // Карточка адреса + мини-карта + маршрут.
            addressCard
                .padding(.top, 16)

            // Лицензия — для медцентров, стоматологий, аптек, ветклиник, автошкол.
            licenseCard

            // Услуга (запись) или меню. У ресторана и магазина — И меню, И блок
            // броней: кроме еды и товаров бывает игровой зал, кинозал, бильярд,
            // дорожка — их бронируют на время, а не кладут в корзину. Если услуг
            // нет, блок сам ничего не рисует (hideWhenEmpty), и витрина прежняя.
            if vm.isService {
                OrgBookingSection(slug: vm.slug, detail: vm.detail) { showAuth = true }
                    .padding(.top, 20)
                // Паритет с Android: товары у организации услуг (салон продаёт
                // косметику) показываем под записью. Нет товаров — блока нет.
                if !vm.products.isEmpty {
                    menuSection.padding(.top, 20)
                }
            } else if vm.servicePlacement == "last" {
                // Продавец положил услуги в категорию НИЖЕ первой категории
                // меню: сначала еда, потом бронь игрового зала.
                menuSection.padding(.top, 20)
                OrgBookingSection(
                    slug: vm.slug, detail: vm.detail,
                    onNeedAuth: { showAuth = true },
                    serviceOrg: false, hideWhenEmpty: true
                )
                .padding(.top, vm.services.isEmpty ? 0 : 20)
            } else {
                // Как было всегда: блок услуг над меню.
                // Отступ только при непустом списке: при hideWhenEmpty блок
                // схлопывается в нулевую высоту, но родительский padding
                // остался бы пустой полосой над меню.
                OrgBookingSection(
                    slug: vm.slug, detail: vm.detail,
                    onNeedAuth: { showAuth = true },
                    serviceOrg: false, hideWhenEmpty: true
                )
                .padding(.top, vm.services.isEmpty ? 0 : 20)
                menuSection.padding(.top, 20)
            }

            // Отзывы — для всех типов организаций. Сводка нажимаема → полный экран ReviewsScreen.
            OrgReviewsSection(
                slug: vm.slug,
                reviews: vm.reviews,
                loading: vm.reviewsLoading,
                error: vm.reviewsError,
                avgRating: rating,
                reviewsCount: vm.detail?.reviewsCount ?? vm.seed?.reviewsCount,
                // Отзывы не загрузились — повтор прямо здесь.
                onRetry: { Task { await vm.loadReviews() } }
            )
            .padding(.top, 20)

            // Отступ под липкую корзину + FAB.
            Color.clear.frame(height: cart.count > 0 ? 150 : 96)
        }
        .padding(.horizontal, YMSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            YMColor.bg
                .clipShape(RoundedRectangle(cornerRadius: YMForm.sheetRadius, style: .continuous))
        )
    }

    // MARK: Лицензия

    /// Номер лицензии и дата выдачи. Показываем, если организация в
    /// лицензируемой категории (requires_license) либо реквизиты уже
    /// опубликованы. Пустую карточку «Лицензия: —» не рисуем: лучше ничего,
    /// чем строка без данных.
    @ViewBuilder private var licenseCard: some View {
        let needs = (vm.detail?.requiresLicense ?? false)
            || (vm.detail?.categories ?? []).contains { $0.requiresLicense == true }
        if let lic = vm.detail?.license, let number = lic.number, !number.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(YMColor.accent)
                    Text(lic.title?.isEmpty == false ? lic.title! : "Лицензия")
                        .font(YMFont.title3).foregroundStyle(YMColor.text)
                }
                Text("№ \(number)" + (licDate(lic.issuedAt).map { " от \($0)" } ?? ""))
                    .font(YMFont.styled(.body, .semibold)).foregroundStyle(YMColor.text)
                if let by = lic.issuedBy, !by.isEmpty {
                    Text("Выдана: \(by)").font(YMFont.callout).foregroundStyle(YMColor.muted)
                }
                if let until = licDate(lic.validUntil) {
                    Text("Действует до \(until)").font(YMFont.callout).foregroundStyle(YMColor.muted)
                }
                if let cat = lic.category, !cat.isEmpty {
                    Text(cat).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.lg)
            .ymCard(radius: YMRadius.card)
            .padding(.top, 16)
        } else if needs {
            Text("Реквизиты лицензии ещё не опубликованы организацией.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(YMSpace.lg)
                .ymCard(radius: YMRadius.card)
                .padding(.top, 16)
        }
    }

    /// «2026-09-13» → «13.09.2026». Пустое и неожиданное отдаём как nil.
    private func licDate(_ iso: String?) -> String? {
        guard let iso = iso, iso.count >= 10 else { return nil }
        let p = iso.prefix(10).split(separator: "-")
        guard p.count == 3 else { return nil }
        return "\(p[2]).\(p[1]).\(p[0])"
    }

    // MARK: Address card + mini-map

    private var addressCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Мини-карта: золотой пин по lat/lng.
            // Координаты продавец вводит сам, сервер диапазон не проверяет: широта 555
            // давала MapKit «Invalid Region» и закрывала приложение. Неверные — без карты.
            if let lat = vm.detail?.lat, let lng = vm.detail?.lng,
               CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lng)) {
                OrgMiniMap(lat: lat, lng: lng)
                    .frame(height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            }
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "mappin.and.ellipse")
                    .ymIcon(18, weight: .semibold)
                    .foregroundStyle(YMColor.accent)
                VStack(alignment: .leading, spacing: 3) {
                    // Пустой адрес из карточки («») давал пустую строку рядом с пином.
                    Text(vm.detail?.address?.isEmpty == false ? (vm.detail?.address ?? "") : "Адрес уточняется")
                        .ymFont(14.5, weight: .semibold)
                        .foregroundStyle(YMColor.text)
                    if let city = vm.seed?.category { // fallback; при наличии дистанции — покажется тут
                        Text(city)
                            .ymFont(12)
                            .foregroundStyle(YMColor.muted)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    Haptics.light()
                    openRoute()
                } label: {
                    Text("↗ Маршрут")
                        .ymFont(12.5, weight: .bold)
                        .foregroundStyle(YMColor.onAccent)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(YMColor.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(vm.detail?.lat == nil && (vm.detail?.address?.isEmpty ?? true))
            }
            .padding(14)
        }
        .background(YMColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // MARK: Menu (магазин)

    private var menuSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Быстрые подборки (этап 12): только признаки, реально есть в меню.
            QuickPicksRow(products: vm.products, active: $activePick) { p in
                ProductTile(
                    product: p,
                    line: simpleLine(p.id),
                    busy: quickBusy == p.id,
                    reduceMotion: reduceMotion,
                    onOpen: { Haptics.light(); openProduct(p.id) },
                    onPlus: { Haptics.light(); onTilePlus(p) },
                    onMinus: { if let l = simpleLine(p.id) { cart.dec(l.key) } },
                    onInc: { if let l = simpleLine(p.id) { cart.inc(l.key) } }
                )
            }
            .padding(.bottom, 14)

            // Липкая навигация по разделам меню — золотое подчёркивание активного.
            if !categories.isEmpty {
                // Лента-капсула (редизайн): серая рамка, активная вкладка — белая капсула.
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            catTab("Популярное", 0)
                            ForEach(categories) { c in catTab(c.name ?? "—", c.id) }
                        }
                        .padding(4)
                    }
                    .background(YMUi.segmentBg, in: Capsule())
                    .onChange(of: activeCat) { id in
                        withAnimation(YMMotion.adaptive(.easeInOut(duration: YMDur.tabSwitch), reduceMotion: reduceMotion)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            let shown = shownProducts
            LazyVStack(spacing: YMForm.cardGap) {
                if !shown.isEmpty {
                    // Заголовок раздела — по центру (ТЗ 5.3).
                    Text(activeCat == 0 ? "Популярное" : (categories.first { $0.id == activeCat }?.name ?? "Меню"))
                        .ymText(YMText.sectionTitle)
                        .foregroundStyle(YMUi.text)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 20).padding(.bottom, 10 - YMForm.cardGap)
                }
                // Сетка в два столбца (ТЗ 5.4): строки по 2 внутри той же ленивой колонки.
                // Раздел по-прежнему выбирается через activeCat -> shownProducts: якорей нет, id не меняются.
                ForEach(menuRows(shown)) { row in
                    HStack(alignment: .top, spacing: YMForm.cardGap) {
                        ForEach(row.items) { p in
                            ProductTile(
                                product: p,
                                line: simpleLine(p.id),
                                busy: quickBusy == p.id,
                                reduceMotion: reduceMotion,
                                onOpen: { Haptics.light(); openProduct(p.id) },
                                onPlus: { Haptics.light(); onTilePlus(p) },
                                onMinus: { if let l = simpleLine(p.id) { cart.dec(l.key) } },
                                onInc: { if let l = simpleLine(p.id) { cart.inc(l.key) } }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if row.items.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    // Поля экрана 16 (лист заведения даёт 20).
                    .padding(.horizontal, YMForm.screenPadding - YMSpace.xl)
                }
                if shown.isEmpty, vm.products.isEmpty, let pe = vm.productsError {
                    // Меню не загрузилось — это не «пусто»: даём повторить.
                    VStack(spacing: YMSpace.sm) {
                        Text("Не удалось загрузить меню: \(pe)")
                            .font(YMFont.callout)
                            .foregroundStyle(YMColor.muted)
                            .multilineTextAlignment(.center)
                        if vm.productsReloading {
                            ProgressView().tint(YMColor.accent)
                        } else {
                            Button("Повторить") { Task { await vm.reloadProducts() } }
                                .buttonStyle(YMSecondaryButtonStyle())
                                .frame(maxWidth: 200)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else if shown.isEmpty {
                    Text("В этом разделе пока пусто")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                }
            }
            .padding(.top, 12)
        }
    }

    // MARK: Category tab (золотое подчёркивание)

    @Namespace private var catNS

    private func catTab(_ title: String, _ id: Int) -> some View {
        let active = activeCat == id
        return Button {
            Haptics.selection()
            withAnimation(YMMotion.adaptive(.easeInOut(duration: YMDur.tabSwitch), reduceMotion: reduceMotion)) { activeCat = id }
        } label: {
            Text(title)
                .font(.custom(YMFont.golosName(active ? .heavy : .semibold), fixedSize: 14.5))
                .foregroundStyle(active ? YMUi.text : YMUi.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                    if active {
                        Capsule().fill(YMUi.segmentSelected)
                            .shadow(color: .black.opacity(0.10), radius: 3, y: 1)
                            .matchedGeometryEffect(id: "catTabBg", in: catNS)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .id(id)
    }

    // MARK: Top controls (‹ ↗ ♡)

    private var topControls: some View {
        HStack {
            circleControl("chevron.left") { Haptics.light(); dismiss() }
            Spacer()
            HStack(spacing: 10) {
                circleControl("square.and.arrow.up") { share() }
                // Избранное организации — красное сердечко (heart.fill, YMColor.statusCancel).
                // Гостю — сначала вход: раньше сердечко загоралось, запрос получал
                // 401 и молча гасло обратно, без объяснения.
                HeartButton(isFav: Binding(
                    get: { vm.isFav },
                    set: { v in
                        if !Session.shared.isLoggedIn { showAuth = true } else if !vm.favBusy { vm.isFav = v }
                    }
                ), size: 38, favColor: YMColor.statusCancel)
                    .onChange(of: vm.isFav) { _ in Task { await vm.toggleFav() } }
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 8)
    }

    private func circleControl(_ system: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .ymIcon(16, weight: .semibold)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Color.black.opacity(0.4), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Bottom bar (StickyCartBar + чат-FAB)

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Spacer()
            // Чат-FAB над корзиной.
            HStack {
                Spacer()
                Button {
                    Haptics.light()
                    // Чат в этом API привязан к заказу — из карточки организации
                    // открываем общий список чатов (диалоги по заказам заведения).
                    if nested { localChat = true } else { coord.openChatList() }
                } label: {
                    Text("💬")
                        .ymFont(22)
                        .frame(width: 52, height: 52)
                        .background(YMColor.surface, in: Circle())
                        .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
                        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, YMSpace.xl)

            // Плавающая корзина-пилюля по центру; «Наверх» справа на её линии (ниже чат-FAB).
            let narrow = UIScreen.main.bounds.width < 360
            VStack(alignment: .trailing, spacing: 12) {
                if showTop && narrow {
                    // Узкий экран: «Наверх» над пилюлей, как чат.
                    ScrollTopButton { topTick += 1 }
                        .padding(.trailing, YMSpace.xl)
                        .transition(.opacity)
                }
            ZStack(alignment: .trailing) {
                if cart.count > 0 {
                    StickyCartBar(count: cart.count, total: cart.total, lines: cart.lines) {
                        // Открыть глобальный флоу корзины (Корзина → Оформление → Успех).
                        if nested { localCart = true } else { coord.openCart() }
                    }
                    .frame(maxWidth: .infinity)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
                if showTop && !narrow {
                    ScrollTopButton { topTick += 1 }
                        .padding(.trailing, YMSpace.xl)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity)
            }
            .padding(.bottom, 8)
            .animation(reduceMotion ? nil : .easeOut(duration: YMDur.floatingCart), value: cart.count > 0)
            .animation(reduceMotion ? nil : .easeOut(duration: YMDur.floatingCart), value: showTop)
        }
        // Корзина и чаты, когда заведение открыто в шторке (см. nested).
        // Висят на нижней панели, а не на корне: там уже шторка входа.
        .fullScreenCover(isPresented: $localCart) {
            CartFlow(
                onClose: { localCart = false },
                onTrackOrder: { id in
                    localCart = false
                    // Заказ — во вкладке «Заказы»: шторку профиля/«Жильё» закрываем.
                    coord.revealForPush(closeAll: true) { coord.pendingOrderDetail = id }
                }
            )
            .environmentObject(Cart.shared)
            .environmentObject(DeepLinkRouter.shared)
            .environmentObject(coord)
            .environmentObject(Session.shared)
        }
        .sheet(isPresented: $localChat) {
            NavigationStack {
                ChatView.list
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Закрыть") { localChat = false }
                        }
                    }
            }
            .environmentObject(Session.shared)
        }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 16) {
            SkeletonBox(radius: 0).frame(height: heroHeight).ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBox().frame(width: 72, height: 72)
                SkeletonBox().frame(width: 180, height: 24)
                SkeletonBox().frame(width: 240, height: 14)
                ForEach(0..<3, id: \.self) { _ in
                    SkeletonBox(radius: YMRadius.card).frame(height: 96)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            Spacer()
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "wifi.exclamationmark")
                .ymIcon(34, weight: .semibold)
                .foregroundStyle(YMColor.muted)
            Text(message)
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await vm.load() } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
    }

    // MARK: Derived

    /// Пауза приёма заведения (поле карточки; нет ключа — не пауза).
    private var isPaused: Bool { ShopPause.isPaused(vm.detail?.paused) }

    /// Открыто ли сейчас.
    ///
    /// Приоритет — ответ СЕРВЕРА (`is_open` в карточке и в списке): часы работы
    /// заданы временем заведения, а расчёт на телефоне идёт по его часовому
    /// поясу. Покупатель из Владивостока видел «Закрыто» у работающего
    /// московского заведения, а из Калининграда — «Открыто» у закрытого.
    /// Локальный расчёт остаётся запасным путём для старого сервера.
    private var isOpen: Bool {
        if let srv = vm.detail?.isOpen { return srv }
        if let srv = vm.seed?.isOpen { return srv }
        if let d = vm.detail, let computed = OrgHours.isOpenNow(d.hours, tz: ShopTime.zone(d.timezone)) { return computed }
        return true
    }
    private var rating: Double? { vm.detail?.rating ?? vm.seed?.rating }
    /// delivery_time сервер не отдаёт. Паритет с Android: время приготовления
    /// из avg_cook_time «25–35 мин» — из карточки, а без неё — из списка.
    private var deliveryTime: String? {
        if let t = vm.detail?.deliveryTime ?? vm.seed?.deliveryTime, !t.isEmpty { return t }
        guard let m = vm.detail?.avgCookTime ?? vm.seed?.avgCookTime, m > 0 else { return nil }
        return "\(m)–\(m + 10) мин"
    }
    private var subtitle: String? {
        // «Тип · кухня · теги» — из категории Shop / категорий ShopDetail.
        var parts: [String] = []
        if let cat = vm.seed?.category, !cat.isEmpty { parts.append(cat) }
        if let cats = vm.detail?.categories, !cats.isEmpty {
            parts.append(cats.prefix(2).compactMap { $0.name }.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// Категории для меню-табов — КАТЕГОРИИ ТОВАРОВ магазина (по shopId), а не
    /// теги-категории организации (detail.categories). Их id совпадают с product.categoryId.
    /// Паритет с Android: раздел без товаров не показываем — вкладка открывала
    /// «В этом разделе пока пусто» (подкатегории, скрытые позиции).
    private var categories: [Category] {
        let used = Set(vm.products.compactMap { $0.categoryId })
        return vm.productCategories.filter { used.contains($0.id) }
    }

    private struct MenuRow: Identifiable { let id: Int; let items: [Product] }
    private func menuRows(_ list: [Product]) -> [MenuRow] {
        stride(from: 0, to: list.count, by: 2).map { i in
            let items = Array(list[i..<min(i + 2, list.count)])
            return MenuRow(id: items[0].id, items: items)
        }
    }
    /// Простая строка корзины: тот же товар без добавок.
    private func simpleLine(_ productId: Int) -> CartLine? {
        cart.lines.first { $0.productId == productId && $0.modifierIds.isEmpty }
    }

    private var shownProducts: [Product] {
        activeCat == 0 ? vm.products : vm.products.filter { $0.categoryId == activeCat }
    }

    // MARK: Actions

    /// Deep-link в Яндекс.Карты с fallback на web.
    private func openRoute() {
        guard let lat = vm.detail?.lat, let lng = vm.detail?.lng else {
            // Fallback по адресу-строке.
            let addr = vm.detail?.address ?? vm.detail?.name ?? ""
            let q = addr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let web = URL(string: "https://yandex.ru/maps/?text=\(q)") { openURL(web) }
            return
        }
        let appURL = URL(string: "yandexmaps://build_route_on_map/?lat_to=\(lat)&lon_to=\(lng)")
        let webURL = URL(string: "https://yandex.ru/maps/?rtext=~\(lat),\(lng)&rtt=auto")
        if let app = appURL {
            UIApplication.shared.open(app, options: [:]) { ok in
                if !ok, let web = webURL { openURL(web) }
            }
        } else if let web = webURL {
            openURL(web)
        }
    }

    private func share() {
        Haptics.light()
        guard let slug = vm.detail?.slug ?? vm.seed?.slug,
              let url = URL(string: "\(API.base)/shop/\(slug)") else { return }
        let av = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // Presenter — самый верхний экран: карточка бывает в шторке или
        // обложке (из push, «Избранного», «Жилья»), и корневой контроллер,
        // уже что-то показывающий, молча не открывал «Поделиться».
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
        while let p = top?.presentedViewController { top = p }
        top?.present(av, animated: true)
    }
}

// MARK: - DishRow (строка блюда)

/// Не используется с этапа 4 (меню — плитки ProductTile), удалить на этапе 14.
/// Строка блюда: фото 88×88, название + ХАЛЯЛЬ, описание, цена, круглая золотая «+».
struct DishRow: View {
    let product: Product
    var onTap: () -> Void = {}
    var onAdd: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(product.name ?? "—")
                            .ymFont(15.5, weight: .bold)
                            .foregroundStyle(YMColor.text)
                            .lineLimit(1)
                        if product.isHalal == true {
                            HalalBadge()
                        }
                    }
                    if let d = product.description, !d.isEmpty {
                        Text(d)
                            .ymFont(12.5)
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(2)
                    }
                    if product.stopped == true {
                        Text("Нет в наличии")
                            .ymFont(13, weight: .semibold)
                            .foregroundStyle(YMColor.muted)
                            .padding(.top, 2)
                    } else {
                        Text(Money.format(Money.dec(product.price)))
                            .ymFont(15, weight: .heavy)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .foregroundStyle(YMColor.text)
                            .padding(.top, 2)
                        if let w = product.wholesaleLabel {
                            Text(w).ymFont(11).foregroundStyle(YMColor.muted).lineLimit(1)
                        }
                        if let l = LikesText.recommend(product.likesPercent) {
                            Text(l).ymFont(11).foregroundStyle(YMColor.muted).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 8)
                ZStack(alignment: .bottomTrailing) {
                    PhotoPlaceholder(url: API.imageURL(product.photo),
                                     label: "ФОТО", radius: YMRadius.control, tone: product.id, fit: true)
                        .frame(width: 88, height: 88)
                    // Круглая золотая «+» со свечением. У закончившейся позиции её нет.
                    if product.stopped != true {
                    Button {
                        Haptics.light()
                        onAdd()
                    } label: {
                        Image(systemName: "plus")
                            .accessibilityLabel("Добавить в корзину")
                            .ymIcon(16, weight: .heavy)
                            .foregroundStyle(YMColor.onAccent)
                            .frame(width: 30, height: 30)
                            .background(YMColor.accent, in: Circle())
                            .shadow(color: YMPalette.gold.opacity(0.5), radius: 10, y: 3)
                    }
                    .buttonStyle(.plain)
                    .offset(x: 8, y: 8)
                    }
                }
                .opacity(product.stopped == true ? 0.5 : 1)
            }
            .padding(12)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11yLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Добавить в корзину") { if product.stopped != true { onAdd() } }
    }

    /// Название, цена и оптовая цена одной фразой для VoiceOver.
    private var a11yLabel: String {
        var parts: [String] = [product.name ?? "Товар"]
        if product.stopped == true {
            parts.append("нет в наличии")
        } else {
            parts.append(Money.format(Money.dec(product.price)))
            if let w = product.wholesaleLabel, !w.isEmpty { parts.append("оптовая цена " + w) }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - ProductTile (плитка товара, редизайн этап 4, ТЗ 5.4)

/// Белая карточка r20: квадратное фото на светло-серой плитке (вписано), метки в левом нижнем углу,
/// название в 2 строки, цена слева и круглая «+» справа; у товара в корзине «+» превращается в «− N +».
struct ProductTile: View {
    @Environment(\.colorScheme) private var tileScheme
    let product: Product
    var line: CartLine? = nil
    var busy: Bool = false
    var reduceMotion: Bool = false
    var onOpen: () -> Void = {}
    var onPlus: () -> Void = {}
    var onMinus: () -> Void = {}
    var onInc: () -> Void = {}

    private var unavailable: Bool { product.stopped == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .background(YMUi.photoBg)
                        .overlay {
                            PhotoPlaceholder(url: API.imageURL(product.photo), label: "ФОТО",
                                             radius: 0, tone: product.id, fit: true)
                                .padding(8)
                                // Белый фон фото продавцов сливается с серой плиткой (умножение): единый
                                // вид витрины без «рамок». В тёмной теме не применяем — затемнило бы товар.
                                .blendMode(tileScheme == .dark ? .normal : .multiply)
                        }
                        .overlay(alignment: .bottomLeading) {
                            let st = Self.stickers(product)
                            if !st.isEmpty { StickerStack(items: st).padding(6) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(product.name ?? "—")
                        .ymText(YMText.cardTitle)
                        .foregroundStyle(YMUi.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 4).padding(.top, 8)
                    if !unavailable {
                        if let l = LikesText.recommend(product.likesPercent) {
                            Text(l).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                                .lineLimit(1).padding(.horizontal, 4)
                        }
                        if let w = product.wholesaleLabel, !w.isEmpty {
                            Text(w).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                                .lineLimit(1).padding(.horizontal, 4)
                        }
                    }
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(a11yLabel)
            .accessibilityAddTraits(.isButton)

            HStack(spacing: 6) {
                if unavailable {
                    Text("Нет в наличии")
                        .ymText(YMText.caption)
                        .foregroundStyle(YMColor.statusCancel)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    Text(Money.format(Money.dec(product.price)))
                        .ymText(YMText.cardPrice)
                        .foregroundStyle(YMUi.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    ZStack {
                        if let l = line {
                            QtyStepper(qtyText: fmtQty(l.qty, l.isFractional ? l.unit : nil),
                                       onMinus: onMinus, onPlus: onInc)
                                .transition(.opacity)
                        } else {
                            Button(action: onPlus) {
                                ZStack {
                                    if busy {
                                        ProgressView().controlSize(.small).tint(YMUi.text)
                                    } else {
                                        Image(systemName: "plus")
                                            .ymIcon(15, weight: .semibold)
                                            .foregroundStyle(YMUi.text)
                                    }
                                }
                                .frame(width: 34, height: 34)
                                .background(YMUi.stepperBg, in: Circle())
                            }
                            .buttonStyle(.plain)
                            .disabled(busy)
                            .accessibilityLabel("Добавить в корзину")
                            .transition(.opacity)
                        }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: YMDur.plusToStepper), value: line != nil)
                }
            }
            .padding(.horizontal, 4)
            .frame(minHeight: 34)
        }
        .padding(8)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
        .opacity(unavailable ? 0.55 : 1)
    }

    private var a11yLabel: String {
        var parts: [String] = [product.name ?? "Товар"]
        if unavailable { parts.append("нет в наличии") }
        else { parts.append(Money.format(Money.dec(product.price))) }
        return parts.joined(separator: ", ")
    }

    /// Метки: теги продавца («хит» — красная, «новинка» — зелёная, остальное — свойство) + «Халяль».
    /// Цветные первыми; StickerStack показывает не больше трёх.
    static func stickers(_ p: Product) -> [(String, StickerKind)] {
        var out: [(String, StickerKind)] = []
        for t in p.tags ?? [] {
            let s = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty { continue }
            let low = s.lowercased()
            let kind: StickerKind
            if low == "хит" || low == "hit" || low.hasPrefix("хит ") { kind = .hit }
            else if low == "новинка" || low == "new" || low == "новое" { kind = .new }
            else { kind = .property }
            out.append((s.prefix(1).uppercased() + s.dropFirst(), kind))
        }
        if p.isHalal == true { out.append(("Халяль", .property)) }
        func rank(_ k: StickerKind) -> Int {
            switch k { case .hit: return 0; case .new: return 1; case .property: return 2 }
        }
        return out.enumerated()
            .sorted { a, b in
                let ra = rank(a.element.1), rb = rank(b.element.1)
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map { $0.element }
    }
}

// MARK: - HalalBadge (переиспользуемый бейдж «ХАЛЯЛЬ»)

/// Зелёный бейдж «ХАЛЯЛЬ» — семантика статуса «done» (зелёный), мягкая заливка.
struct HalalBadge: View {
    var body: some View {
        Text("ХАЛЯЛЬ")
            .ymFont(10, weight: .heavy)
            .tracking(0.3)
            .foregroundStyle(YMColor.statusDone)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(YMColor.statusDone.opacity(0.16), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}

// MARK: - OrgMiniMap (MapKit, золотой пин)

/// Мини-карта организации: неинтерактивная превью с золотым пином по lat/lng.
struct OrgMiniMap: View {
    let lat: Double
    let lng: Double

    struct Pin: Identifiable { let id = 0; let coord: CLLocationCoordinate2D }

    var body: some View {
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        let region = MKCoordinateRegion(center: coord,
                                        span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008))
        Map(coordinateRegion: .constant(region),
            interactionModes: [],
            annotationItems: [Pin(coord: coord)]) { pin in
            MapAnnotation(coordinate: pin.coord) {
                Image(systemName: "mappin.circle.fill")
                    .ymIcon(30)
                    .foregroundStyle(YMColor.accent)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ClosedBanner (баннер нерабочего времени + предзаказ)

/// Заметный баннер при входе в закрытую организацию.
/// `opensLabel` = nil → только «Сейчас закрыто» (нет данных о часах).
struct ClosedBanner: View {
    let opensLabel: String?
    /// true — товары/еда: подсказка про предзаказ; false — услуги (запись по окнам).
    var preorder: Bool = true
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text("🕑")
                Text(opensLabel != nil ? "Сейчас закрыто. Откроется \(opensLabel!)" : "Сейчас закрыто")
                    .ymFont(14.5, weight: .bold)
                    .foregroundStyle(YMColor.text)
            }
            // Предзаказ теперь есть (2026-10-13): оформление закрытого заведения
            // уходит с preorder_at ко времени работы. Раньше баннер говорил
            // «можно будет, когда откроется» — человек уходил, хотя мог заказать.
            // У услуг записи по свободным окнам — про предзаказ не пишем.
            Text(preorder ? "Можно оформить предзаказ — время выберете при оформлении."
                          : "Записаться можно на свободное время.")
                .ymFont(12.5)
                .foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.statusPending.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(YMColor.statusPending.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - OrgHours (расчёт открыто-сейчас + ближайшее открытие)

/// Логика рабочих часов по [ShopHour] (dayOfWeek 1=Пн..7=Вс, 0/7=Вс; isClosed==1 — выходной).
/// Без падений при пустых/битых данных. Паритет с Android isOpenNow/nextOpenLabel.
enum OrgHours {
    /// Открыто ли сейчас. nil = нет данных (вызывающий решает — считать открытым).
    /// Часы работы заданы временем города заведения (П-68: `timezone` карточки;
    /// нет поля — Москва), а не телефона: у покупателя в другом поясе «Откроется
    /// сегодня/завтра в …» и запасной расчёт «открыто» считались по его часам.
    private static func cal(_ tz: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c
    }

    static func isOpenNow(_ hours: [ShopHour]?, tz: TimeZone = ShopTime.moscow) -> Bool? {
        guard let hours, !hours.isEmpty else { return nil }
        let cal = Self.cal(tz)
        let now = Date()
        let dow = weekdayToServer(cal.component(.weekday, from: now)) // 1=Пн..7=Вс
        guard let today = hours.first(where: { norm($0.dayOfWeek) == dow }) else { return nil }
        if today.isClosed == 1 { return false }
        guard let open = today.openTime?.prefix(5).description,
              let close = today.closeTime?.prefix(5).description,
              !open.isEmpty, !close.isEmpty else { return nil }
        let cur = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        // Обычный интервал или «через полночь» (close <= open).
        return close > open ? (cur >= open && cur <= close) : (cur >= open || cur <= close)
    }

    /// «сегодня в HH:MM» / «завтра в HH:MM» / «в <день недели> в HH:MM». nil = нет данных.
    static func nextOpenLabel(_ hours: [ShopHour]?, tz: TimeZone = ShopTime.moscow) -> String? {
        guard let hours, !hours.isEmpty else { return nil }
        let cal = Self.cal(tz)
        let now = Date()
        let todayDow = weekdayToServer(cal.component(.weekday, from: now))
        let cur = String(format: "%02d:%02d", cal.component(.hour, from: now), cal.component(.minute, from: now))
        for offset in 0...7 {
            let dow = ((todayDow - 1 + offset) % 7) + 1
            guard let entry = hours.first(where: { norm($0.dayOfWeek) == dow }) else { continue }
            if entry.isClosed == 1 { continue }
            guard let open = entry.openTime?.prefix(5).description, !open.isEmpty else { continue }
            if offset == 0 && cur >= open { continue } // сегодня уже поздно — ищем дальше
            let whenLabel: String
            switch offset {
            case 0: whenLabel = "сегодня"
            case 1: whenLabel = "завтра"
            // «во вторник», а не «в вторник».
            default: whenLabel = (dow == 2 ? "во " : "в ") + ruWeekday(dow)
            }
            return "\(whenLabel) в \(open)"
        }
        return nil
    }

    /// Calendar.weekday (1=Вс..7=Сб) → серверный формат (1=Пн..7=Вс).
    private static func weekdayToServer(_ w: Int) -> Int { w == 1 ? 7 : w - 1 }
    /// Нормализуем серверный dayOfWeek к 1..7 (0=Вс → 7).
    private static func norm(_ dow: Int?) -> Int { let d = dow ?? 7; return d == 0 ? 7 : d }
    /// День недели в предложном падеже (1=Пн..7=Вс).
    private static func ruWeekday(_ dow: Int) -> String {
        switch dow {
        case 1: return "понедельник"; case 2: return "вторник"; case 3: return "среду"
        case 4: return "четверг"; case 5: return "пятницу"; case 6: return "субботу"
        default: return "воскресенье"
        }
    }
}

// MARK: - Money.dec (Double → Decimal, точно)

extension Money {
    /// Модели этого клиента хранят деньги как `Double?` (LenientDouble на сервере
    /// отдаёт числа/строки). `Money.parse(_:)` не имеет ветки для Double и вернул бы 0,
    /// поэтому конвертируем через строковое представление — без ошибки плавающей точки
    /// (Decimal(double) даёт мусорные хвосты). nil → 0.
    static func dec(_ value: Double?) -> Decimal {
        guard let v = value else { return 0 }
        // "%g" не годится для больших сумм; печатаем полное десятичное, без экспоненты.
        return Decimal(string: String(format: "%.2f", v)) ?? 0
    }
}
