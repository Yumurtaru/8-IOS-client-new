//
//  DiscoverView.swift — Поиск / Категории / Избранное (premium-клиент)
//
//  Три раздела «Обзора» из макета DiscoverPhone (search | categories | favorites).
//  Строго на дизайн-токенах (YMColor/YMFont/YMSpace/YMRadius), light + dark,
//  Dynamic Type, Reduce Motion. ♥ — пружина + Haptics.
//
//  ТОЧКИ ВХОДА (для навигации / RootTabView):
//    • DiscoverView(mode: .search)      — таб «Поиск»
//    • DiscoverView(mode: .categories)  — раздел «Категории»
//    • DiscoverView(mode: .favorites)   — таб «Избранное»
//  Алиасы для читаемости точек входа табов:
//    • SearchScreen()      == DiscoverView(mode: .search)
//    • CategoriesScreen()  == DiscoverView(mode: .categories)
//    • FavoritesScreen()   == DiscoverView(mode: .favorites)
//
//  ПРИВЯЗКА К API (как в старом Search/Profile):
//    • Поиск:        GET  api/v1/search/smart?q=&price_min=&price_max=&rating=&sort=  → {shops, products}
//    • Категории:    GET  api/v1/org-categories/with-counts?type=store|service|restaurant → [OrgCategory]
//    • Избранное:    GET  api/v1/favorites → [Shop]  ·  GET api/v1/product-favorites → [Product]
//    • Toggle fav:   POST/DELETE api/v1/favorites/{id}  ·  POST/DELETE api/v1/product-favorites/{id}
//  Локальная история/недавние — SearchHistoryStore / RecentStore.
//

import SwiftUI

enum DiscoverMode { case search, categories, favorites }

// MARK: - Точки входа-алиасы (читаемость в RootTabView / навигации)

struct SearchScreen: View { var body: some View { DiscoverView(mode: .search) } }
struct CategoriesScreen: View { var body: some View { DiscoverView(mode: .categories) } }
struct FavoritesScreen: View { var body: some View { DiscoverView(mode: .favorites) } }

// MARK: - DiscoverView

struct DiscoverView: View {
    let mode: DiscoverMode
    init(mode: DiscoverMode) { self.mode = mode }

