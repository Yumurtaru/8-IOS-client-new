import SwiftUI

// MARK: - HomeViewModel

/// Модель Главной. Тянет данные ровно теми же вызовами/типами, что старый клиент
/// (см. 3 IOS-client HomeView): cities, banners, popular ([CatalogItem]),
/// организации ([Shop]) через /organizations|/shops. Деньги — Decimal (Money).
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var banners: [Banner] = []
    @Published var popular: [CatalogItem] = []      // «Популярное в городе»
    @Published var recommendations: [CatalogItem] = [] // «Рекомендуем вам» (персонально)
    @Published var shops: [Shop] = []               // список организаций
    @Published var kind: OrgKind = .all
    @Published var loading = true
    @Published var error: String?

    private var didInitialLoad = false

    /// OrgKind → серверный typeFilter (как в старом клиенте: all|restaurant|store|service).
    private func typeParam(_ k: OrgKind) -> String {
        switch k {
        case .all:         return "all"
        case .restaurants: return "restaurant"
        case .shops:       return "store"
        case .services:    return "service"
        case .lodging:     return "lodging"
        }
    }

    func firstLoad(session: Session) async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        await load(session: session)
    }

    /// Полная загрузка (первый вход и pull-to-refresh).
    /// Номер выборки. Запросы не отменяются: «Рестораны» → сразу «Магазины»,
    /// и ответ по ресторанам, пришедший последним, оставался на экране под
    /// чипом «Магазины», а первый закончившийся запрос раньше времени гасил
    /// скелетон. Теперь применяется только ответ последней выборки.
    private var gen = 0

    func load(session: Session) async {
        gen += 1
        let myGen = gen
        loading = true; error = nil
        // Города: если город ещё не выбран (нет id) — берём первый как в старом клиенте.
        if session.cityId == nil,
           let cities: [City] = try? await API.shared.list("api/v1/cities", query: ["with_orgs": "1"]),
           let first = cities.first {
            session.cityId = first.id
            session.cityName = session.cityName ?? first.name
        }
        // Баннеры здесь больше не запрашиваем: ленту сторис грузит сама
        // StoriesView (по городу), а этот запрос шёл без города, и его ответ
        // никто не читал — лишний запрос на каждом входе и обновлении.
        // Три независимых запроса — параллельно: раньше шли друг за другом,
        // и скелетон Главной висел сумму их времён.
        async let rec: Void = loadRecommendations(session: session)
        async let sec: Void = loadSections(session: session, myGen: myGen)
        await loadShops(session: session, myGen: myGen)
        _ = await (rec, sec)
        if myGen == gen { loading = false }
    }

    /// «Рекомендуем вам» — персональные товары: GET api/v1/recommendations?city_id=
    /// -> RecommendationsResp, товары в .popular. Для гостей сервер отдаёт пусто.
    /// Не зависит от чипа-типа (как в Android) — только от города.
    private func loadRecommendations(session: Session) async {
        var q: [String: String] = [:]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        // Пока шёл запрос, сменился аккаунт — подборка прежнего человека не нужна.
        let t = session.token
        let c = session.cityId
        let resp: RecommendationsResp? = try? await API.shared.get("api/v1/recommendations", query: q)
        // Сменили город, пока шёл запрос: опоздавший ответ клал подборку
        // прежнего города под новый — товары, которые сюда не возят.
        guard session.token == t, session.cityId == c else { return }
        recommendations = resp?.popular ?? []
    }

    /// Сменился аккаунт (вход/выход): личную подборку перечитываем, прежнюю
    /// убираем сразу — она собрана по заказам другого человека.
    func reloadRecommendations(session: Session) async {
        recommendations = []
        await loadRecommendations(session: session)
    }

    /// Смена типа-чипа: перегружаем только зависящие от типа секции/список.
    func changeKind(_ k: OrgKind, session: Session) async {
        kind = k
        gen += 1
        let myGen = gen
        loading = true; error = nil
        // Параллельно, как и в load(): секции и список друг от друга не зависят.
        async let sec: Void = loadSections(session: session, myGen: myGen)
        await loadShops(session: session, myGen: myGen)
        await sec
        if myGen == gen { loading = false }
    }

    // «Популярное в городе» — /api/v1/popular (как в старом клиенте), фильтр по type/city.
    private func loadSections(session: Session, myGen: Int) async {
        var q: [String: String] = [:]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        if kind != .all { q["type"] = typeParam(kind) }
        let list: [CatalogItem] = (try? await API.shared.list("api/v1/popular", query: q)) ?? []
        guard myGen == gen else { return }
        popular = list
    }

    // Список организаций. Рестораны/магазины/услуги → /organizations; «Все» → /shops.
    private func loadShops(session: Session, myGen: Int) async {
        // Для какого раздела и города список уже на экране. При сбое загрузки
        // ДРУГОГО раздела (или города) старый список не оставляем: под чипом
        // «Магазины» висели рестораны, под новым городом — заведения прежнего.
        let key = "\(kind.rawValue)|\(session.cityId ?? 0)"
        do {
            var q: [String: String] = [:]
            if let cid = session.cityId { q["city_id"] = String(cid) }
            var path = "api/v1/organizations"
            switch kind {
            case .all:
                path = "api/v1/shops"
            case .restaurants:
                q["type"] = "restaurant"
            case .shops:
                q["type"] = "store"
            case .services:
                q["type"] = "service"
            case .lodging:
                // Сюда мы в норме не попадаем: чип «Жильё» открывает раздел и
                // возвращается на место (см. ChipRow ниже). Ветка нужна, чтобы
                // switch был полным, и на всякий случай отдаёт согласованный
                // список — отели/квартиры, а не чужие организации.
                q["type"] = "lodging"
            }
            let list: [Shop] = try await API.shared.list(path, query: q)
            guard myGen == gen else { return }
            shops = list
            shopsKey = key
        } catch is CancellationError {
            // отмена (быстрый повторный запрос) — молча
        } catch {
            guard myGen == gen else { return }
            if shopsKey != key { shops = [] }
            self.error = error.localizedDescription
        }
    }
    private var shopsKey: String?
}

