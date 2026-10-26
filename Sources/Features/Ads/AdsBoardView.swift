//
//  AdsBoardView.swift — доска объявлений: лента (нижняя вкладка «Объявления»)
//
//  Контракт (routes/ads.php), 1:1 с сайтом и Android:
//    • GET api/v1/ads/categories → категории с ЦЕНОЙ размещения (наследование
//      «подкатегория → родитель → настройки» сервер уже применил)
//    • GET api/v1/ads            → лента с фильтрами и постраничной подгрузкой
//
//  Вакансии магазинов (продавцы заводят их в кабинете, GET api/v1/jobs) в
//  рубрике «Вакансии»/«Работа» показываются над объявлениями — те же карточки,
//  что в «Профиль → Вакансии»; нажатие открывает вакансию с откликом.
//
//  Деньги — Decimal через @LenientDecimal и Money.format, никогда не Double.
//  Токены YM.*, light+dark, Dynamic Type.
//

import SwiftUI

@MainActor
final class AdsBoardViewModel: ObservableObject {
    @Published var cats: [AdCategory] = []
    @Published var items: [AdCard] = []
    @Published var loading = true
    @Published var loadingMore = false
    @Published var error: String?
    @Published var enabled = true
    @Published var total = 0
    @Published var query = ""
    @Published var categoryId = 0
    /// Режим «Избранное»: та же лента, но из api/v1/ads/favorites. Сердечко на
    /// карточке было, а посмотреть сохранённое было негде.
    @Published var favOnly = false
    /// Вакансии магазинов для рубрики «Вакансии»: nil — ещё не загружены.
    /// Грузим один раз, поиск фильтрует на месте; ошибка объявлениям не мешает.
    @Published var shopJobs: [Job]?
    @Published var jobsExpanded = false
    /// А97: идёт загрузка вакансий — «Все» не спешит с «Объявлений пока нет».
    @Published private(set) var jobsLoading = false

    private var page = 1
    private var pages = 1
    private var searchTask: Task<Void, Never>?
    /// Обрезанный текст, под который уже запущена перезагрузка (см. searchChanged).
    private var searchedQuery = ""
    /// Номер последней перезагрузки: ответ на старый фильтр (или «ещё» от
    /// старого списка) после смены категории не должен попасть в новый список.
    private var gen = 0

    /// Выбранная корневая категория — чтобы показать её подкатегории.
    var activeRoot: AdCategory? {
        cats.first { $0.stableId == categoryId }
            ?? cats.first { root in (root.children ?? []).contains { $0.stableId == categoryId } }
    }

    /// .task срабатывает на КАЖДОЕ появление экрана: возврат из объявления
    /// обрезал догруженные страницы до первой и прокрутка прыгала.
    private var started = false
    /// Лента хоть раз ответила (успехом или ошибкой) — см. load(reset:).
    private var everLoaded = false
    /// Для какого фильтра (избранное|рубрика|поиск) сейчас лежат items.
    private var shownKey = ""
    private var filterKey: String { "\(favOnly)|\(categoryId)|\(query)" }
    /// Поиск или рубрика заданы — ошибку показываем под полем поиска, а не
    /// во весь экран (иначе поле пропадало вместе с клавиатурой).
    var hasFilter: Bool { !favOnly && (!query.isEmpty || categoryId != 0) }

    /// А97: «Все» (categoryId = 0) — тоже с вакансиями магазинов, как рубрика «Работа».
    var showJobs: Bool { enabled && !favOnly && (categoryId == 0 || isJobsAdCategory(cats, categoryId)) }
    /// «Все»: вакансии ещё грузятся (рубрика «Работа» — как раньше).
    var jobsPending: Bool { categoryId == 0 && showJobs && shopJobs == nil && jobsLoading }