    var body: some View {
        switch mode {
        case .search:     SearchSection()
        case .categories: CategoriesSection()
        case .favorites:  FavoritesSection()
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ПОИСК
// ─────────────────────────────────────────────────────────────────────────────

/// Ответ /search/smart (как в старом клиенте): {shops, products}.
private struct SearchSmartResult: Decodable { let shops: [Shop]?; let products: [Product]? }

/// Единый маршрут перехода для всех секций вкладки (поиск / категории / избранное).
///
/// ПОЧЕМУ ОДНО СОСТОЯНИЕ, А НЕ ДВА. Раньше переход хранился в двух @State
/// (`pushedShop` и `pushedProduct`) и на экране висело два
/// `navigationDestination(isPresented:)`. SwiftUI оставляет в силе только один
/// из них — у второго перестаёт срабатывать закрытие, и его @State так и
/// остаётся заполненным после возврата назад. Дальше ЛЮБАЯ перерисовка экрана
/// (переключение сегмента «Организации ⇄ Товары», обновление списка) снова
/// видела «есть куда переходить» и повторно открывала прошлый экран: тап по
/// «Товары» открывал организацию, тап по «Организации» — товар.
///
/// РЕШЕНИЕ: ОДНО состояние `route` и ОДИН `navigationDestination` на экран —
/// ровно так, как на Главной (HomeView.HomeRoute), которая работает.
///
/// Почему НЕ `NavigationStack(path:)`: экраны, которые открываются отсюда
/// (OrgView, ProductView, ListingView), толкают дальше своими средствами —
/// `navigationDestination(isPresented:)` и обычным NavigationLink. Эти переходы
/// физически не попадают в типизированный path, поэтому path перестаёт
/// соответствовать реальной глубине стека: после «назад» в нём остаётся запись,
/// и следующая перерисовка открывает прошлый экран заново. Пока ВСЕ экраны
/// приложения не переведены на один общий маршрут, один флаг честнее path.
private enum DiscoverRoute: Hashable {
    case shop(Shop)
    case product(Int)
    case listing(orgType: String, title: String, categoryId: Int?)
}

private struct SearchSection: View {
    @EnvironmentObject private var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    @State private var q = ""
    @State private var shops: [Shop] = []
    @State private var products: [Product] = []
    @State private var loading = false
    /// Поиск не выполнился (сеть/сервер) — раньше показывалось «Ничего не найдено».
    @State private var searchFailed = false
    @State private var searchTask: Task<Void, Never>?
    /// Обрезанный текст последнего запущенного поиска: пробел в конце или в
    /// начале не меняет запрос — раньше он отменял идущий поиск и слал тот же заново.
    @State private var searchedKey = ""
    // Пустые на старте — заполняет .onAppear ниже. Начальное значение @State
    // вычисляется при КАЖДОЙ пересборке экрана (а она идёт с корня вкладок при
    // любом изменении корзины, сети, сессии): чтение настроек и разбор JSON
    // «недавно смотрели» шли на главном потоке впустую — результат отбрасывался.
    @State private var history: [String] = []
    @State private var recent: [RecentProduct] = []

    // Локальные избранные (оптимистично; toggle синхронизируется с сервером).
    @State private var favShops: Set<Int> = []
    @State private var favProducts: Set<Int> = []
    /// Товары, по которым запрос ♥ ещё идёт: повторный тап игнорируем (как на
    /// Главной) — двойной тап слал POST и DELETE разом, итог на сервере был случайным.
    @State private var favBusyProducts: Set<Int> = []
    /// ♥ не сохранилось — причина коротким сообщением (раньше откат был молча).
    @State private var favError: String?
    /// Гость нажал ♥ — сначала вход (избранное хранится в аккаунте).
    @State private var showAuth = false

    // Навигация внутри своего NavigationStack: одно состояние на переход.
    @State private var route: DiscoverRoute?

    /// Переход с корня таба. Тап по вкладке снимает стек, но SwiftUI не всегда
    /// сбрасывает navigationDestination(isPresented:) — route оставался «висеть»,
    /// и тап по найденному ничего не открывал. Сначала сбрасываем, потом идём.
    private func go(_ r: DiscoverRoute) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    private var trimmed: String { q.trimmingCharacters(in: .whitespaces) }
    private var showResults: Bool { !shops.isEmpty || !products.isEmpty }
    private var showSuggestState: Bool { trimmed.count < 2 }

    // Живые подсказки из истории + недавних (совпадение выделяется жирным).
    private var suggestions: [String] {
        guard trimmed.count >= 1 else { return [] }
        let ql = trimmed.lowercased()
        var pool = history
        pool.append(contentsOf: recent.map { $0.name })
        var seen = Set<String>(); var out: [String] = []
        for s in pool where s.lowercased().contains(ql) {
            let key = s.lowercased()
            if seen.insert(key).inserted { out.append(s) }
            if out.count >= 6 { break }
        }
        return out
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if !suggestions.isEmpty {
                            suggestionsBlock
                        } else if showSuggestState {
                            recentAndPopularBlock
                        }
                        if showResults { resultsBlock }
                        else if loading { loadingBlock }
                        else if searchFailed {
                            VStack(spacing: YMSpace.sm) {
                                Text("Не удалось выполнить поиск").font(YMFont.title3).foregroundStyle(YMColor.text)
                                Button("Повторить") { scheduleSearch() }.foregroundStyle(YMColor.accent)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 60)
                        }
                        else if !showSuggestState && trimmed.count >= 2 {
                            emptyResults
                        }
                    }
                    .padding(.top, YMSpace.sm)
                    .padding(.bottom, YMSpace.xxxl)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            // ОДИН destination на экран (см. DiscoverRoute).
            .navigationDestination(isPresented: Binding(
                get: { route != nil }, set: { if !$0 { route = nil } }
            )) {
                switch route {
                case .shop(let s):     OrgView(shop: s)
                case .product(let id): ProductView(id: id)
                default:               EmptyView()
                }
            }
        }
        // По входу/выходу: сердечки прежнего аккаунта не должны оставаться.
        .task(id: session.isLoggedIn) { await loadFavIds() }
        // Экран поиска живёт всю сессию: историю и «недавно смотрели» читаем
        // при каждом появлении, иначе они не обновлялись (и после смены
        // аккаунта показывали чужие).
        .onAppear { history = SearchHistoryStore.load(); recent = RecentStore.load() }
        // Тот же запрос без пробелов по краям — новый поиск не нужен (после
        // ошибки — ищем снова, как раньше).
        .onChange(of: q) { _ in if trimmed != searchedKey || searchFailed { scheduleSearch() } }
        // Сменили город на Главной — результаты прежнего города под тем же
        // запросом оставались до следующей буквы. Ищем заново.
        .onChange(of: session.cityId) { _ in scheduleSearch() }
        .errorToast($favError)
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false })
            }
            .environmentObject(Session.shared)
        }
    }

    // ── Поле ввода с золотой рамкой + «Отмена» ──
    private var searchBar: some View {
        HStack(spacing: YMSpace.md) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(focused ? YMColor.accent : YMColor.muted)
                TextField("Рестораны, товары, услуги…", text: $q)
                    .font(YMFont.body)
                    .foregroundStyle(YMColor.text)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($focused)
                    .onSubmit { recordHistory() }
                if !q.isEmpty {
                    Button { q = ""; clearResults() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(YMColor.muted)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 15)
            .frame(height: 46)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(focused ? YMColor.accent : YMColor.hairline, lineWidth: focused ? 1.5 : 1)
            )
            if focused || !q.isEmpty {
                Button("Отмена") {
                    q = ""; clearResults(); focused = false
                }
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(YMColor.accent)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .padding(.bottom, YMSpace.md)
        .animation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion), value: focused)
    }

    // ── Подсказки (совпадение выделено) ──
    private var suggestionsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionKicker("Подсказки")
            ForEach(suggestions, id: \.self) { s in
                Button {
                    q = s; focused = false; recordHistory()
                } label: {
                    HStack(spacing: YMSpace.md) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundStyle(YMColor.muted)
                        highlighted(s)
                            .font(.system(size: 14.5))
                            .foregroundStyle(YMColor.text)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.left")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(YMColor.muted)
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // ── Недавние + недавно смотрели ──
    private var recentAndPopularBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Новый человек: ни истории, ни «недавно смотрели» — под полем был
            // пустой экран, вкладка выглядела сломанной. Подсказываем, что искать.
            if history.isEmpty && recent.isEmpty {
                VStack(spacing: YMSpace.sm) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(YMColor.muted)
                    Text("Что ищем?").font(YMFont.title3).foregroundStyle(YMColor.text)
                    Text("Введите название заведения, блюда, товара или услуги — покажем, что есть в вашем городе.")
                        .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, YMSpace.xxxl)
                .padding(.top, 60)
            }
            if !history.isEmpty {
                HStack {
                    sectionKicker("Недавние запросы")
                    Spacer()
                    Button("Очистить") { SearchHistoryStore.clear(); history = [] }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(YMColor.accent)
                        .padding(.trailing, YMSpace.xl)
                }
                FlowChips(items: history) { term in q = term; recordHistory() }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.bottom, YMSpace.md)
            }
            if !recent.isEmpty {
                sectionKicker("Недавно смотрели")
                ForEach(recent) { r in
                    Button { go(.product(r.id)) } label: {
                        HStack(spacing: YMSpace.md) {
                            PhotoPlaceholder(url: API.imageURL(r.photo), label: "ФОТО", radius: 12, tone: r.id)
                                .frame(width: 44, height: 44)
                            Text(r.name).font(YMFont.body).foregroundStyle(YMColor.text).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Money.format(Money.parse(r.price)))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(YMColor.muted)
                        }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // ── Результаты: Товары (горизонтально) + Организации (строки со ★) ──
    private var resultsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !products.isEmpty {
                sectionKicker("Результаты · Товары")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: YMSpace.md) {
                        ForEach(Array(products.enumerated()), id: \.element.id) { idx, p in
                            productResultCard(p, tone: idx)
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.vertical, YMSpace.sm)
                }
            }
            if !shops.isEmpty {
                sectionKicker("Организации")
                ForEach(Array(shops.enumerated()), id: \.element.id) { idx, s in
                    orgResultRow(s, tone: idx)
                }
            }
        }
    }

    private func productResultCard(_ p: Product, tone: Int) -> some View {
        Button { go(.product(p.id)) } label: {
            VStack(alignment: .leading, spacing: 7) {
                PhotoPlaceholder(url: API.imageURL(p.photo), label: "ФОТО", radius: 16, tone: tone)
                    .frame(width: 150, height: 96)
                    .overlay(alignment: .topTrailing) {
                        HeartButton(isFav: favProduct(p.id), size: 26, favColor: YMColor.statusCancel).padding(6)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if (p.isPromoted ?? 0) == 1 {
                            Text("Реклама")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .padding(6)
                        }
                    }
                Text(p.name ?? "—")
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundStyle(YMColor.text).lineLimit(1)
                // П-22.3: из какого заведения товар (поле необязательное).
                if let sn = p.shopName?.trimmingCharacters(in: .whitespaces), !sn.isEmpty {
                    Text(sn)
                        .font(.system(size: 11.5))
                        .foregroundStyle(YMColor.muted).lineLimit(1)
                }
                Text(Money.format(Money.parse(p.price)))
                    .font(.system(size: 12))
                    .foregroundStyle(YMColor.muted)
            }
            .frame(width: 150, alignment: .leading)
        }
        .buttonStyle(CardPressStyle())
    }

    private func orgResultRow(_ s: Shop, tone: Int) -> some View {
        Button { go(.shop(s)) } label: {
            HStack(spacing: YMSpace.md) {
                PhotoPlaceholder(url: API.imageURL(s.logo ?? s.cover), label: "ЛОГО", radius: 12, tone: tone)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.name ?? "—").font(.system(size: 14, weight: .bold)).foregroundStyle(YMColor.text).lineLimit(1)
                    if let cat = s.category, !cat.isEmpty {
                        Text(cat).font(.system(size: 12)).foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let r = s.rating, r > 0 {
                    HStack(spacing: 4) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                    }
                    .font(.system(size: 13, weight: .bold))
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loadingBlock: some View {
        VStack(spacing: YMSpace.md) {
            ForEach(0..<4, id: \.self) { _ in
                SkeletonBox().frame(height: 56)
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.md)
    }

    private var emptyResults: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Ничего не найдено").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Попробуйте изменить запрос.").font(YMFont.callout).foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    // ── helpers ──
    private func sectionKicker(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.system(size: 12, weight: .heavy)).tracking(0.6)
            .foregroundStyle(YMColor.muted)
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.md).padding(.bottom, YMSpace.sm)
    }

    /// Текст с выделенным вхождением запроса (bold).
    private func highlighted(_ s: String) -> Text {
        // Ищем прямо в s без учёта регистра — диапазон тогда принадлежит самой s.
        // Раньше искали в s.lowercased() и переносили индексы на s: у «İ»
        // строчная форма длиннее, и на названии вроде «İstanbul Kebap» с
        // запросом «bul» индекс уходил за конец строки — вылет при поиске.
        guard !trimmed.isEmpty, let r = s.range(of: trimmed, options: .caseInsensitive) else { return Text(s) }
        let pre = String(s[s.startIndex..<r.lowerBound])
        let mid = String(s[r])
        let post = String(s[r.upperBound..<s.endIndex])
        return Text(pre) + Text(mid).fontWeight(.heavy) + Text(post)
    }

    private func favProduct(_ id: Int) -> Binding<Bool> {
        Binding(get: { favProducts.contains(id) }, set: { on in
            // Гостю — вход: раньше сердечко загоралось, запрос получал 401 и
            // молча гасло обратно, без объяснения.
            guard session.isLoggedIn else { showAuth = true; return }
            guard !favBusyProducts.contains(id) else { return }
            favBusyProducts.insert(id)
            if on { favProducts.insert(id) } else { favProducts.remove(id) }
            Task {
                await toggleProductFav(id, on: on)
                await MainActor.run { _ = favBusyProducts.remove(id) }
            }
        })
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = trimmed
        guard query.count >= 2 else { searchedKey = ""; clearResults(); return }
        searchedKey = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            await runSearch(query)
        }
    }

    private func runSearch(_ query: String) async {
        loading = true
        searchFailed = false
        var params: [String: String] = ["q": query]
        if let cid = session.cityId { params["city_id"] = String(cid) }   // глобально по городу
        do {
            let r: SearchSmartResult = try await API.shared.get("api/v1/search/smart", query: params)
            // Ответ пришёл, а запрос уже сменили (набрали букву, стёрли поле):
            // отмена не успела оборвать запрос, и результаты прежнего запроса
            // ложились под новый текст. Новый поиск сам выставит свои.
            if Task.isCancelled || query != trimmed { return }
            shops = r.shops ?? []; products = r.products ?? []
        } catch {
            // Отмена (набрали следующую букву) — не «ничего не найдено».
            // Но и вечную крутилку не оставляем: ушли с экрана посреди поиска —
            // при возврате индикатор висел до следующей буквы.
            if Task.isCancelled || error is CancellationError { loading = false; return }
            shops = []; products = []; searchFailed = true
        }
        loading = false
    }

    private func recordHistory() {
        let query = trimmed
        guard query.count >= 2 else { return }
        SearchHistoryStore.add(query)
        history = SearchHistoryStore.load()
        scheduleSearch()
    }

    private func clearResults() { shops = []; products = []; loading = false; searchFailed = false }

    private func loadFavIds() async {
        // Гость: сердечки прошлого аккаунта не показываем.
        guard session.isLoggedIn else { favProducts = []; favShops = []; return }
        if let ids: [Int] = try? await API.shared.list("api/v1/product-favorites/ids") {
            favProducts = Set(ids)
        }
        if let favs: [Shop] = try? await API.shared.list("api/v1/favorites") {
            favShops = Set(favs.map { $0.id })
        }
    }

    private func toggleProductFav(_ id: Int, on: Bool) async {
        do {
            if on { try await API.shared.postVoid("api/v1/product-favorites/\(id)") }
            else  { try await API.shared.deleteVoid("api/v1/product-favorites/\(id)") }
        } catch {
            // откат при ошибке + причина словами
            await MainActor.run {
                if on { favProducts.remove(id) } else { favProducts.insert(id) }
                favError = error.userMessage
            }
        }
    }
}