// MARK: - HomeView

struct HomeView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var router: DeepLinkRouter
    @EnvironmentObject private var coord: NavCoordinator
    @StateObject private var vm = HomeViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Избранное — с сервером, как в Поиске и разделе «Избранное». Раньше
    // сердечки на Главной жили только на экране: нажатие ничего не сохраняло,
    // а уже добавленное в избранное здесь не отмечалось.
    @State private var favShops: Set<Int> = []
    /// id товаров «Популярное» / «Рекомендуем» в избранном.
    @State private var favPopular: Set<Int> = []
    /// id, по которым запрос ♥ ещё в пути: двойной тап слал POST и DELETE
    /// вперемешку, а loadFavs затирал ещё не подтверждённую отметку.
    @State private var favBusyShops: Set<Int> = []
    @State private var favBusyProducts: Set<Int> = []
    /// ♥ не сохранилось — причина коротким сообщением (раньше откат был молча).
    @State private var favError: String?
    /// Гость нажал ♥ — сначала вход.
    @State private var showAuth = false
    @State private var appeared = false
    /// Чип, выбранный до нажатия на «Жильё» — к нему возвращаемся (см. ChipRow).
    @State private var lastKind: OrgKind = .all
    /// А97: GET /api/v1/features — карточка «Отправить посылку» только при parcels: true.
    @ObservedObject private var features = FeaturesStore.shared
    /// Гость нажал «Отправить посылку» — после входа открываем форму.
    @State private var parcelAfterAuth = false
    private var showParcelCard: Bool { features.current.parcels == true }

    // Единый маршрут навигации таба. ВАЖНО: несколько .navigationDestination(isPresented:)
    // в одном NavigationStack конфликтуют в SwiftUI (срабатывает только первый) — поэтому
    // держим ОДИН destination на enum-маршрут.
    private enum HomeRoute {
        case shop(Shop)
        case product(Int)
        case listing(orgType: String, title: String)
        case becomeSeller
        case about
    }
    @State private var route: HomeRoute?

    /// Переход с корня таба. Тап по вкладке снимает стек, но SwiftUI не всегда
    /// сбрасывает navigationDestination(isPresented:) — route оставался «висеть»,
    /// и повторное присваивание не меняло Binding: тап по организации или
    /// популярному товару ничего не открывал. Сначала сбрасываем, потом идём.
    private func go(_ r: HomeRoute) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    // Смена города с шапки Главной.
    @State private var showCitySheet = false
    // Профиль открывается из шапки (кнопка в правом углу) — модально.
    // Флаг живёт в NavCoordinator (profileOpen): пуш и ссылка закрывают
    // шторку перед переходом, иначе заказ/чат открывались под ней.

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    header
                    // Поиск на Главной — витрина (text=nil), тап через собственный onTap
                    // компонента уводит на вкладку «Поиск» (индекс 1).
                    SearchField(onTap: { Haptics.light(); router.requestedTab = 1 })
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, 14)

                    // Сторис-лента (баннеры города). Пусто/ошибка → сама рисует EmptyView.
                    // Отступ сверху (6) перенесён внутрь StoriesView — только при баннерах.
                    StoriesView(cityId: session.cityId)

                    ChipRow(selected: $vm.kind) { k in
                        // «Жильё» — не фильтр, а отдельный раздел: у него свой
                        // поиск по датам и гостям. Открываем его поверх таба и
                        // возвращаем чип на прежний, чтобы список под ним
                        // остался тем, что человек видел до нажатия.
                        if k == .lodging {
                            vm.kind = lastKind
                            coord.openLodging()
                            return
                        }
                        lastKind = k
                        // Остальные чипы (Все/Рестораны/Магазины/Услуги) — инлайн-загрузка.
                        Task { await vm.changeKind(k, session: session) }
                    }
                    .padding(.top, 12)

                    // ЯКОРЬ ЗАВИСИМОСТИ SwiftUI — НЕ УДАЛЯТЬ (это та самая «отладочная» строка,
                    // с которой «Магазины» заработали). Внутри LazyVStack секция списка не
                    // перерисовывалась при смене раздела/города — явное чтение
                    // vm.kind/vm.shops/vm.error/session.cityId в теле экрана заставляет body
                    // переоценивать список. Раскладка полная (как у рабочей строки), цвет —
                    // прозрачный, поэтому текста на экране не видно.
                    Text("город=\(session.cityId.map(String.init) ?? "нет") · раздел=\(vm.kind.rawValue) · пришло=\(vm.shops.count)\(vm.error.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.clear)
                        // Строка невидима глазом, но VoiceOver читал её вслух
                        // («город=1 · раздел=all · пришло=12», а при сбое — и
                        // текст ошибки). Скрываем из доступности и убираем из
                        // раскладки, зависимость body от полей сохраняется.
                        .accessibilityHidden(true)
                        .frame(maxWidth: .infinity, maxHeight: 0, alignment: .leading)
                        .clipped()

                    PromoBanner(action: { go(.about) })
                        .padding(.top, 12)

                    if vm.loading {
                        loadingSkeleton
                    } else if let e = vm.error, vm.shops.isEmpty, vm.popular.isEmpty {
                        errorState(e)
                    } else {
                        content
                    }

                    Color.clear.frame(height: 24)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            // Отдельная задача: отмена задачи экрана (переход на другую вкладку
            // по push при холодном старте, жест обновления) раньше обрывала
            // загрузку, все try? давали [] — и главная оставалась пустой до
            // ручного обновления, потому что первая загрузка уже «случилась».
            .refreshable { await Task { await vm.load(session: session) }.value }
            .task { await Task { await vm.firstLoad(session: session) }.value }
            // А97: что включено на площадке (кэш на минуту — запрос не чаще раза в минуту).
            .task { await features.refresh() }
            .onAppear { Task { await features.refresh() } }
            // Отметки избранного: по входу/выходу и при возврате на Главную
            // (сердечко могли поменять в заведении или в Поиске).
            .task(id: session.isLoggedIn) { await loadFavs() }
            // Город выбирается в онбординге ПОСЛЕ первой загрузки главной (HomeView рендерится
            // под онбордингом). Поэтому при смене cityId (онбординг / шторка города) —
            // перезагружаем данные под новый город, иначе организации не появляются.
            .onChange(of: session.cityId) { _ in
                Task { await vm.load(session: session) }
            }
            // Причина отказа ♥ на Главной.
            .errorToast($favError)
            // Переходы из карточек: организация → OrgView, популярный товар → ProductView.
            // ОДИН destination на все переходы таба (организация / товар / листинг категорий).
            .navigationDestination(isPresented: Binding(
                get: { route != nil }, set: { if !$0 { route = nil } }
            )) {
                switch route {
                case .shop(let s):                   OrgView(shop: s)
                case .product(let id):               ProductView(id: id)
                case .listing(let type, let title):  ListingView(orgType: type, title: title, cityId: session.cityId)
                case .becomeSeller:                  BecomeSellerView()
                case .about:                         AboutView()
                case .none:                          EmptyView()
                }
            }
            // Смена города с шапки: выбор → Session (id/name) + перезагрузка данных.
            .sheet(isPresented: $showCitySheet) {
                CityPickerSheet(
                    currentId: session.cityId,
                    currentName: session.cityName
                ) { id, name in
                    // Запасная строка «текущий город» без id (список не загрузился):
                    // раньше уходил city_id=0, и Главная грузила не тот город.
                    guard id > 0 else { showCitySheet = false; return }
                    session.cityName = name
                    session.cityId = id            // смена cityId → onChange выше перезагрузит данные
                    showCitySheet = false
                }
            }
            // Профиль модально (вкладки профиля больше нет — доступ из шапки).
            .sheet(isPresented: $coord.profileOpen) {
                ProfileView()
                    .environmentObject(session)
                    .environmentObject(Cart.shared)
                    .environmentObject(DeepLinkRouter.shared)
                    .environmentObject(NavCoordinator.shared)
                    // Заведение и товар из «Избранного» внутри шторки: общие окна
                    // корзины отсюда не видны — эти экраны показывают их сами.
                    .environment(\.ymNestedPresentation, true)
            }
            // Пуш «цена снизилась / снова в наличии» (product_id) — карточка товара.
            // onAppear — холодный старт: значение выставлено до появления экрана.
            .onChange(of: coord.pendingProductId) { id in openPendingProduct(id) }
            .onAppear { openPendingProduct(coord.pendingProductId) }
            // «Рекомендуем вам» — личная подборка по заказам: после выхода и входа
            // другим человеком на Главной оставалась подборка прежнего.
            .onChange(of: session.token) { _ in
                Task { await vm.reloadRecommendations(session: session) }
            }
        }
    }

    // MARK: Header (kicker «ВАШ ГОРОД» + город ▾ + аватар)

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Ваш город".uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(YMColor.accent)
                Button {
                    Haptics.selection()
                    showCitySheet = true   // шторка выбора города
                } label: {
                    HStack(spacing: 5) {
                        // Город ещё не выбран (первый запуск без сети) — раньше здесь
                        // стояла «Москва», хотя заведения были не московские.
                        Text(session.cityName ?? "Выберите город")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(YMColor.text)
                        Text("▾")
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                            .offset(y: 1)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            avatar
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 6)
    }

    // Кнопка профиля в правом углу шапки (профиль убран из нижних вкладок).
    private var avatar: some View {
        Button {
            Haptics.selection()
            coord.profileOpen = true
        } label: {
            Image(systemName: "person.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(YMColor.accent)
                .frame(width: 42, height: 42)
                .background(YMColor.surface2, in: Circle())
                .overlay(Circle().strokeBorder(YMColor.accent, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Content

    private var content: some View {
        VStack(spacing: 0) {
            // «Популярное в городе» — горизонтальная карусель PopularCard.
            if !vm.popular.isEmpty {
                SectionHeader(title: "Популярное в городе", actionTitle: "Все") {
                    router.requestedTab = 1
                }
                .padding(.top, 16)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(Array(vm.popular.enumerated()), id: \.element.uid) { idx, item in
                            PopularCard(
                                title: item.name ?? "—",
                                tag: item.category ?? item.shopName,
                                rating: nil,
                                photoURL: API.imageURL(item.photo),
                                tone: idx,
                                // Паритет с Android: цена в карточке подборки.
                                priceText: Money.format(Money.dec(item.price)),
                                isFav: favBinding(product: item.id)
                            ) {
                                go(.product(item.id))   // → карточка товара
                            }
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 4)
                }
            }

            // «Рекомендуем вам» — персональные товары (рисуем только если непусто).
            if !vm.recommendations.isEmpty {
                SectionHeader(title: "Рекомендуем вам", actionTitle: nil, action: nil)
                    .padding(.top, 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(Array(vm.recommendations.enumerated()), id: \.element.uid) { idx, item in
                            PopularCard(
                                title: item.name ?? "—",
                                tag: item.category ?? item.shopName,
                                rating: nil,
                                photoURL: API.imageURL(item.photo),
                                tone: idx,
                                // Паритет с Android: цена в карточке подборки.
                                priceText: Money.format(Money.dec(item.price)),
                                isFav: favBinding(product: item.id)
                            ) {
                                go(.product(item.id))   // → карточка товара
                            }
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 4)
                }
            }

            // «Рестораны» / организации — вертикальный список OrgCard.
            if !vm.shops.isEmpty {
                SectionHeader(title: sectionTitle, actionTitle: "Все") {
                    // «Все» → раздел листингом; для «Все» (kind=.all) уводим на Поиск, как раньше.
                    if let type = sectionOrgType {
                        go(.listing(orgType: type, title: sectionTitle))
                    } else {
                        router.requestedTab = 1
                    }
                }
                .padding(.top, 18)
                LazyVStack(spacing: YMSpace.lg) {
                    ForEach(Array(vm.shops.enumerated()), id: \.element.id) { idx, shop in
                        VStack(spacing: YMSpace.lg) {
                            OrgCard(shop: shop, tone: idx, isFav: favBinding(shop: shop.id)) {
                                go(.shop(shop))   // → карточка организации
                            }
                            .opacity(appeared || reduceMotion ? 1 : 0)
                            .offset(y: appeared || reduceMotion ? 0 : 12)
                            .animation(
                                YMMotion.adaptive(YMMotion.spring.delay(Double(idx) * 0.04),
                                                  reduceMotion: reduceMotion),
                                value: appeared
                            )
                            // А97: «Отправить посылку» — после второго заведения (меньше — после последнего).
                            if showParcelCard && idx == min(1, vm.shops.count - 1) {
                                ParcelPromoCard { openParcel() }
                            }
                            // Промо-карточка «Стать продавцом» после каждых 3 заведений.
                            if (idx + 1) % 3 == 0 {
                                BecomeSellerPromoCard { go(.becomeSeller) }
                            }
                        }
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, 4)
                .onAppear { appeared = true }
            } else if let e = vm.error, !vm.popular.isEmpty {
                // «Популярное» пришло, а список заведений — нет (таймаут на
                // мобильной сети): под каруселью было пусто, без ошибки и «Повторить».
                errorState(e)
            }

            if vm.popular.isEmpty && vm.shops.isEmpty {
                emptyState
            }
            // А97: заведений нет (пустой город / раздел) — карточка посылки отдельно.
            if showParcelCard && vm.shops.isEmpty && vm.error == nil {
                ParcelPromoCard { openParcel() }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 18)
            }
        }
        // Вход для ♥ гостя. Шторка — на содержимом, а не на корне экрана:
        // там уже висят выбор города и профиль.
        .sheet(isPresented: $showAuth, onDismiss: {
            // А97: гость нажимал «Отправить посылку» — вошёл: открываем форму.
            guard parcelAfterAuth else { return }
            parcelAfterAuth = false
            if session.isLoggedIn { openParcel() }
        }) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false })
            }
            .environmentObject(session)
        }
    }

    /// А97: «Отправить посылку» — тот же экран, что «Профиль → Отправить посылку» (в шторке профиля).
    /// Гость — сначала вход.
    private func openParcel() {
        guard session.isLoggedIn else {
            parcelAfterAuth = true
            showAuth = true
            return
        }
        coord.profileOpen = true
        ProfilePushIntent.open(.parcelNew)
    }

    private var sectionTitle: String {
        switch vm.kind {
        case .all, .restaurants: return "Рестораны"
        case .shops:             return "Магазины"
        case .services:          return "Услуги"
        // Чип «Жильё» не остаётся выбранным: он открывает раздел и
        // возвращается на прежний (см. ChipRow выше). Ветка нужна, чтобы
        // switch был полным, и на всякий случай даёт осмысленный заголовок.
        case .lodging:           return "Жильё"
        }
    }

    /// orgType раздела для листинга; nil для «Все» (там показываем общий Поиск).
    private var sectionOrgType: String? {
        switch vm.kind {
        case .all:         return nil
        case .restaurants: return "restaurant"
        case .shops:       return "store"
        case .services:    return "service"
        case .lodging:     return "lodging"
        }
    }

    // MARK: States

    private var loadingSkeleton: some View {
        VStack(spacing: YMSpace.lg) {
            // карусель
            HStack(spacing: YMSpace.md) {
                ForEach(0..<3, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBox(radius: YMRadius.card).frame(width: 146, height: 104)
                        SkeletonBox().frame(width: 110, height: 12)
                        SkeletonBox().frame(width: 70, height: 10)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // крупные карточки
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBox(radius: YMRadius.card).frame(height: 150)
                    SkeletonBox().frame(width: 160, height: 16)
                    SkeletonBox().frame(width: 200, height: 12)
                }
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 20)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(YMColor.muted)
            Text(message)
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await vm.load(session: session) } }
                .buttonStyle(YMSecondaryButtonStyle())
                .frame(maxWidth: 200)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 60)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Пока пусто")
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            Text("В вашем городе для выбранного раздела пока нет заведений.")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            // Пустой город/раздел был тупиком: только текст, без действия.
            // Город — та же шторка, что в шапке.
            Button(session.cityId == nil ? "Выбрать город" : "Выбрать другой город") {
                Haptics.selection()
                showCitySheet = true
            }
            .buttonStyle(YMSecondaryButtonStyle())
            .frame(maxWidth: 240)
            .padding(.top, YMSpace.sm)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 50)
    }

    private func openPendingProduct(_ id: Int?) {
        guard let id, id > 0 else { return }
        coord.pendingProductId = nil
        go(.product(id))
    }

    // MARK: Fav bindings (с сервером, откат при ошибке)

    private func favBinding(shop id: Int) -> Binding<Bool> {
        Binding(get: { favShops.contains(id) }, set: { on in
            guard session.isLoggedIn else { showAuth = true; return }
            // Предыдущий запрос по этому заведению ещё идёт — тап игнорируем.
            guard !favBusyShops.contains(id) else { return }
            favBusyShops.insert(id)
            if on { favShops.insert(id) } else { favShops.remove(id) }
            Task {
                do {
                    if on { try await API.shared.postVoid("api/v1/favorites/\(id)") }
                    else  { try await API.shared.deleteVoid("api/v1/favorites/\(id)") }
                } catch {
                    await MainActor.run {
                        if on { favShops.remove(id) } else { favShops.insert(id) }
                        favError = error.userMessage
                    }
                }
                await MainActor.run { _ = favBusyShops.remove(id) }
            }
        })
    }
    private func favBinding(product id: Int) -> Binding<Bool> {
        Binding(get: { favPopular.contains(id) }, set: { on in
            guard session.isLoggedIn else { showAuth = true; return }
            // Предыдущий запрос по этому товару ещё идёт — тап игнорируем.
            guard !favBusyProducts.contains(id) else { return }
            favBusyProducts.insert(id)
            if on { favPopular.insert(id) } else { favPopular.remove(id) }
            Task {
                do {
                    if on { try await API.shared.postVoid("api/v1/product-favorites/\(id)") }
                    else  { try await API.shared.deleteVoid("api/v1/product-favorites/\(id)") }
                } catch {
                    await MainActor.run {
                        if on { favPopular.remove(id) } else { favPopular.insert(id) }
                        favError = error.userMessage
                    }
                }
                await MainActor.run { _ = favBusyProducts.remove(id) }
            }
        })
    }

    /// Отметки избранного с сервера. Гостю — пусто (сердечки прежнего аккаунта
    /// не остаются). Сбой — прежние отметки не трогаем.
    private func loadFavs() async {
        guard session.isLoggedIn else { favShops = []; favPopular = []; return }
        // Для id с запросом «в пути» оставляем локальную отметку — ответ
        // сервера мог быть снят до этого нажатия.
        if let ids: [Int] = try? await API.shared.list("api/v1/product-favorites/ids") {
            var next = Set(ids)
            for b in favBusyProducts { if favPopular.contains(b) { next.insert(b) } else { next.remove(b) } }
            favPopular = next
        }
        if let favs: [Shop] = try? await API.shared.list("api/v1/favorites") {
            var next = Set(favs.map { $0.id })
            for b in favBusyShops { if favShops.contains(b) { next.insert(b) } else { next.remove(b) } }
            favShops = next
        }
    }
}