    var visibleJobs: [Job] {
        guard showJobs else { return [] }
        let all: [Job] = shopJobs ?? []
        let q: String = query.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return all }
        // Простыми шагами, без длинной цепочки `||` с `??`: Xcode 26 такие
        // выражения не успевает проверить (сборка 74).
        var out: [Job] = []
        for j in all {
            let hay: String = joinedNonEmpty([j.title, j.shop, j.category], separator: " ").lowercased()
            if hay.contains(q) { out.append(j) }
        }
        return out
    }

    /// Город из настроек → пусто — вся площадка (как в «Профиль → Вакансии»).
    func loadJobsIfNeeded(force: Bool = false) async {
        guard showJobs, !jobsLoading, shopJobs == nil || force else { return }
        jobsLoading = true
        defer { jobsLoading = false }
        let cityId = Session.shared.cityId
        do {
            var list: [Job] = try await API.shared.allPages("api/v1/jobs",
                query: cityId.map { ["city_id": String($0)] } ?? [:]) { (j: Job) in j.id }
            if list.isEmpty, cityId != nil {
                list = try await API.shared.allPages("api/v1/jobs") { (j: Job) in j.id }
            }
            shopJobs = list
        } catch {
            // Нет сети — попробуем при следующем выборе рубрики или обновлении.
        }
    }

    func start() async {
        guard !started else {
            // Вернулись из объявления в «Избранных»: там могли снять сердечко,
            // а снятое объявление оставалось в списке до обновления жестом.
            // Догруженные «Показать ещё» страницы не обрезаем до первой.
            if favOnly && page == 1 { await load(reset: true) }
            return
        }
        started = true
        if let r = try? await API.shared.adCategories() {
            cats = r.categories ?? []
            enabled = r.enabled ?? true
        } else {
            // Категории не пришли (нет сети) — при следующем появлении попробуем
            // снова, иначе чипы рубрик не появлялись до перезапуска.
            started = false
        }
        // А97: вакансии магазинов для «Все» — параллельно с лентой.
        async let jobs: Void = loadJobsIfNeeded()
        await load(reset: true)
        await jobs
        if Task.isCancelled { started = false }   // ушли до ответа — при возврате загрузим снова
    }

    func load(reset: Bool) async {
        // Двойной тап «Показать ещё» раньше грузил одну страницу дважды:
        // дубли id в ForEach и пропуск следующей страницы.
        if !reset && loadingMore { return }
        // Скелетон — только до первого ответа. Раньше при пустой выдаче каждая
        // буква в поиске (или смена рубрики) включала скелетон, а он заменяет
        // весь экран вместе с полем поиска: клавиатура пряталась посреди ввода.
        if reset { gen += 1; loadingMore = false; loading = items.isEmpty && (!everLoaded || error != nil); if items.isEmpty { error = nil }; page = 1 } else { loadingMore = true }
        let my = gen
        let key = filterKey
        do {
            let next = reset ? 1 : page + 1
            let r = favOnly
                ? try await API.shared.adFavorites(page: next)
                : try await API.shared.ads(categoryId: categoryId, q: query, page: next)
            guard my == gen else { return }
            enabled = r.enabled ?? true
            total = r.total ?? 0
            pages = max(1, r.pages ?? 1)
            let fresh = r.items ?? []
            // Новое объявление между догрузками сдвигает страницы: без фильтра
            // один id попадал в ForEach дважды.
            let known = Set(items.compactMap(\.id))
            items = reset ? fresh : items + fresh.filter { a in a.id.map { !known.contains($0) } ?? true }
            if !reset { page += 1 }
            if reset { shownKey = key }
            error = nil
            everLoaded = true
        } catch is CancellationError {
        } catch {
            guard my == gen else { return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить"
            // Сменили рубрику/поиск, а запрос упал: раньше под новым фильтром
            // оставались объявления прежнего, будто это найденное. Обновление
            // того же фильтра (жест) список не стирает.
            if reset && key != shownKey { items = []; total = 0; pages = 1; shownKey = key }
            everLoaded = true
        }
        guard my == gen else { return }
        loading = false
        loadingMore = false
    }

    var canLoadMore: Bool { page < pages }

    /// Поиск с задержкой: печатают быстро, а запрос нужен один.
    func searchChanged() {
        // Пробел по краям запрос не меняет: раньше лента перезагружалась тем же
        // поиском (и обрывала уже идущий). Сравниваем обрезанный текст.
        let key = query.trimmingCharacters(in: .whitespaces)
        if key == searchedQuery, error == nil { return }   // после ошибки — пробуем снова, как раньше
        searchedQuery = key
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            if Task.isCancelled { return }
            await self?.load(reset: true)
        }
    }

    func pick(_ id: Int) {
        categoryId = id
        Task { await load(reset: true) }
        Task { await loadJobsIfNeeded() }
    }

    /// Переключить ленту «все / избранные». Поиск и категорию сбрасываем:
    /// в избранном фильтров нет.
    func toggleFavorites() {
        favOnly.toggle()
        // Поиск сброшен здесь же и лента грузится ниже — отложенный поиск по
        // onChange(query) повторял ту же загрузку через 0,45 с.
        searchTask?.cancel(); searchedQuery = ""
        query = ""; categoryId = 0
        Task { await load(reset: true) }
        // А97: из «Избранных» вернулись в общую ленту («Все») — вакансии нужны снова.
        Task { await loadJobsIfNeeded() }
    }
}