/// Пилюли-чипы истории (перенос строк).
private struct FlowChips: View {
    let items: [String]
    var onTap: (String) -> Void
    var body: some View {
        // ScrollView горизонтально — простой и предсказуемый layout под Dynamic Type.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: YMSpace.sm) {
                ForEach(items, id: \.self) { term in
                    Button { onTap(term) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11))
                            Text(term).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        }
                        .foregroundStyle(YMColor.text)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                            .strokeBorder(YMColor.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - КАТЕГОРИИ
// ─────────────────────────────────────────────────────────────────────────────

private enum CatTab: String, CaseIterable, Hashable {
    case shops, services, food
    var title: String { self == .shops ? "Магазины" : self == .services ? "Услуги" : "Еда" }
    /// type-параметр сервера org-categories/with-counts.
    var apiType: String { self == .shops ? "store" : self == .services ? "service" : "restaurant" }
}

private struct CategoriesSection: View {
    @EnvironmentObject private var session: Session
    @State private var tab: CatTab = .shops
    @State private var cats: [OrgCategory] = []
    @State private var loading = true
    // Листинг организаций выбранной категории (orgType + заголовок).
    @State private var route: DiscoverRoute?

    /// Переход с корня таба. Тап по вкладке снимает стек, но SwiftUI не всегда
    /// сбрасывает navigationDestination(isPresented:) — route оставался «висеть»,
    /// и тап по найденному ничего не открывал. Сначала сбрасываем, потом идём.
    private func go(_ r: DiscoverRoute) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Категории")
                        .font(.system(size: 28, weight: .heavy)).tracking(-0.6)
                        .foregroundStyle(YMColor.text)
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, YMSpace.sm).padding(.bottom, YMSpace.md)

                    YMSegmented(options: CatTab.allCases, selection: $tab) { $0.title }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.bottom, YMSpace.lg)