// MARK: - ParcelPromoCard (А97)

/// «Отправить посылку» между заведениями — в стиле карточки «Добавьте свою организацию»
/// (BecomeSellerPromoCard). Тексты — общие с Android (HomeScreen.ParcelPromoCard).
struct ParcelPromoCard: View {
    var onTap: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Text("КУРЬЕР YUMURTA")
                    .font(YMFont.caption2).fontWeight(.semibold)
                    .foregroundStyle(YMColor.accent)
                Text("Отправить посылку")
                    .font(YMFont.title3).foregroundStyle(YMColor.text)
                Text("Курьер заберёт и привезёт документы, пакеты, коробки и грузы. Людей и животных не возим.")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Вызвать курьера").font(YMFont.headline).foregroundStyle(YMColor.accent)
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.lg)
            .background(YMColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - CityPickerSheet (смена города с Главной)

/// Шторка выбора города: GET api/v1/cities -> [City]. Поиск по названию,
/// текущий город подсвечен золотом + галочкой. Пусто/ошибка → показываем хотя бы
/// текущий город, чтобы список никогда не был пустым (паритет с Android CityPickerSheet).
private struct CityPickerSheet: View {
    let currentId: Int?
    let currentName: String?
    var onPick: (Int, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cities: [City] = []
    @State private var query = ""
    @State private var loading = true
    /// Список не загрузился (сеть/сервер). Раньше это выглядело как
    /// «Город не найден» (или один текущий город), и повторить было нельзя.
    @State private var loadFailed = false

    // Fallback: если сервер пуст/ошибка — хотя бы текущий город.
    private var source: [City] {
        if !cities.isEmpty { return cities }
        if let name = currentName, !name.isEmpty {
            return [City(id: currentId ?? 0, name: name, region: nil)]
        }
        return []
    }
    private var filtered: [City] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return source }
        return source.filter { ($0.name ?? "").range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                TextField("Поиск города", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, YMSpace.lg)
                    .padding(.vertical, 12)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, YMSpace.md)

                if loading {
                    VStack(spacing: YMSpace.sm) {
                        ForEach(0..<6, id: \.self) { _ in
                            SkeletonBox(radius: YMRadius.control).frame(height: 54)
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                } else if loadFailed && cities.isEmpty {
                    VStack(spacing: YMSpace.sm) {
                        Text("Не удалось загрузить список городов. Проверьте интернет.")
                            .font(YMFont.callout)
                            .foregroundStyle(YMColor.muted)
                            .multilineTextAlignment(.center)
                        Button("Повторить") { Task { await loadCities() } }
                            .font(YMFont.callout.weight(.bold))
                            .foregroundStyle(YMColor.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 40)
                } else if filtered.isEmpty {
                    Text("Город не найден")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    ScrollView {
                        LazyVStack(spacing: YMSpace.sm) {
                            ForEach(filtered) { city in
                                cityRow(city)
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.bottom, YMSpace.xl)
                    }
                }
                Spacer(minLength: 0)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Выбор города")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                        .foregroundStyle(YMColor.accent)
                }
            }
            .task { await loadCities() }
        }
    }

    private func cityRow(_ city: City) -> some View {
        let name = city.name ?? "—"
        let selected: Bool = {
            if let id = currentId { return id == city.id }
            return name.caseInsensitiveCompare(currentName ?? "") == .orderedSame
        }()
        return Button {
            Haptics.selection()
            onPick(city.id, name)
        } label: {
            HStack {
                Text(name)
                    .font(.system(size: 16, weight: selected ? .bold : .medium))
                    .foregroundStyle(selected ? YMColor.accent : YMColor.text)
                Spacer()
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.accent)
                }
            }
            .padding(.horizontal, YMSpace.lg)
            .padding(.vertical, 14)
            .background(selected ? YMColor.accent.opacity(0.10) : YMColor.surface2,
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(selected ? YMColor.accent.opacity(0.5) : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func loadCities() async {
        loading = true; loadFailed = false
        do {
            cities = try await API.shared.list("api/v1/cities", query: ["with_orgs": "1"])
        } catch is CancellationError {
        } catch {
            loadFailed = true
        }
        loading = false
    }
}