struct AdsBoardView: View {
    @StateObject private var vm = AdsBoardViewModel()
    @State private var path = NavigationPath()
    @State private var showForm = false
    /// Подача объявления и «Мои» требуют входа. Гость раньше заполнял всю
    /// форму и получал «Сессия истекла», а «Мои» — ошибку с бесполезным «Повторить».
    @EnvironmentObject private var session: Session
    @State private var showAuth = false
    /// Что гость хотел сделать до входа. Раньше после входа он оказывался на
    /// ленте и нажимал «Подать объявление» / «Мои» второй раз.
    private enum AfterAuth { case form, my }
    @State private var afterAuth: AfterAuth?

    private let columns = [GridItem(.flexible(), spacing: YMSpace.md), GridItem(.flexible(), spacing: YMSpace.md)]

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .bottom) {
                content
                if vm.enabled {
                    Button {
                        if session.isLoggedIn { showForm = true } else { afterAuth = .form; showAuth = true }
                    } label: {
                        Label("Подать объявление", systemImage: "plus")
                            .font(YMFont.headline)
                            .foregroundStyle(YMColor.onAccent)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 22)
                            .background(
                                LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                               startPoint: .leading, endPoint: .trailing),
                                in: Capsule()
                            )
                    }
                    .padding(.bottom, YMSpace.lg)
                }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(vm.favOnly ? "Избранные" : "Объявления")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Избранное доступно только вошедшим: ручка требует токен.
                if session.isLoggedIn {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button {
                            Haptics.selection()
                            vm.toggleFavorites()
                        } label: {
                            Image(systemName: vm.favOnly ? "heart.fill" : "heart")
                        }
                        .accessibilityLabel(vm.favOnly ? "Все объявления" : "Избранные объявления")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        if session.isLoggedIn { path.append(AdsRoute.my) } else { afterAuth = .my; showAuth = true }
                    } label: { Text("Мои") }
                }
            }
            .navigationDestination(for: AdsRoute.self) { route in
                switch route {
                case .my: MyAdsView()
                case .detail(let id): AdDetailView(adId: id)
                case .job(let id): JobDetailView(jobId: id)
                }
            }
            .sheet(isPresented: $showForm) {
                AdFormView(editAdId: 0) { newId in
                    showForm = false
                    path.append(AdsRoute.detail(newId))
                    // Лента под объявлением грузится один раз: после «Назад»
                    // только что опубликованного объявления в ней не было.
                    Task { await vm.load(reset: true) }
                }
            }
            .task { await vm.start() }
            // Push «объявление скоро уйдёт в архив» (ad_id): раньше открывалась
            // общая лента, а «Продлить» есть только в «Мои» — туда и ведём.
            .onAppear { consumePushIntent() }
            .onReceive(NotificationCenter.default.publisher(for: AdsPushIntent.note)) { _ in consumePushIntent() }
            // Вышли из аккаунта в режиме «Избранные» — ручка избранного отвечает
            // 401, и лента застревала на ошибке. Возвращаем общую ленту.
            .onChange(of: session.isLoggedIn) { logged in
                if !logged && vm.favOnly { vm.toggleFavorites() }
            }
        }
        // Вход — отдельной шторкой на самом стеке: шторка формы висит уровнем ниже.
        // Шторка входа закрылась: вошли — продолжаем начатое (форма открывается
        // уже после закрытия шторки, иначе вторая шторка не показалась бы).
        .sheet(isPresented: $showAuth, onDismiss: {
            let pending = afterAuth
            afterAuth = nil
            guard session.isLoggedIn, let next = pending else { return }
            switch next {
            case .form: showForm = true
            case .my:   path.append(AdsRoute.my)
            }
        }) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false })
            }
            .environmentObject(session)
        }
    }

    /// «Мои» поверх того, что открыто: стек не сбрасываем — открытые
    /// экраны (и их несохранённое) остаются под ним.
    private func consumePushIntent() {
        guard AdsPushIntent.take(), session.isLoggedIn else { return }
        path.append(AdsRoute.my)
    }

    @ViewBuilder
    private var content: some View {
        if !vm.enabled {
            AdsEmptyView(title: "Доска объявлений пока не включена",
                         subtitle: "Заходите позже — раздел скоро откроется.")
        } else if vm.loading && !vm.hasFilter {
            AdsSkeletonView()
        } else if let e = vm.error, vm.items.isEmpty, !vm.hasFilter, vm.visibleJobs.isEmpty, !vm.jobsPending {
            ErrorRetryView(message: e) { Task { await vm.load(reset: true) } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: YMSpace.md) {
                    if !vm.favOnly {
                        searchField
                        categoryRow
                    }
                    // Ошибка при уже показанном списке (догрузка, обновление
                    // жестом) раньше не была видна вовсе; при поиске/рубрике —
                    // под полем, чтобы не прятать клавиатуру.
                    if let e = vm.error, !vm.loading {
                        HStack(alignment: .firstTextBaseline, spacing: YMSpace.sm) {
                            Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            Spacer(minLength: 0)
                            if vm.items.isEmpty {
                                Button("Повторить") { Task { await vm.load(reset: true) } }
                                    .font(YMFont.caption)
                            }
                        }
                    }
                    if !vm.visibleJobs.isEmpty {
                        shopJobsSection
                    }
                    if vm.items.isEmpty && (vm.loading || vm.jobsPending) {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, YMSpace.xl)
                    } else if vm.items.isEmpty && vm.error != nil {
                        EmptyView()
                    } else if vm.items.isEmpty && !vm.visibleJobs.isEmpty {
                        EmptyView()
                    } else if vm.items.isEmpty {
                        // Без поиска и рубрики пустая лента — это «объявлений ещё нет»
                        // (новый город, доска только открылась), а не «ничего не нашлось,
                        // измените запрос», которого человек не вводил.
                        AdsEmptyView(
                            title: vm.favOnly ? "В избранном пусто"
                                : (vm.hasFilter ? "Ничего не нашлось" : "Объявлений пока нет"),
                            subtitle: vm.favOnly
                                ? "Нажмите сердечко на карточке объявления — оно появится здесь."
                                : (vm.hasFilter ? "Измените запрос или подайте своё объявление."
                                   : "Станьте первым — кнопка «Подать объявление» внизу.")
                        )
                            .frame(height: 260)
                    } else {
                        if !vm.visibleJobs.isEmpty {
                            Text("Объявления")
                                .font(YMFont.headline).foregroundStyle(YMColor.text)
                                .padding(.top, YMSpace.sm)
                        }
                        if vm.total > 0 {
                            Text("Найдено: \(vm.total)")
                                .font(YMFont.caption).foregroundStyle(YMColor.muted)
                        }
                        LazyVGrid(columns: columns, spacing: YMSpace.md) {
                            ForEach(vm.items) { ad in
                                NavigationLink(value: AdsRoute.detail(ad.stableId)) {
                                    AdGridCard(ad: ad)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        if vm.canLoadMore {
                            Button {
                                Task { await vm.load(reset: false) }
                            } label: {
                                HStack { Spacer()
                                    if vm.loadingMore { ProgressView() } else { Text("Показать ещё") }
                                    Spacer() }
                            }
                            .padding(.top, YMSpace.sm)
                        }
                    }
                }
                .padding(.horizontal, YMSpace.lg)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, 96)   // место под кнопку «Подать объявление»
            }
            .refreshable {
                await vm.load(reset: true)
                await vm.loadJobsIfNeeded(force: true)
            }
        }
    }

    /// Вакансии магазинов: первые три, остальные — по кнопке.
    private var shopJobsSection: some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Вакансии магазинов · \(vm.visibleJobs.count)")
                .font(YMFont.headline).foregroundStyle(YMColor.text)
            ForEach(vm.jobsExpanded ? vm.visibleJobs : Array(vm.visibleJobs.prefix(3))) { job in
                NavigationLink(value: AdsRoute.job(job.id)) {
                    JobCard(job: job)
                }
                .buttonStyle(.plain)
            }
            if vm.visibleJobs.count > 3 && !vm.jobsExpanded {
                Button {
                    vm.jobsExpanded = true
                } label: {
                    HStack { Spacer(); Text("Показать все вакансии (\(vm.visibleJobs.count))"); Spacer() }
                }
                .font(YMFont.callout)
            }
        }
    }

    /// Сервер ищет только по запросу от 3 символов, короче — отдаёт всю ленту
    /// (routes/ads.php): «Найдено: N» по 1–2 буквам выглядело как результат поиска.
    private var queryTooShort: Bool {
        let n = vm.query.trimmingCharacters(in: .whitespaces).count
        return n > 0 && n < 3
    }

    private var searchField: some View {
        VStack(alignment: .leading, spacing: 4) {
            searchBox
            if queryTooShort {
                Text("Поиск — от 3 символов")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
        }
    }

    private var searchBox: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(YMColor.muted)
            TextField("Что ищете?", text: $vm.query)
                .textInputAutocapitalization(.never)
                // Один параметр: двухпараметрический onChange — iOS 17, цель 16.0.
                .onChange(of: vm.query) { _ in vm.searchChanged() }
            if !vm.query.isEmpty {
                Button { vm.query = ""; vm.searchChanged() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(YMColor.muted)
                }
            }
        }
        .padding(.horizontal, YMSpace.md)
        .padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }

    private var categoryRow: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMSpace.sm) {
                    AdCatChip(title: "Все", symbol: "square.grid.2x2.fill", selected: vm.categoryId == 0) { vm.pick(0) }
                    ForEach(vm.cats) { cat in
                        AdCatChip(
                            title: cat.name ?? "",
                            symbol: adCategorySymbol(cat.icon, cat.name ?? ""),
                            selected: vm.activeRoot?.stableId == cat.stableId
                        ) { vm.pick(cat.stableId) }
                    }
                }
            }
            if let kids = vm.activeRoot?.children, !kids.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.sm) {
                        ForEach(kids) { k in
                            AdCatChip(title: k.name ?? "", symbol: nil, selected: vm.categoryId == k.stableId) {
                                vm.pick(k.stableId)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Push/строка ленты уведомлений об СВОЁМ объявлении (ad_id: скоро в архив,
/// снято) — открыть «Мои». Ставит вызывающий вместе с переходом на вкладку
/// «Объявления»; забирает AdsBoardView (при появлении или по note). Старше
/// 15 с не исполняется — чтобы не сработать позже, при обычном заходе.
enum AdsPushIntent {
    static let note = Notification.Name("ym.adsPushIntent")
    private static var pendingAt: Date?

    static func openMyAds() {
        pendingAt = Date()
        NotificationCenter.default.post(name: note, object: nil)
    }

    static func take() -> Bool {
        guard let at = pendingAt else { return false }
        pendingAt = nil
        return Date().timeIntervalSince(at) < 15
    }
}

/// Куда ходим из ленты. Отдельный тип, чтобы NavigationPath был типизированным.
enum AdsRoute: Hashable {
    case my
    case detail(Int)
    /// Вакансия магазина из рубрики «Вакансии».
    case job(Int)
}

/// Рубрика, где кроме объявлений показываем вакансии магазинов. Рубрики заводит
/// администратор, отдельного признака нет — узнаём по названию/slug: «Вакансии»
/// (vakansii, vacancy, jobs) — сама рубрика или подрубрика внутри выбранной;
/// корневая «Работа» без подрубрик — тоже. «Резюме» и «Ищу работу» — нет.
/// Паритет с Android (AdsScreen.isJobsCategory).
private func isVacancyAdCategory(_ c: AdCategory) -> Bool {
    let n: String = (c.name ?? "").lowercased()
    let s: String = (c.slug ?? "").lowercased()
    if n.contains("ваканс") { return true }
    if s.contains("vakans") || s.contains("vacanc") { return true }
    return s == "jobs" || s == "job"
}

func isJobsAdCategory(_ cats: [AdCategory], _ id: Int) -> Bool {
    guard id != 0 else { return false }
    if let root = cats.first(where: { $0.stableId == id }) {
        let kids = root.children ?? []
        if isVacancyAdCategory(root) || kids.contains(where: isVacancyAdCategory) { return true }
        if kids.isEmpty {
            let n: String = (root.name ?? "").lowercased()
            let s: String = (root.slug ?? "").lowercased()
            let i: String = (root.icon ?? "").lowercased()
            if n.contains("работ") || s.contains("rabot") { return true }
            return s == "work" || i == "briefcase"
        }
        return false
    }
    let child = cats.flatMap { $0.children ?? [] }.first { $0.stableId == id }
    return child.map(isVacancyAdCategory) ?? false
}

/// Иконка корневой категории объявлений.
///
/// Сервер хранит имя иконки набора Phosphor (поле `icon`, засевается в
/// tools/migrate_ads.php). В iOS такого набора нет, поэтому переводим имя в
/// ближайший SF Symbol. Если администратор заведёт категорию без иконки —
/// пробуем угадать по названию, в самом конце отдаём общий значок: экран не
/// должен зависеть от содержимого справочника.
func adCategorySymbol(_ icon: String?, _ name: String) -> String {
    switch (icon ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
    case "car", "truck", "motorcycle":            return "car.fill"
    case "house", "buildings", "building":        return "house.fill"
    case "briefcase", "suitcase":                 return "briefcase.fill"
    case "wrench", "hammer", "toolbox":           return "wrench.and.screwdriver.fill"
    case "tshirt", "dress", "baby":               return "tshirt.fill"
    case "sofa", "armchair", "plant":             return "leaf.fill"
    case "device-mobile", "devicemobile", "laptop", "desktop": return "iphone"
    case "dog", "cat", "paw-print":               return "pawprint.fill"
    case "bicycle", "bike", "football":           return "bicycle"
    case "guitar":                                return "guitars.fill"
    case "gift", "hand-heart":                    return "gift.fill"
    case "game-controller", "gamepad":            return "gamecontroller.fill"
    default: break
    }
    let n = name.lowercased()
    if n.contains("транспорт") || n.contains("авто")      { return "car.fill" }
    if n.contains("недвижим")  || n.contains("жиль")      { return "house.fill" }
    if n.contains("работ")     || n.contains("ваканс")    { return "briefcase.fill" }
    if n.contains("услуг")                                { return "wrench.and.screwdriver.fill" }
    if n.contains("вещи")      || n.contains("одежд")     { return "tshirt.fill" }
    if n.contains("дом")       || n.contains("дач")       { return "leaf.fill" }
    if n.contains("электрон")  || n.contains("техник")    { return "iphone" }
    if n.contains("животн")                               { return "pawprint.fill" }
    if n.contains("хобби")     || n.contains("отдых") || n.contains("спорт") { return "bicycle" }
    if n.contains("даром")     || n.contains("подар")     { return "gift.fill" }
    return "tag.fill"
}

/// Чип категории: иконка в кружке + название. Цену размещения здесь не
/// показываем — покупателю она не нужна, её видно при подаче объявления.
/// У подкатегорий иконки нет: symbol == nil — обычный текстовый чип.
struct AdCatChip: View {
    let title: String
    let symbol: String?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: YMSpace.sm) {
                if let symbol {
                    ZStack {
                        Circle().fill(selected ? Color.white.opacity(0.22) : YMColor.accent.opacity(0.12))
                        Image(systemName: symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(selected ? Color.white : YMColor.accent)
                    }
                    .frame(width: 28, height: 28)
                }
                Text(title)
                    .font(YMFont.callout)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
            }
            .padding(.leading, symbol == nil ? YMSpace.md : 6)
            .padding(.trailing, YMSpace.md)
            .padding(.vertical, symbol == nil ? YMSpace.sm : 6)
            .foregroundStyle(selected ? (symbol == nil ? YMColor.accent : Color.white) : YMColor.text)
            .background(
                selected
                    ? (symbol == nil ? YMColor.accent.opacity(0.16) : YMColor.accent)
                    : YMColor.surface,
                in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                    .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct AdGridCard: View {
    let ad: AdCard

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(YMColor.surface2)
                // API.imageURL — сервер отдаёт путь от корня сайта, нужна база.
                if let u = API.imageURL(ad.photoURL) {
                    CachedAsyncImage(url: u) { phase in
                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                        else { Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(YMColor.muted) }
                    }
                } else {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(YMColor.muted)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fill)
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                if (ad.photosCount ?? 0) > 1 {
                    Text("\(ad.photosCount ?? 0)")
                        .font(YMFont.caption2).foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(ad.priceText ?? "").font(YMFont.headline).foregroundStyle(YMColor.text)
                Text(ad.title ?? "").font(YMFont.body).foregroundStyle(YMColor.text).lineLimit(2)
                Text(joinedNonEmpty([ad.categoryName, ad.city], separator: " · "))
                    .font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.md)
        }
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1)
        )
    }
}

struct AdsSkeletonView: View {
    var body: some View {
        VStack(spacing: YMSpace.md) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: YMSpace.md) {
                    SkeletonBox(radius: YMRadius.card).frame(height: 190)
                    SkeletonBox(radius: YMRadius.card).frame(height: 190)
                }
            }
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

struct AdsEmptyView: View {
    let title: String
    let subtitle: String
    /// Кнопка следующего шага («Подать объявление»). nil — без кнопки, как раньше.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: YMSpace.sm) {
            Image(systemName: "megaphone").font(.system(size: 42)).foregroundStyle(YMColor.muted)
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(subtitle).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
            if let t = actionTitle, let action {
                Button { Haptics.light(); action() } label: { Text(t) }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .padding(.top, YMSpace.md)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(YMSpace.xl)
    }
}