                    if loading {
                        grid(count: 6) { SkeletonBox(radius: 18).frame(height: 104) }
                    } else if cats.isEmpty {
                        // П-28.15б: у ресторанов рубрик нет — сервер всегда отдаёт [],
                        // и «пока пусто» под «Едой» вводило в заблуждение. Пустой
                        // блок не показываем; у других вкладок — как раньше.
                        if tab != .food { emptyState }
                    } else {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: YMSpace.md),
                                            GridItem(.flexible(), spacing: YMSpace.md)],
                                  spacing: YMSpace.md) {
                            ForEach(Array(cats.enumerated()), id: \.element.id) { idx, cat in
                                CategoryTile(category: cat, tone: idx, tab: tab) {
                                    Haptics.selection()
                                    // id категории — в листинг: раньше открывался весь
                                    // раздел под названием категории (как Android — с фильтром).
                                    go(.listing(orgType: tab.apiType,
                                                title: cat.name ?? tab.title,
                                                categoryId: cat.id))
                                }
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                    }
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationBarHidden(true)
            .navigationDestination(isPresented: Binding(
                get: { route != nil }, set: { if !$0 { route = nil } }
            )) {
                switch route {
                case .listing(let type, let title, let categoryId):
                    ListingView(orgType: type, title: title, cityId: session.cityId, categoryId: categoryId)
                default:
                    EmptyView()
                }
            }
        }
        .task { await load() }
        .onChange(of: tab) { _ in Task { await load() } }
    }

    @ViewBuilder private func grid<Content: View>(count: Int, @ViewBuilder _ cell: @escaping () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: YMSpace.md),
                            GridItem(.flexible(), spacing: YMSpace.md)], spacing: YMSpace.md) {
            ForEach(0..<count, id: \.self) { _ in cell() }
        }
        .padding(.horizontal, YMSpace.xl)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("Категорий пока нет").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("В этом разделе для вашего города пока пусто.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 50)
    }

    private func load() async {
        loading = true
        let forTab = tab
        var q: [String: String] = ["type": forTab.apiType]
        if let cid = session.cityId { q["city_id"] = String(cid) }
        let list: [OrgCategory] = (try? await API.shared.list("api/v1/org-categories/with-counts", query: q)) ?? []
        // «Магазины» → сразу «Услуги»: опоздавший ответ по магазинам ложился под
        // вкладку «Услуги», и плитка открывала листинг не того раздела.
        guard forTab == tab else { return }
        cats = list
        loading = false
    }
}

/// Плитка категории 104pt: эмодзи/иконка, название, счётчик.
private struct CategoryTile: View {
    let category: OrgCategory
    var tone: Int = 0
    /// Раздел плитки: слово счётчика своё — у «Еды» и «Услуг» было «12 магазинов».
    fileprivate var tab: CatTab = .shops
    var onTap: () -> Void = {}

    // Счётчик «128 магазинов» с корректным склонением.
    private var countLine: String? {
        guard let n = category.count, n > 0 else { return nil }
        return "\(n) \(plural(n))"
    }
    private func plural(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        let forms: (String, String, String)
        switch tab {
        case .shops:    forms = ("магазин", "магазина", "магазинов")
        case .services: forms = ("организация", "организации", "организаций")
        case .food:     forms = ("заведение", "заведения", "заведений")
        }
        if m10 == 1 && m100 != 11 { return forms.0 }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return forms.1 }
        return forms.2
    }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                Text(category.icon?.isEmpty == false ? category.icon! : "🏷️")
                    .font(.system(size: 26))
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name ?? "—")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text).lineLimit(1)
                    if let c = countLine {
                        Text(c).font(.system(size: 11.5)).foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 104)
            .padding(14)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([category.name, countLine].compactMap { $0 }.joined(separator: ", "))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ИЗБРАННОЕ
// ─────────────────────────────────────────────────────────────────────────────

private enum FavTab: String, CaseIterable, Hashable {
    case orgs, products
    var title: String { self == .orgs ? "Организации" : "Товары" }
}

private struct FavoritesSection: View {
    @State private var tab: FavTab = .orgs
    @State private var shops: [Shop] = []
    @State private var products: [Product] = []
    @State private var loading = true
    /// Текст ошибки. Раньше обе загрузки шли через `try?`, и ЛЮБОЙ сбой —
    /// истёкшая сессия, нет сети, 500 — превращался в пустой список: человек с
    /// непустым избранным видел «здесь пока пусто» и шёл искать поломку.
    @State private var error: String?
    @State private var reloadKey = 0
    @State private var favShops: Set<Int> = []
    @State private var favProducts: Set<Int> = []
    /// Запрос ♥ ещё идёт — повторный тап по этой карточке игнорируем (как на Главной).
    @State private var favBusyShops: Set<Int> = []
    @State private var favBusyProducts: Set<Int> = []
    /// ♥ не сохранилось — причина коротким сообщением (раньше откат был молча).
    @State private var favError: String?
    @State private var route: DiscoverRoute?
    /// Гость нажал «Войти» на экране избранного.
    @State private var showAuth = false

    /// Переход как на Главной и в Поиске (go): стек профиля сняли без вызова
    /// сеттера — route «висел», и тап по карточке избранного ничего не открывал.
    private func go(_ r: DiscoverRoute) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    /// СВОЕГО NavigationStack здесь НЕТ, и это принципиально.
    ///
    /// «Избранное» перестало быть нижней вкладкой и открывается из профиля —
    /// то есть ВНУТРИ NavigationStack профиля (ProfileView.profileDestination).
    /// Стек внутри стека SwiftUI не прощает: экран открывался и тут же
    /// схлопывался обратно, а после нескольких попыток навигация ломалась
    /// совсем — белый экран с жёлтым треугольником вместо содержимого.
    ///
    /// Поэтому секция — обычное содержимое, как AddressesView и остальные
    /// разделы профиля: заголовок в навбаре, переходы уходят в стек родителя.
    /// Соседние секции (Поиск) остаются вкладками и свой стек сохраняют.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Количество прямо на сегменте: пустые «Организации» больше
                // нельзя принять за пустое избранное целиком, когда товары есть.
                YMSegmented(options: FavTab.allCases, selection: $tab) { t in
                    let n = (t == .orgs) ? shops.count : products.count
                    return n > 0 ? "\(t.title)  \(n)" : t.title
                }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.bottom, YMSpace.lg)

                if !Session.shared.isLoggedIn {
                    // Гость видел ровно то же «здесь пока пусто», что и человек
                    // с пустым избранным. Избранное лежит на сервере и привязано
                    // к аккаунту — причину надо назвать прямо.
                    notice(icon: "♥", title: "Войдите в аккаунт",
                           text: "Избранное хранится в вашем аккаунте, а не на телефоне.")
                    // Гость из профиля попадал сюда в тупик: «Войдите» без кнопки.
                    // Вход — шторкой, после него остаёмся здесь и грузим избранное.
                    Button("Войти") { Haptics.light(); showAuth = true }
                        .buttonStyle(YMPrimaryButtonStyle())
                        .frame(maxWidth: 240)
                        .frame(maxWidth: .infinity)
                        .padding(.top, YMSpace.lg)
                } else if loading {
                    VStack(spacing: YMSpace.lg) {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBox(radius: 20).frame(height: 178) }
                    }
                    .padding(.horizontal, YMSpace.xl)
                } else if let e = error {
                    VStack(spacing: YMSpace.sm) {
                        Text(e).font(YMFont.callout).foregroundStyle(YMColor.muted)
                            .multilineTextAlignment(.center)
                        Button("Повторить") { reloadKey += 1 }
                            .font(YMFont.callout.weight(.bold))
                            .foregroundStyle(YMColor.accent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, YMSpace.xxxl).padding(.top, 40)
                } else if tab == .orgs {
                    if shops.isEmpty { empty("Нет избранных организаций") }
                    else {
                        VStack(spacing: YMSpace.lg) {
                            ForEach(Array(shops.enumerated()), id: \.element.id) { idx, s in
                                FavOrgCard(shop: s, tone: idx, isFav: favShop(s.id)) { go(.shop(s)) }
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                    }
                } else {
                    if products.isEmpty { empty("Нет избранных товаров") }
                    else {
                        VStack(spacing: YMSpace.lg) {
                            ForEach(Array(products.enumerated()), id: \.element.id) { idx, p in
                                FavProductCard(product: p, tone: idx, isFav: favProduct(p.id)) { go(.product(p.id)) }
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                    }
                }
            }
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Избранное")
        .navigationBarTitleDisplayMode(.inline)
        // ОДИН destination на экран (см. DiscoverRoute). Привязывается к
        // стеку профиля — своего у секции больше нет.
        .navigationDestination(isPresented: Binding(
            get: { route != nil }, set: { if !$0 { route = nil } }
        )) {
            switch route {
            case .shop(let s):     OrgView(shop: s)
            case .product(let id): ProductView(id: id)
            default:               EmptyView()
            }
        }
        .task(id: reloadKey) { await load() }
        .errorToast($favError)
        // Вход гостя: после него перечитываем избранное (reloadKey).
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false; reloadKey += 1 })
            }
            .environmentObject(Session.shared)
        }
        // Гашение отложенного перехода при смене вкладки. YMSegmented пишет
        // selection внутри withAnimation, поэтому сбрасываем маршрут здесь,
        // а не в теле — иначе переключение сегмента и перестройка перехода
        // попадают в одну транзакцию и тап по сегменту теряется.
        .onChange(of: tab) { _ in route = nil }
    }

    private func empty(_ title: String) -> some View {
        VStack(spacing: YMSpace.sm) {
            Text("💔").font(.system(size: 44))
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Добавляйте организации и товары тапом по ♥.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 40)
    }

    private func favShop(_ id: Int) -> Binding<Bool> {
        Binding(get: { favShops.contains(id) }, set: { on in
            guard !favBusyShops.contains(id) else { return }
            favBusyShops.insert(id)
            if on { favShops.insert(id) } else { favShops.remove(id) }
            Task {
                await toggleShopFav(id, on: on)
                await MainActor.run { _ = favBusyShops.remove(id) }
            }
        })
    }
    private func favProduct(_ id: Int) -> Binding<Bool> {
        Binding(get: { favProducts.contains(id) }, set: { on in
            guard !favBusyProducts.contains(id) else { return }
            favBusyProducts.insert(id)
            if on { favProducts.insert(id) } else { favProducts.remove(id) }
            Task {
                await toggleProductFav(id, on: on)
                await MainActor.run { _ = favBusyProducts.remove(id) }
            }
        })
    }

    private func load() async {
        // Скелетоны — только когда показывать нечего. `.task` перезапускается
        // при каждом возврате на вкладку, и loading = true прятал весь список
        // целиком — со стороны это выглядело так, будто переключение
        // «Организации ⇄ Товары» не сработало.
        guard Session.shared.isLoggedIn else { loading = false; return }
        if shops.isEmpty && products.isEmpty { loading = true }
        error = nil
        // try? здесь больше нет: сбой должен быть виден, а не выглядеть как
        // пустое избранное.
        // Отмена (ушли на карточку, «Повторить» во время загрузки) — не ошибка:
        // раньше список стирался и показывалось английское
        // «The operation couldn't be completed (Swift.CancellationError…)».
        do {
            shops = try await API.shared.list("api/v1/favorites")
        } catch is CancellationError {
            return   // следующий запуск .task загрузит заново
        } catch {
            shops = []
            self.error = "Не удалось загрузить избранное: \(error.localizedDescription)"
        }
        do {
            products = try await API.shared.list("api/v1/product-favorites")
        } catch is CancellationError {
            return   // следующий запуск .task загрузит заново
        } catch {
            products = []
            // Ошибку первого запроса не затираем: показываем ту, что случилась раньше.
            if self.error == nil { self.error = "Не удалось загрузить избранное: \(error.localizedDescription)" }
        }
        favShops = Set(shops.map { $0.id })
        favProducts = Set(products.map { $0.id })
        loading = false
    }

    /// Простое сообщение по центру: иконка, заголовок, пояснение.
    private func notice(icon: String, title: String, text: String) -> some View {
        VStack(spacing: YMSpace.sm) {
            Text(icon).font(.system(size: 44)).foregroundStyle(YMColor.accent)
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(text).font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 40)
    }
    private func toggleShopFav(_ id: Int, on: Bool) async {
        do {
            if on { try await API.shared.postVoid("api/v1/favorites/\(id)") }
            else  { try await API.shared.deleteVoid("api/v1/favorites/\(id)") }
        } catch {
            await MainActor.run {
                if on { favShops.remove(id) } else { favShops.insert(id) }
                favError = error.userMessage
            }
        }
    }
    private func toggleProductFav(_ id: Int, on: Bool) async {
        do {
            if on { try await API.shared.postVoid("api/v1/product-favorites/\(id)") }
            else  { try await API.shared.deleteVoid("api/v1/product-favorites/\(id)") }
        } catch {
            await MainActor.run {
                if on { favProducts.remove(id) } else { favProducts.insert(id) }
                favError = error.userMessage
            }
        }
    }
}

/// Карточка избранной организации: фото 120pt, ♥ (золото), бейдж статуса, ★.
private struct FavOrgCard: View {
    let shop: Shop
    var tone: Int = 0
    @Binding var isFav: Bool
    var onTap: () -> Void = {}

    private var isOpen: Bool { shop.isOpen ?? true }

    private var favSubtitle: String? {
        if let c = shop.category, !c.isEmpty { return c }
        // Паритет с Android: сначала тип словами, затем адрес.
        if let t = orgTypeLabel(shop.type) { return t }
        if let a = shop.address, !a.isEmpty { return a }
        return nil
    }
    private var favTime: String? {
        if let t = shop.deliveryTime, !t.isEmpty { return t }
        guard let m = shop.avgCookTime, m > 0 else { return nil }
        return "\(m)–\(m + 10) мин"
    }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                PhotoPlaceholder(url: API.imageURL(shop.cover ?? shop.banner ?? shop.logo),
                                 label: "ОБЛОЖКА", radius: 0, tone: tone)
                    .frame(height: 120).frame(maxWidth: .infinity).clipped()
                    .opacity(isOpen ? 1 : 0.55)   // закрытую приглушаем
                    .overlay(alignment: .topLeading) {
                        StatusPill(text: isOpen ? "Открыто" : "Закрыто",
                                   kind: isOpen ? .open : .cancel, solid: true).padding(11)
                    }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(shop.name ?? "—")
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundStyle(YMColor.text).lineLimit(1)
                        Spacer(minLength: 8)
                        if let r = shop.rating, r > 0 {
                            HStack(spacing: 4) {
                                Text("★").foregroundStyle(YMColor.accent)
                                Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                            }
                            .font(.system(size: 13.5, weight: .bold))
                        }
                    }
                    // Паритет с Android: category и delivery_time /favorites не отдаёт —
                    // строка была пустой. Берём адрес и avg_cook_time «25–35 мин».
                    HStack(spacing: 6) {
                        if let cat = favSubtitle {
                            Text(cat).font(.system(size: 13)).foregroundStyle(YMColor.muted).lineLimit(1)
                        }
                        if let t = favTime {
                            Circle().fill(YMColor.muted).frame(width: 3, height: 3)
                            Text(t).font(.system(size: 13)).foregroundStyle(YMColor.muted)
                        }
                    }
                }
                .padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 14)
                .opacity(isOpen ? 1 : 0.55)   // текст закрытой организации тоже тусклый
            }
            // Область нажатия — ровно карточка, ни точкой больше.
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shop.name ?? "Организация"), \(isOpen ? "открыто" : "закрыто")")
        .ymCard(radius: 20)
        // ♥ — СНАРУЖИ кнопки карточки. Внутри label это была кнопка в кнопке:
        // тап по сердечку срабатывал и на внешней кнопке, открывая карточку.
        .overlay(alignment: .topTrailing) {
            HeartButton(isFav: $isFav, size: 34, favColor: YMColor.statusCancel).padding(11)
        }
    }
}

/// Карточка избранного товара: фото 120pt, ♥, цена золотом.
private struct FavProductCard: View {
    let product: Product
    var tone: Int = 0
    @Binding var isFav: Bool
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                PhotoPlaceholder(url: API.imageURL(product.photo), label: "ФОТО", radius: 0, tone: tone)
                    .frame(height: 120).frame(maxWidth: .infinity).clipped()
                VStack(alignment: .leading, spacing: 4) {
                    Text(product.name ?? "—")
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundStyle(YMColor.text).lineLimit(1)
                    // П-22.3: заведение товара (поле необязательное).
                    if let sn = product.shopName?.trimmingCharacters(in: .whitespaces), !sn.isEmpty {
                        Text(sn)
                            .font(.system(size: 12.5))
                            .foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        Text(Money.format(Money.parse(product.price)))
                            .font(.system(size: 14, weight: .heavy))
                            .foregroundStyle(YMColor.accent)
                        if let old = product.oldPriceAny, old > (product.price ?? 0) {
                            Text(Money.format(Money.parse(old)))
                                .font(.system(size: 12))
                                .strikethrough()
                                .foregroundStyle(YMColor.muted)
                        }
                    }
                }
                .padding(.horizontal, 15).padding(.top, 12).padding(.bottom, 14)
            }
            // Область нажатия — ровно карточка, ни точкой больше.
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(product.name ?? "Товар")
        .ymCard(radius: 20)
        // ♥ — СНАРУЖИ кнопки карточки (см. FavOrgCard).
        .overlay(alignment: .topTrailing) {
            HeartButton(isFav: $isFav, size: 34, favColor: YMColor.statusCancel).padding(11)
        }
    }
}
