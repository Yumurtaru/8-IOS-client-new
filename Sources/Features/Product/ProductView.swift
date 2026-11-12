import SwiftUI

//
//  ProductView.swift — карточка товара (product) / услуги (service).
//  Дизайн 1:1 с ProductPhone.dc.html (kind = product | service).
//
//  ПУБЛИЧНЫЕ INIT-СИГНАТУРЫ (для централизованной навигации):
//    ProductView(id: Int)                              // товар по id (deep-link/каталог)
//    ProductView(product: Product)                     // товар с seed-данными из списка
//    ProductView(service: ServiceItem, shopName: String?)  // услуга (режим записи)
//
//  API (реальные методы старого клиента):
//    GET  api/v1/products/{id}              -> ProductDetail (+ modifierGroups)
//    GET  api/v1/services/{id}/slots        -> [Slot]
//    POST api/v1/appointments               <- AppointmentBody{slotId}
//
//  Добавление в корзину — через Cart.shared (single-store; конфликт магазина
//  разрешает Cart автоматически — диалог конфликта делает другой агент).
//  Деньги — только Decimal через Money. Токены — YM*.
//

// MARK: - ViewModel

@MainActor
final class ProductViewModel: ObservableObject {
    enum Mode { case product, service }

    @Published var detail: ProductDetail?
    @Published var slots: [Slot] = []
    @Published var loading = true
    @Published var error: String?
    @Published var booked = false
    /// Похожие товары: GET api/v1/products/{id}/recommended -> [Product].
    /// Пусто/ошибка — секция просто не рисуется, карточку не ломает.
    @Published var recommended: [Product] = []
    /// Адрес визита для выездной услуги (location_type = at_client).
    /// Берём адрес по умолчанию из профиля: сервер отклоняет запись без адреса
    /// (422), а формы ввода на карточке услуги нет — запись с этого экрана
    /// раньше всегда падала. Если адреса в профиле нет, остаётся nil и сервер
    /// вернёт понятное сообщение «укажите улицу и дом».
    @Published var visitAddress: VisitAddress?

    let mode: Mode
    let productId: Int?
    let seedProduct: Product?
    let service: ServiceItem?
    let serviceShopName: String?

    init(id: Int) { mode = .product; productId = id; seedProduct = nil; service = nil; serviceShopName = nil }
    init(product: Product) { mode = .product; productId = product.id; seedProduct = product; service = nil; serviceShopName = nil }
    init(service: ServiceItem, shopName: String?) {
        mode = .service; productId = nil; seedProduct = nil
        self.service = service; self.serviceShopName = shopName
    }

    /// Похожие товары (отдельно от детали: повторяется, если в прошлый раз не пришли).
    func loadRecommended() async {
        guard mode == .product, let id = productId else { return }
        if let list: [Product] = try? await API.shared.list("api/v1/products/\(id)/recommended") {
            recommended = list.filter { $0.id != id }
        }
    }

    func load() async {
        loading = true; error = nil
        switch mode {
        case .product:
            guard let id = productId else { error = "Нет данных товара"; loading = false; return }
            do {
                let d: ProductDetail = try await API.shared.get("api/v1/products/\(id)")
                detail = d
                // «Недавно смотрели» во вкладке «Поиск» читает RecentStore, но
                // записи туда не делал никто — раздел всегда был пустым.
                SpotlightIndex.indexProduct(id: d.id, name: d.name, shopName: d.shopName)
                Track.productOpened(id: d.id, name: d.name)
                RecentStore.add(RecentProduct(id: d.id, name: d.name ?? "",
                                              photo: d.photos?.first?.pathWebp,
                                              price: d.price, shopId: d.shopId, shopName: d.shopName))
            } catch is CancellationError {
            } catch {
                self.error = error.localizedDescription
            }
            // Похожие товары грузим отдельно: ошибка/пусто не мешает карточке товара.
            await loadRecommended()
        case .service:
            guard let s = service else { error = "Нет данных услуги"; loading = false; return }
            // Слоты записи. Отсутствие слотов — не ошибка (услуга без онлайн-записи).
            slots = (try? await API.shared.list("api/v1/services/\(s.id)/slots")) ?? []
            // Только для выезда: лишний запрос обычной услуге не нужен.
            if s.isAtClient { visitAddress = await defaultVisitAddress() }
        }
        loading = false
    }

    /// Адрес по умолчанию из профиля -> форма адреса визита.
    /// Ошибку глотаем: без адреса запись просто не пройдёт, но экран не ломается.
    private func defaultVisitAddress() async -> VisitAddress? {
        guard Session.shared.isLoggedIn else { return nil }
        let list: [Address] = (try? await API.shared.list("api/v1/profile/addresses")) ?? []
        guard let a = list.first(where: { $0.isDefaultBool }) ?? list.first else { return nil }
        var v = VisitAddress()
        // value — ТОЛЬКО город: сервер сам склеивает «город, улица, д. N».
        v.value     = a.city ?? Session.shared.cityName ?? ""
        v.street    = a.street ?? ""
        v.house     = a.house ?? ""
        v.apartment = a.apartment ?? ""
        v.entrance  = a.entrance ?? ""
        v.floor     = a.floor ?? ""
        v.lat       = a.lat
        v.lng       = a.lng
        return v.isComplete ? v : nil
    }

    /// Запись на выбранный слот.
    func book(slot: Slot) async -> Bool {
        do {
            let atClient = service?.isAtClient ?? false
            try await API.shared.postVoid("api/v1/appointments",
                                          body: AppointmentBody(slotId: slot.id,
                                                                address: atClient ? visitAddress : nil))
            booked = true
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }
}

// MARK: - ProductView

struct ProductView: View {
    @StateObject private var vm: ProductViewModel
    @StateObject private var cart = Cart.shared
    @EnvironmentObject private var coord: NavCoordinator
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFav = false
    // Флаг: isFav меняется программно (загрузка с сервера) — не слать тоггл в ответ.
    @State private var favSyncing = false
    /// Запрос избранного ещё идёт — новый тап по ♥ игнорируем (как на Главной):
    /// двойной тап слал POST и DELETE разом, и на сервере оставалось не то, что на экране.
    @State private var favBusy = false
    /// ♥ не сохранилось — причина коротким сообщением (раньше откат был молча).
    @State private var favError: String?
    @State private var photoIndex = 0
    @State private var photoVisible = false      // фото проявляется из прозрачности (0,3 с)
    @State private var descExpanded = false      // «Всё описание»
    @State private var requiredFlash = false     // тап по неактивной «В корзину»: подпись группы краснеет
    @State private var descShownH: CGFloat = 0
    @State private var descFullH: CGFloat = 0
    @State private var descTruncated = false
    @State private var heartBump = false
    @State private var heartSparkKey = 0
    @State private var flashTick = 0             // триггер прокрутки к невыбранной группе
    @Environment(\.colorScheme) private var scheme

    // product state
    @State private var selectedRadio: [Int: Int] = [:] // группа → выбранная радио-опция (у каждой группы свой выбор)
    @State private var checkedAddons: Set<Int> = []    // id выбранных чекбоксов (Добавить к блюду)
    @State private var qty: Double = 1
    @State private var added = false
    /// Гость нажал «Записаться» — сначала вход (запись требует аккаунта).
    @State private var showAuth = false
    // Весовой/дробный товар: выбранный вес-пресет (0.3 / 0.5 / 1 кг). Для штучных не используется.
    @State private var selectedWeight: Double = 0

    // service state
    @State private var selectedDay: Int = 0            // индекс дня
    @State private var selectedSlot: Int?              // id слота
    @State private var homeVisit = false

    /// Карточка открыта в шторке профиля («Избранное») или в «Жилье»: общий
    /// диалог «Начать новую корзину?» рисуется на корне вкладок ПОД шторкой —
    /// «В корзину» с товаром другого заведения молча ничего не делала. Тогда
    /// диалог показываем на самой карточке.
    @Environment(\.ymNestedPresentation) private var nested
    @State private var localConflict = false

    init(id: Int) { _vm = StateObject(wrappedValue: ProductViewModel(id: id)) }
    init(product: Product) { _vm = StateObject(wrappedValue: ProductViewModel(product: product)) }
    init(service: ServiceItem, shopName: String?) {
        _vm = StateObject(wrappedValue: ProductViewModel(service: service, shopName: shopName))
    }

    private let heroHeight: CGFloat = 360

    var body: some View {
        ZStack(alignment: .top) {
            YMUi.screenBg.ignoresSafeArea()

            if vm.loading && vm.detail == nil && vm.mode == .product {
                loadingState
            } else if let e = vm.error, vm.detail == nil, vm.mode == .product {
                errorState(e)
            } else {
                content
                bottomBar
            }
            topControls
        }
        .navigationBarHidden(true)
        // Причина отказа ♥ — над нижней кнопкой «В корзину».
        .errorToast($favError, bottom: 96)
        .cartConflictDialog(
            isPresented: $localConflict,
            currentShop: cart.shopName,
            newShop: vm.detail?.shopName,
            onConfirm: { if let d = vm.detail { commitAdd(d) } }
        )
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false })
            }
            .environmentObject(Session.shared)
        }
        // Деталь может прийти не с первой попытки (кнопка «Повторить» в ошибке
        // грузит её отдельно). Пресет веса и стартовое количество подбираем на
        // КАЖДОЕ появление детали: иначе после повторной загрузки весовой товар
        // оставался с нулевым весом, и в корзину уходило «× 0» по нулевой цене.
        // Предвыбор обязательных вариантов — тоже на появление детали: после
        // «Повторить» в ошибке он не выполнялся, и «В корзину» оставалась серой.
        .onChange(of: vm.detail?.id) { _ in syncQtyDefaults(); preselectRequired() }
        // Обязательные группы выбраны — красная подсветка снимается.
        .onChange(of: requiredChosen) { ok in if ok { requiredFlash = false } }
        .task {
            // Товар и рекомендации — один раз; избранное — при каждом появлении.
            if vm.detail == nil { await vm.load() }
            else if vm.recommended.isEmpty { await vm.loadRecommended() }
            syncQtyDefaults()
            preselectRequired()
            await loadFav()
        }
    }

    /// Обязательная радио-группа: предвыбираем первый вариант (как в Android).
    private func preselectRequired() {
        guard let d = vm.detail else { return }
        for g in d.modifierGroups ?? [] where g.isRequired == true
            && ((g.type ?? "") == "single" || (g.maxQty ?? 0) == 1) {
            if selectedRadio[g.id] == nil, let first = g.options?.first { selectedRadio[g.id] = first.id }
        }
    }

    // MARK: Избранное (через product-favorites, как в DiscoverView)

    /// id товара для избранного (детальный id → seed id).
    private var favTargetId: Int? { vm.productId ?? vm.detail?.id ?? vm.seedProduct?.id }

    /// Состояние сердечка из api/v1/product-favorites/ids (тот же механизм, что в DiscoverView).
    private func loadFav() async {
        guard vm.mode == .product, let id = favTargetId else { return }
        if let ids: [Int] = try? await API.shared.list("api/v1/product-favorites/ids") {
            let fav = ids.contains(id)
            await MainActor.run {
                favSyncing = true
                isFav = fav
                // Сброс на следующем тике: onChange(of: isFav) уже отработает при favSyncing == true.
                DispatchQueue.main.async { favSyncing = false }
            }
        }
    }

    /// Оптимистичный тоггл: POST/DELETE api/v1/product-favorites/{id}, откат при ошибке.
    private func toggleFav() {
        guard !favSyncing, let id = favTargetId else { return }
        let on = isFav
        favBusy = true
        Task {
            do {
                if on { try await API.shared.postVoid("api/v1/product-favorites/\(id)") }
                else  { try await API.shared.deleteVoid("api/v1/product-favorites/\(id)") }
            } catch {
                // Откат — программной установкой (favSyncing), как в loadFav. Раньше
                // откат снова срабатывал в onChange(of: isFav) и слал обратный запрос:
                // у гостя (401) или без сети сердечко мигало, а запросы шли без конца.
                await MainActor.run {
                    favSyncing = true
                    isFav.toggle()
                    DispatchQueue.main.async { favSyncing = false }
                    favError = error.userMessage
                }
            }
            await MainActor.run { favBusy = false }
        }
    }

    // MARK: Content

    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    gallery
                        .padding(.horizontal, YMForm.screenPadding)
                        .padding(.top, 8)
                    sheet
                }
            }
            // Тап по неактивной «В корзину» (не выбрана обязательная группа): прокрутка к группе.
            .onChange(of: flashTick) { _ in
                guard let id = missingRequiredGroupId else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: YMDur.requiredHint)) {
                    proxy.scrollTo("grp\(id)", anchor: .center)
                }
            }
        }
    }

    // MARK: Фото: крупное, на серой плитке, скругление 20, свайп + свои точки

    private var galleryPhotos: [String] {
        if vm.mode == .product {
            let ph = (vm.detail?.photos ?? []).compactMap { $0.pathWebp }
            if !ph.isEmpty { return ph }
            if let p = vm.seedProduct?.photo { return [p] }
            return [""]
        } else {
            return [vm.service?.name.map { _ in "" } ?? ""]
        }
    }

    private func photoPage(_ p: String, _ i: Int) -> some View {
        PhotoPlaceholder(url: API.imageURL(p.isEmpty ? nil : p),
                         // Подпись видна, когда фото нет: служебное «ГАЛЕРЕЯ · СВАЙП» из макета не показываем.
                         label: "ФОТО", radius: 0, tone: i, fit: true, maxPixel: 2000)
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var gallery: some View {
        let photos = galleryPhotos
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 340)
            .background(YMUi.photoBg)
            .overlay {
                Group {
                    if photos.count > 1 {
                        TabView(selection: $photoIndex) {
                            ForEach(Array(photos.enumerated()), id: \.offset) { i, p in
                                photoPage(p, i).tag(i)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                        .animation(reduceMotion ? nil : .easeOut(duration: YMDur.photoFade), value: photoIndex)
                    } else {
                        photoPage(photos.first ?? "", 0)
                    }
                }
                .opacity(photoVisible || reduceMotion ? 1 : 0)
                // Белый фон фото сливается с серой плиткой (умножение), как в плитке меню; в тёмной теме — нет.
                .blendMode(scheme == .dark ? .normal : .multiply)
            }
            .overlay(alignment: .bottom) {
                if photos.count > 1 { photoDots(count: photos.count).padding(.bottom, 10) }
            }
            .clipShape(RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
            .onAppear {
                if reduceMotion { photoVisible = true }
                else { withAnimation(.easeOut(duration: YMDur.photoFade)) { photoVisible = true } }
            }
    }

    /// Точки галереи: активная — тёмная вытянутая капсула, остальные — серые.
    private func photoDots(count: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == photoIndex ? YMUi.text : YMUi.textSecondary.opacity(0.45))
                    .frame(width: i == photoIndex ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: YMDur.sizeSwitch), value: photoIndex)
        .accessibilityHidden(true)
    }

    // MARK: Sheet

    private var sheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Короткая обязательная группа одиночного выбора (2–4 опции) — равные пилюли над названием.
            if let g = pillGroup { pillRow(g).padding(.top, 14) }

            // Название + ХАЛЯЛЬ.
            HStack(alignment: .center, spacing: 10) {
                Text(titleText)
                    .ymText(YMText.productTitle)
                    .foregroundStyle(YMUi.text)
                    .lineLimit(3)
                if isHalal { HalalBadge() }
                Spacer(minLength: 0)
            }
            .padding(.top, 14)
            if vm.mode == .product, let l = LikesText.recommend(vm.detail?.likesPercent) {
                Label(l, systemImage: "hand.thumbsup")
                    .ymIcon(13).foregroundStyle(YMUi.textSecondary)
                    .padding(.top, 4)
            }

            // ★рейтинг · метаданные (объём/вес/единица) — серым.
            HStack(spacing: 10) {
                if let r = ratingValue, r > 0 {
                    HStack(spacing: 5) {
                        Text("★").foregroundStyle(YMColor.accent)
                        Text(String(format: "%.1f", r)).foregroundStyle(YMUi.text)
                    }
                    .ymText(YMText.caption)
                }
                if let meta = metaText, !meta.isEmpty {
                    Text(meta)
                        .ymText(YMText.caption)
                        .foregroundStyle(YMUi.textSecondary)
                }
            }
            .padding(.top, 6)

            // Описание: 3 строки + «Всё описание».
            if let desc = descText, !desc.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(desc)
                        .ymText(YMText.description)
                        .lineSpacing(3)
                        .foregroundStyle(YMUi.textSecondary)
                        .lineLimit(descExpanded ? nil : 3)
                        // Факт обрезки: высота показанного текста против полного (скрытая копия без лимита).
                        .background(GeometryReader { g in
                            Color.clear
                                .onAppear { descShownH = g.size.height; updateDescTruncated() }
                                .onChange(of: g.size.height) { h in descShownH = h; updateDescTruncated() }
                        })
                        .background(
                            Text(desc)
                                .ymText(YMText.description)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .hidden()
                                .background(GeometryReader { g in
                                    Color.clear
                                        .onAppear { descFullH = g.size.height; updateDescTruncated() }
                                        .onChange(of: g.size.height) { h in descFullH = h; updateDescTruncated() }
                                })
                        )
                    if descTruncated || descExpanded {
                        Button { descExpanded.toggle() } label: {
                            Text(descExpanded ? "Свернуть" : "Всё описание")
                                .ymText(YMText.description)
                                .foregroundStyle(YMColor.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 10)
            }

            if vm.mode == .product {
                productSections
            } else {
                serviceSections
            }

            // Запас под нижнюю панель; с подсказкой «Выберите …» она выше.
            Color.clear.frame(height: missingRequiredGroup == nil ? 120 : 170)
        }
        .padding(.horizontal, YMForm.screenPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Пилюли короткой обязательной группы

    private func updateDescTruncated() {
        guard !descExpanded else { return }
        descTruncated = descFullH > descShownH + 1
    }

    private func isRadio(_ g: ModifierGroup) -> Bool {
        (g.type ?? "") == "single" || (g.maxQty ?? 0) == 1
    }

    /// Первая обязательная группа одиночного выбора с 2–4 короткими (≤ 12 символов) опциями.
    private var pillGroup: ModifierGroup? {
        guard vm.mode == .product, let d = vm.detail else { return nil }
        return (d.modifierGroups ?? []).first { g in
            let opts = g.options ?? []
            return g.isRequired == true && isRadio(g) && (2...4).contains(opts.count)
                && opts.allSatisfy { ($0.name ?? "").count <= 12 }
        }
    }

    private func pillRow(_ g: ModifierGroup) -> some View {
        HStack(spacing: 8) {
            ForEach(g.options ?? []) { opt in
                let sel = selectedRadio[g.id] == opt.id
                Button {
                    Haptics.selection()
                    selectedRadio[g.id] = opt.id
                } label: {
                    VStack(spacing: 0) {
                        Text(opt.name ?? "—")
                            .ymText(YMText.cardTitle)
                            .foregroundStyle(YMUi.text)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        if let pr = opt.price, pr > 0 {
                            Text("+\(Money.format(Money.dec(pr)))")
                                .ymText(YMText.caption)
                                .foregroundStyle(YMUi.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .padding(.vertical, 2)
                    .background(sel ? YMUi.card : YMUi.segmentBg, in: Capsule())
                    .overlay(Capsule().strokeBorder(sel ? YMUi.accentFill : Color.clear, lineWidth: 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
        .id("grp\(g.id)")
    }

    /// Группа обязательная и выбор в ней ещё не сделан (то же правило, что requiredChosen).
    private func isGroupMissing(_ g: ModifierGroup) -> Bool {
        guard g.isRequired == true else { return false }
        let opts = g.options ?? []
        if opts.isEmpty { return false }
        if isRadio(g) { return selectedRadio[g.id] == nil }
        let need = min(max(1, g.minQty ?? 1), opts.count)
        return opts.filter({ checkedAddons.contains($0.id) }).count < need
    }

    /// id первой обязательной группы без выбора (для прокрутки); nil — всё выбрано.
    private var missingRequiredGroupId: Int? {
        (vm.detail?.modifierGroups ?? []).first { isGroupMissing($0) }?.id
    }

    /// Тап по неактивной кнопке: подпись группы краснеет, экран прокручивается к ней.
    private func flashRequired() {
        Haptics.warning()
        withAnimation(reduceMotion ? nil : .easeOut(duration: YMDur.requiredHint)) { requiredFlash = true }
        flashTick += 1
    }

    /// Белая карточка группы добавок: заголовок, подпись правила, строки.
    @ViewBuilder private func groupCard<C: View>(_ g: ModifierGroup, title: String, caption: String?,
                                                 @ViewBuilder rows: () -> C) -> some View {
        let flash = requiredFlash && isGroupMissing(g)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .ymText(YMText.sectionTitle)
                .foregroundStyle(YMUi.text)
            if let caption {
                Text(caption)
                    .ymText(YMText.caption)
                    .foregroundStyle(flash ? YMColor.statusCancel : YMUi.textSecondary)
                    .animation(reduceMotion ? nil : .easeOut(duration: YMDur.requiredHint), value: flash)
            }
            VStack(spacing: 0) { rows() }.padding(.top, 6)
        }
        .padding(YMForm.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
        .id("grp\(g.id)")
        .padding(.top, YMForm.cardGap)
    }

    // MARK: Product sections (Размер порции / Добавить к блюду)

    /// O1: блок «Оптом дешевле» — строки «от 25 кг — 37 ₽/кг (−18%)».
    @ViewBuilder private var wholesaleBlock: some View {
        if let d = vm.detail, !wholesaleSteps.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(Wholesale.blockTitle)
                    .ymText(YMText.sectionTitle)
                    .foregroundStyle(YMUi.text)
                ForEach(wholesaleSteps, id: \.minQty) { s in
                    Text(Wholesale.tierRow(s, retail: Money.dec(d.price), unit: d.unit))
                        .ymText(YMText.body)
                        .foregroundStyle(YMUi.text)
                }
            }
            .padding(YMForm.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
            .padding(.top, YMForm.cardGap)
        }
    }

    @ViewBuilder private var productSections: some View {
        wholesaleBlock

        // Весовой товар с пресетами: ряд чипов (0.3 / 0.5 / 1 кг) с ценой за
        // выбранный вес. Без пресетов чипов нет — количество набирается «+/−».
        if let d = vm.detail, weightPresets(d).count >= 2 {
            weightSection(d)
        }

        let groups = vm.detail?.modifierGroups ?? []
        let pillId = pillGroup?.id
        // Радио-группа (Размер порции): type == "single" / isRequired. Группа в пилюлях над названием — не дублируется.
        let radioGroups = groups.filter { isRadio($0) && $0.id != pillId }
        // Чекбокс-группы (Добавить к блюду).
        let checkGroups = groups.filter { !isRadio($0) }

        ForEach(radioGroups) { g in
            groupCard(g, title: g.name ?? "Размер порции",
                      caption: g.isRequired == true ? "Выберите 1" : "Не обязательно") {
                ForEach(g.options ?? []) { opt in
                    radioRow(opt, groupId: g.id, groupOptions: g.options ?? [], required: g.isRequired == true)
                }
            }
        }

        ForEach(checkGroups) { g in
            let need = max(1, g.minQty ?? 1)
            groupCard(g, title: g.name ?? "Добавить к блюду",
                      caption: g.isRequired == true ? (need > 1 ? "Выберите от \(need)" : "Обязательно") : nil) {
                ForEach(g.options ?? []) { opt in
                    checkRow(opt, groupOptions: g.options ?? [], maxQty: g.maxQty)
                }
            }
        }

        // Похожие товары — секции нет, если список пуст.
        if !vm.recommended.isEmpty {
            recommendedSection
        }
    }

    // MARK: Весовые товары (чипы-пресеты + цена за вес)

    /// Пресеты веса из строки ("0.3,0.5,1"). Дефолтов НЕТ: если продавец
    /// пресеты не задал, товар штучный (см. isWeighed).
    private func weightPresets(_ d: ProductDetail) -> [Double] {
        (d.qtyPresets ?? "").split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }.sorted()
    }

    /// Весовой/дробный товар — РОВНО то же правило, что на сервере (snapOrderQty):
    /// дробным товар считается, если у него стоит флаг qty_fractional либо задано
    /// не меньше двух пресетов количества.
    ///
    /// Раньше сюда входила ещё и единица измерения («кг», «л»). Из-за этого
    /// обычный штучный товар с единицей «кг» показывал чипы 0,3 / 0,5 / 1 кг,
    /// по умолчанию выбирался 0,3, а сервер округлял количество до 1: на экране
    /// 45 ₽, в заказе 149,90 ₽. Единица сама по себе товар не дробит.
    private func isWeighed(_ d: ProductDetail) -> Bool {
        if (d.qtyFractional ?? 0) == 1 { return true }
        return weightPresets(d).count >= 2
    }

    /// Точный Decimal для веса из Double (через строку — без Double-погрешности).
    private func decWeight(_ w: Double) -> Decimal {
        let s = (w == w.rounded() ? String(Int(w)) : String(w))
        return Decimal(string: s) ?? Decimal(w)
    }

    /// Цена за выбранный вес: price × preset (строго Decimal).
    /// O1: при наборе опта цена единицы — по ступени (qtyTotal = в корзине + выбранный вес).
    private func weightPrice(_ d: ProductDetail, _ w: Double) -> Decimal {
        let base = Money.dec(d.price)
        let st = Wholesale.steps(d.priceTiers, retail: base)
        let u = Wholesale.unit(retail: base, addons: 0, steps: st,
                               qtyTotal: Wholesale.qtyTotal(cart.lines, productId: d.id) + w)
        return Wholesale.round2(u * decWeight(w))
    }

    @ViewBuilder private func weightSection(_ d: ProductDetail) -> some View {
        let presets = weightPresets(d)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Вес")
                    .ymText(YMText.sectionTitle)
                    .foregroundStyle(YMUi.text)
                Spacer()
                // Цена за выбранный вес.
                Text(Money.format(weightPrice(d, selectedWeight)))
                    .ymFont(16, weight: .heavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(YMColor.text)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.self) { v in
                        weightChip(v, unit: d.unit)
                    }
                }
            }
        }
        .padding(YMForm.cardPadding)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
        .padding(.top, YMForm.cardGap)
    }

    private func weightChip(_ v: Double, unit: String?) -> some View {
        let active = abs(selectedWeight - v) < 0.0001
        return Button {
            Haptics.selection()
            selectedWeight = v
        } label: {
            Text(fmtQty(v, unit))
                .ymFont(14, weight: .bold)
                .foregroundStyle(active ? YMColor.accent : YMColor.text)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(active ? YMColor.accent.opacity(0.10) : YMColor.surface,
                            in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(active ? YMColor.accent : YMColor.hairline, lineWidth: active ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: Похожие товары

    private var recommendedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Похожие товары")
                .ymText(YMText.sectionTitle)
                .foregroundStyle(YMUi.text)
                .padding(.top, 24)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: YMForm.cardGap) {
                    ForEach(Array(vm.recommended.enumerated()), id: \.element.id) { idx, p in
                        recommendedCard(p, tone: idx)
                    }
                }
                .padding(.vertical, YMSpace.sm)
            }
            .padding(.top, 4)
        }
    }

    /// Лёгкая плитка в стиле меню: белая карточка 20, фото на сером квадрате, название и цена.
    private func recommendedCard(_ p: Product, tone: Int) -> some View {
        NavigationLink { ProductView(product: p) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .background(YMUi.photoBg)
                    .overlay {
                        PhotoPlaceholder(url: API.imageURL(p.photo), label: "ФОТО", radius: 0, tone: tone, fit: true)
                            .padding(8)
                            .blendMode(scheme == .dark ? .normal : .multiply)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(p.name ?? "—")
                    .ymText(YMText.cardTitle)
                    .foregroundStyle(YMUi.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.top, 8).padding(.horizontal, 2)
                Spacer(minLength: 4)
                Text(Money.format(Money.dec(p.price)))
                    .ymText(YMText.cardPrice)
                    .foregroundStyle(YMUi.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.horizontal, 2)
            }
            .padding(8)
            .frame(width: 150, height: 232, alignment: .topLeading)
            .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
        }
        .buttonStyle(CardPressStyle())
    }

    /// Общая строка варианта: фото-кружок (если есть), название, «+40 ₽» серым, справа кружок/квадратик.
    private func optionRow(_ opt: ModifierOption, selected: Bool, square: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let ph = opt.photoWebp, !ph.isEmpty {
                    PhotoPlaceholder(url: API.imageURL(ph), label: "", radius: 0, tone: opt.id, fit: true, maxPixel: 200)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                }
                Text(opt.name ?? "—")
                    .ymText(YMText.body)
                    .foregroundStyle(YMUi.text)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if let pr = opt.price, pr > 0 {
                    Text("+\(Money.format(Money.dec(pr)))")
                        .ymText(YMText.body)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(YMUi.textSecondary)
                }
                ZStack {
                    if square {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? YMUi.accentFill : Color.clear)
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(selected ? YMUi.accentFill : YMUi.textSecondary, lineWidth: 1.5))
                    } else {
                        Circle()
                            .fill(selected ? YMUi.accentFill : Color.clear)
                            .overlay(Circle().strokeBorder(selected ? YMUi.accentFill : YMUi.textSecondary, lineWidth: 1.5))
                    }
                    if selected {
                        Image(systemName: "checkmark")
                            .ymIcon(11, weight: .heavy)
                            .foregroundStyle(YMColor.onAccent)
                    }
                }
                .frame(width: 24, height: 24)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Радио-строка: выбранная — золотой кружок.
    private func radioRow(_ opt: ModifierOption, groupId: Int, groupOptions: [ModifierOption], required: Bool = false) -> some View {
        let selected = selectedRadio[groupId] == opt.id
        return optionRow(opt, selected: selected, square: false) {
            Haptics.selection()
            // Необязательная группа («Не обязательно»): повторное нажатие снимает
            // выбор. Раньше однажды выбранную платную добавку убрать было нельзя —
            // только закрыть карточку и открыть заново.
            if selected && !required { selectedRadio[groupId] = nil } else { selectedRadio[groupId] = opt.id }
        }
    }

    /// Чекбокс-строка: выбранная — золотой квадратик с галочкой.
    private func checkRow(_ opt: ModifierOption, groupOptions: [ModifierOption] = [], maxQty: Int? = nil) -> some View {
        let checked = checkedAddons.contains(opt.id)
        return optionRow(opt, selected: checked, square: true) {
            Haptics.selection()
            // «До 2 соусов»: больше лимита группы не отмечаем — иначе отказ на оформлении.
            if checked { checkedAddons.remove(opt.id) } else {
                let inGroup = groupOptions.filter { checkedAddons.contains($0.id) }.count
                if (maxQty ?? 0) <= 0 || inGroup < (maxQty ?? 0) { checkedAddons.insert(opt.id) } else { Haptics.warning() }
            }
        }
    }

    // MARK: Service sections (Дата записи / Свободное время / Вызов на дом)

    @ViewBuilder private var serviceSections: some View {
        // Дата записи — горизонтальный пикер дней (из дат слотов или ближайшие 7 дней).
        VStack(alignment: .leading, spacing: 10) {
            Text("Дата записи")
                .ymFont(16, weight: .heavy)
                .foregroundStyle(YMColor.text)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(dayList.enumerated()), id: \.offset) { i, day in
                        dayCell(i, day)
                    }
                }
            }
        }
        .padding(.top, 20)

        // Свободное время — сетка 4-в-ряд.
        VStack(alignment: .leading, spacing: 10) {
            Text("Свободное время")
                .ymFont(16, weight: .heavy)
                .foregroundStyle(YMColor.text)
            let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
            if slotsForDay.isEmpty {
                Text("Нет свободных слотов на эту дату")
                    .font(YMFont.callout)
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 4)
            } else {
                LazyVGrid(columns: cols, spacing: 10) {
                    ForEach(slotsForDay) { slot in
                        slotCell(slot)
                    }
                }
            }
        }
        .padding(.top, 20)

        // Плашка «Вызвать специалиста на дом» с тумблером.
        HStack(spacing: 12) {
            Text("🏠").ymFont(20)
            VStack(alignment: .leading, spacing: 2) {
                Text("Вызвать специалиста на дом")
                    .ymFont(14, weight: .bold)
                    .foregroundStyle(YMColor.text)
                Text("Мастер приедет по вашему адресу")
                    .ymFont(12)
                    .foregroundStyle(YMColor.muted)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $homeVisit)
                .labelsHidden()
                .tint(YMColor.accent)
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.top, 20)
    }

    private func dayCell(_ index: Int, _ day: DayItem) -> some View {
        let active = selectedDay == index
        return Button {
            Haptics.selection()
            selectedDay = index
            selectedSlot = nil
        } label: {
            VStack(spacing: 3) {
                Text(day.dow)
                    .ymFont(11, weight: .semibold)
                    .foregroundStyle(active ? YMColor.onAccent.opacity(0.75) : YMColor.muted)
                Text(day.num)
                    .ymFont(18, weight: .heavy)
                    .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
            }
            .frame(width: 54, height: 60)
            .background(active ? YMColor.accent : YMColor.surface,
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(active ? Color.clear : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func slotCell(_ slot: Slot) -> some View {
        let taken = false  // TODO(API): в модели Slot нет флага занятости — все приходящие слоты свободны.
        let active = selectedSlot == slot.id
        return Button {
            guard !taken else { return }
            Haptics.selection()
            selectedSlot = slot.id
        } label: {
            Text(slotLabel(slot))
                .ymFont(13.5, weight: .bold)
                .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(active ? YMColor.accent : YMColor.surface,
                            in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(active ? Color.clear : YMColor.hairline, lineWidth: 1.5))
                .opacity(taken ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(taken)
    }

    // MARK: Top controls

    private var topControls: some View {
        HStack {
            Button { Haptics.light(); dismiss() } label: {
                Image(systemName: "chevron.left")
                    .ymIcon(15, weight: .semibold)
                    .foregroundStyle(YMUi.text)
                    .frame(width: YMForm.closeButton, height: YMForm.closeButton)
                    .background(Color.white, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                    .accessibilityLabel("Назад")
            }
            .buttonStyle(.plain)
            Spacer()
            // Сердечко товара показываем только в режиме товара (у услуги избранного нет).
            if vm.mode == .product {
                // Гостю — сначала вход: раньше сердечко загоралось, запрос получал
                // 401 и молча гасло обратно, без объяснения.
                Button {
                    Haptics.light()
                    if !Session.shared.isLoggedIn { showAuth = true } else if !favBusy {
                        let becomesFav = !isFav
                        isFav.toggle()
                        // Поп и искры — только при включении и без Reduce Motion (как в HeartButton).
                        if becomesFav && !reduceMotion {
                            withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { heartBump = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { heartBump = false }
                            }
                            heartSparkKey += 1
                        }
                    }
                } label: {
                    Image(systemName: isFav ? "heart.fill" : "heart")
                        .ymIcon(16, weight: .semibold)
                        .foregroundStyle(isFav ? YMColor.statusCancel : Color(hex: "#111111"))
                        .frame(width: YMForm.closeButton, height: YMForm.closeButton)
                        .background(Color.white, in: Circle())
                        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
                        .scaleEffect(heartBump ? 1.35 : 1)
                        .overlay(
                            Group {
                                if heartSparkKey > 0 {
                                    YMBurst(config: .sparks(size: YMForm.closeButton, colors: [YMColor.statusCancel, YMPalette.goldBright]))
                                        .id(heartSparkKey)
                                        .frame(width: YMForm.closeButton * 2.4, height: YMForm.closeButton * 2.4)
                                }
                            }
                            .allowsHitTesting(false)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isFav ? "Убрать из избранного" : "Добавить в избранное")
                .onChange(of: isFav) { _ in toggleFav() }
            }
        }
        .padding(.horizontal, YMForm.screenPadding + 12)
        .padding(.top, 8 + 12)
    }

    // MARK: Bottom bar

    @ViewBuilder private var bottomBar: some View {
        VStack {
            Spacer()
            if vm.mode == .product {
                requiredHint
                productBottomBar
            } else {
                serviceBottomBar
            }
        }
    }

    /// Обязательный выбор не сделан — «В корзину» серая. Подпись-причина прямо над кнопкой;
    /// после тапа по кнопке краснеет (и экран прокручивается к группе).
    @ViewBuilder private var requiredHint: some View {
        if !isStopped, let g = missingRequiredGroup {
            Text("Выберите «\(g)», чтобы добавить в корзину")
                .ymText(YMText.caption)
                .foregroundStyle(requiredFlash ? YMColor.statusCancel : YMUi.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(YMUi.card, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                .padding(.horizontal, YMForm.screenPadding)
                // Подсказка не должна перехватывать тап по варианту под ней.
                .allowsHitTesting(false)
        }
    }

    /// Нужен ли сейчас тап-перехват на неактивной кнопке (причина — невыбранная группа).
    private var tapHintsRequired: Bool {
        vm.detail != nil && !requiredChosen && !isStopped && !added
    }

    @ViewBuilder private var addLabel: some View {
        if isOutOfStock {
            Text("Закончился")
        } else if isStopped {
            Text("Нет в наличии")
        } else if added {
            Text("Добавлено ✓")
        } else {
            HStack(spacing: 6) {
                Text(Money.format(lineTotal) + " +").ymNumeric(lineTotal)
                if cardTier != nil, retailTotal > lineTotal {
                    Text(Money.format(retailTotal)).strikethrough().opacity(0.7)
                }
            }
        }
    }

    private var addA11y: String {
        if isOutOfStock { return "Закончился" }
        if isStopped { return "Нет в наличии" }
        if added { return "Добавлено" }
        return "В корзину, \(Money.format(lineTotal))"
    }

    // Степпер −/N/+ и кнопка «<цена> +».
    private var productBottomBar: some View {
        VStack(spacing: 8) {
            wholesaleNote
            HStack(spacing: 12) {
                // Степпер показываем только для штучных: у весового кол-во задаёт чип-пресет.
                if !isWeighedProduct {
                    QtyStepper(qtyText: qtyLabel, height: YMForm.buttonHeight,
                               onMinus: { decQty() }, onPlus: { incQty() })
                }

                Button {
                    addToCart()
                } label: {
                    addLabel
                }
                .buttonStyle(YMPrimaryButtonStyle())
                // `added` — окно закрывается через 0.7 с, второе нажатие за это время
                // добавляло товар ещё раз.
                // isStopped — позиция в стоп-листе или выключена продавцом: раньше
                // кнопка работала, корзина набиралась, а отказ приходил только на
                // оформлении («Часть товаров закончилась»), без указания позиции.
                .disabled(vm.detail == nil || !requiredChosen || added || isStopped || effectiveQty <= 0)
                .accessibilityLabel(addA11y)
                .overlay {
                    // Неактивная из-за невыбранной группы: тап подсвечивает группу и прокручивает к ней.
                    if tapHintsRequired && missingRequiredGroupId != nil && effectiveQty > 0 {
                        Color.clear.contentShape(Rectangle()).onTapGesture { flashRequired() }
                    }
                }
            }
        }
        .padding(.horizontal, YMForm.screenPadding)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(YMUi.card.ignoresSafeArea(edges: .bottom)
            .shadow(color: .black.opacity(0.06), radius: 8, y: -2))
    }

    // Кнопка «Записаться · от СУММА».
    private var serviceBottomBar: some View {
        Button {
            book()
        } label: {
            HStack(spacing: 8) {
                Text(vm.booked ? "Вы записаны ✓" : "Записаться")
                // Цены нет (null/0) — без «· от 0 ₽» на кнопке.
                if servicePrice > 0 {
                    Text("·").opacity(0.6)
                    Text("от \(Money.format(servicePrice))")
                }
            }
        }
        .buttonStyle(YMPrimaryButtonStyle())
        .disabled(selectedSlot == nil || vm.booked)
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(.bar)
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: 16) {
            SkeletonBox(radius: 0).frame(height: heroHeight).ignoresSafeArea(edges: .top)
            VStack(alignment: .leading, spacing: 12) {
                SkeletonBox().frame(width: 200, height: 24)
                SkeletonBox().frame(width: 260, height: 14)
                SkeletonBox(radius: YMRadius.control).frame(height: 54)
                SkeletonBox(radius: YMRadius.control).frame(height: 54)
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

    // MARK: Derived (общие)

    private var titleText: String {
        vm.mode == .product ? (vm.detail?.name ?? vm.seedProduct?.name ?? "—") : (vm.service?.name ?? "—")
    }
    private var isHalal: Bool {
        vm.mode == .product && (vm.detail?.isHalal ?? vm.seedProduct?.isHalal ?? false)
    }
    private var ratingValue: Double? {
        // У ProductDetail/ServiceItem нет рейтинга в модели — показываем только если появится.
        // TODO(API): рейтинг товара/услуги в ProductDetail/ServiceItem отсутствует.
        nil
    }
    private var metaText: String? {
        if vm.mode == .service, let dm = vm.service?.durationMin, dm > 0 { return "\(dm) мин" }
        if vm.mode == .product, let unit = vm.detail?.unit ?? vm.seedProduct?.unit, !unit.isEmpty { return unit }
        return nil
    }
    /// Цена услуги для кнопки «Записаться · от …» (0 — цены нет).
    private var servicePrice: Decimal { Money.dec(vm.service?.price) }
    private var descText: String? {
        vm.mode == .product ? (vm.detail?.description ?? vm.seedProduct?.description) : vm.service?.description
    }

    // MARK: Product logic

    /// Шаг «+/−». Дробным шаг бывает только у дробного товара (правило сервера),
    /// иначе сервер округлит количество и покупатель получит не то, что видел.
    private var stepValue: Double {
        guard let d = vm.detail else { return 1 }
        if !isWeighed(d) { return 1 }
        if let f = weightPresets(d).first { return f }
        if (d.qtyStep ?? 0) > 0 { return d.qtyStep ?? 0.1 }
        return 0.1
    }
    private var isFractional: Bool { stepValue != 1 }
    private var qtyLabel: String {
        isFractional ? fmtQty(qty, vm.detail?.unit) : String(Int(qty.rounded()))
    }
    /// Подставить стартовые значения по загруженной карточке: вес-пресет для
    /// весового товара и количество, кратное шагу, — для остальных.
    private func syncQtyDefaults() {
        guard vm.mode == .product, let d = vm.detail else { return }
        let ps = weightPresets(d)
        if ps.count >= 2 {
            if selectedWeight <= 0 || !ps.contains(where: { abs($0 - selectedWeight) < 0.0001 }) {
                selectedWeight = ps.first ?? 0
            }
        } else {
            // Дробный шаг: стартовое «1» не кратно шагу, и сервер пересчитал бы
            // количество по своей сетке (1 кг при шаге 0,3 → 0,9). Ставим сам шаг.
            let st = stepValue
            // Только если текущее количество не по сетке шага: экран
            // перерисовывается и при возврате с соседнего товара, и раньше
            // выбранные 1,5 кг сбрасывались на 0,3.
            if st != 1 {
                let ratio = qty / st
                if qty < st || abs(ratio - ratio.rounded()) > 0.0001 { qty = st }
            }
        }
    }

    private func incQty() { Haptics.selection(); qty = snapQty(qty + stepValue) }
    private func decQty() {
        Haptics.selection()
        let nq = snapQty(qty - stepValue)
        if nq >= stepValue { qty = nq }
    }

    /// Количество по сетке шага — то же правило, что у сервера (snapOrderQty):
    /// иначе экран показывает одну цену, а заказ считается по другой.
    private func snapQty(_ q: Double) -> Double {
        let st = stepValue
        if st <= 0 { return q }
        if st == 1 { return max(1, (q).rounded()) }
        let snapped = max(st, (q / st).rounded() * st)
        return (snapped * 1000).rounded() / 1000
    }

    /// Позиция закончилась: сервер отдаёт stopped в карточке товара.
    /// А65: категория выключена продавцом (category_off) — тоже «нет в наличии»,
    /// заказ сервер отклонит (409).
    private var isStopped: Bool {
        vm.detail?.stopped == true || vm.detail?.categoryOff == true || isOutOfStock
    }
    /// А428: закончился у магазина (out_of_stock) — подпись «Закончился», добавить нельзя.
    private var isOutOfStock: Bool { vm.detail?.outOfStock == true }

    /// Количество задаётся чипами-пресетами, а не степпером. Чипы уместны
    /// только когда пресетов хотя бы два: дробный товар без пресетов
    /// (qty_fractional без списка весов) набирается обычными «+/−» с дробным
    /// шагом — иначе выбирать было бы не из чего и в корзину ушёл бы ноль.
    private var isWeighedProduct: Bool {
        guard let d = vm.detail else { return false }
        return weightPresets(d).count >= 2
    }

    /// Кол-во, которое кладём в корзину: вес-пресет для весового, иначе штучное qty.
    private var effectiveQty: Double { isWeighedProduct ? selectedWeight : qty }

    /// Цена строки: (цена товара + сумма выбранных модификаторов) × кол-во.
    /// Для весового кол-во = выбранный вес (точный Decimal). ИТОГ модификаторов суммируем
    /// локально (option.price) — сервер финализирует при заказе.
    private var lineTotal: Decimal {
        guard let d = vm.detail else { return 0 }
        let base = Money.dec(d.price)
        let unit = Wholesale.unit(retail: base, addons: modsSum, steps: wholesaleSteps, qtyTotal: cardQtyTotal)
        return Wholesale.round2(unit * cardMult)
    }

    /// O1: применимые ступени товара.
    private var wholesaleSteps: [Wholesale.Step] {
        guard let d = vm.detail else { return [] }
        return Wholesale.steps(d.priceTiers, retail: Money.dec(d.price))
    }
    /// O1: qtyTotal для карточки = уже в корзине (все строки товара) + выбранное сейчас
    /// (карточка всегда добавляет количество в корзину).
    private var cardQtyTotal: Double {
        guard let d = vm.detail else { return 0 }
        return Wholesale.qtyTotal(cart.lines, productId: d.id) + effectiveQty
    }
    private var cardMult: Decimal { isWeighedProduct ? decWeight(selectedWeight) : Wholesale.dec(qty) }
    /// Сумма выбранных добавок на единицу.
    private var modsSum: Decimal {
        guard let d = vm.detail else { return 0 }
        let allOptions = (d.modifierGroups ?? []).flatMap { $0.options ?? [] }
        var mods = Decimal(0)
        for id in selectedRadio.values {
            if let opt = allOptions.first(where: { $0.id == id }) { mods += Money.dec(opt.price) }
        }
        for id in checkedAddons {
            if let opt = allOptions.first(where: { $0.id == id }) { mods += Money.dec(opt.price) }
        }
        return mods
    }
    /// O1: та же сумма по рознице (для зачёркивания и «Экономия»).
    private var retailTotal: Decimal {
        guard let d = vm.detail else { return 0 }
        return Wholesale.round2((Money.dec(d.price) + modsSum) * cardMult)
    }
    private var cardTier: Wholesale.Step? { Wholesale.tier(wholesaleSteps, qtyTotal: cardQtyTotal) }

    /// O1: строка под суммой — «Экономия N ₽» или «Ещё N кг до оптовой цены».
    @ViewBuilder private var wholesaleNote: some View {
        if vm.detail != nil, !wholesaleSteps.isEmpty, !isStopped {
            if cardTier != nil {
                let saving = retailTotal - lineTotal
                if saving > 0 {
                    Text(Wholesale.savingText(saving))
                        .ymFont(13, weight: .semibold)
                        .foregroundStyle(YMColor.accent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else if let n = Wholesale.next(wholesaleSteps, qtyTotal: cardQtyTotal) {
                Text(Wholesale.moreText(n, qtyTotal: cardQtyTotal, unit: vm.detail?.unit))
                    .ymFont(13, weight: .semibold)
                    .foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private var selectedModifierIds: [Int] {
        var ids = Array(checkedAddons)
        ids.append(contentsOf: selectedRadio.values)
        return ids
    }

    /// Все обязательные группы выбраны: радио — выбран вариант, чекбоксы — отмечено
    /// не меньше min_qty (минимум 1). Группа без доступных вариантов не блокирует.
    private var requiredChosen: Bool {
        guard let d = vm.detail else { return false }
        for g in d.modifierGroups ?? [] where g.isRequired == true {
            let opts = g.options ?? []
            if opts.isEmpty { continue }
            let isRadio = (g.type ?? "") == "single" || (g.maxQty ?? 0) == 1
            if isRadio {
                if selectedRadio[g.id] == nil { return false }
            } else {
                let need = min(max(1, g.minQty ?? 1), opts.count)
                if opts.filter({ checkedAddons.contains($0.id) }).count < need { return false }
            }
        }
        return true
    }

    /// Название первой обязательной группы, где выбор ещё не сделан (правило —
    /// как в requiredChosen). nil — всё выбрано или карточка не загружена.
    private var missingRequiredGroup: String? {
        guard let d = vm.detail else { return nil }
        for g in d.modifierGroups ?? [] where g.isRequired == true {
            let opts = g.options ?? []
            if opts.isEmpty { continue }
            let isRadio = (g.type ?? "") == "single" || (g.maxQty ?? 0) == 1
            if isRadio {
                if selectedRadio[g.id] == nil { return g.name ?? "вариант" }
            } else {
                let need = min(max(1, g.minQty ?? 1), opts.count)
                let have = opts.filter({ checkedAddons.contains($0.id) }).count
                if have < need { return g.name ?? "добавки" }
            }
        }
        return nil
    }

    private func addToCart() {
        guard let d = vm.detail else { return }
        let newShopId = d.shopId ?? 0
        // Инвариант single-store: если корзина занята ДРУГИМ магазином — просим
        // подтверждение через глобальный диалог, и только по «Очистить» добавляем.
        if let cur = cart.shopId, cur != newShopId, !cart.isEmpty {
            if nested { localConflict = true; return }
            coord.requestCartConflict(
                currentShop: cart.shopName,
                newShop: d.shopName,
                onConfirm: { [self] in commitAdd(d) }
            )
            return
        }
        commitAdd(d)
    }

    private func commitAdd(_ d: ProductDetail) {
        let allOptions = (d.modifierGroups ?? []).flatMap { $0.options ?? [] }
        // Весовой товар кладём с qty = выбранный вес-пресет; штучный — целым qty.
        // Cart.add сам сохранит unit/qtyFractional/qtyPresets из ProductDetail.
        // AT-3: корзина заблокирована неотвеченным оформлением — не добавлено;
        // говорим об этом тостом здесь же (ниже).
        guard Cart.shared.add(
            product: d,
            modifierIds: selectedModifierIds,
            options: allOptions,
            shopId: d.shopId ?? 0,
            shopName: d.shopName,
            qty: effectiveQty
        ) else {
            // Говорим здесь же, тостом (общих алертов на корне нет).
            Haptics.warning()
            favError = "Прошлое оформление не завершилось — заказ мог создаться. Откройте корзину → «Оформить» и узнайте исход, потом добавляйте товары."
            return
        }
        added = true
        Haptics.success()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { dismiss() }
    }

    // MARK: Service logic

    struct DayItem { let dow: String; let num: String; let date: Date }

    /// Список дней: если у слотов есть даты — берём их; иначе ближайшие 7 дней.
    private var dayList: [DayItem] {
        let cal = Calendar.current
        let df = DateFormatter(); df.locale = Locale(identifier: "ru_RU"); df.dateFormat = "EEEEEE"
        let today = Date()
        return (0..<7).map { off in
            let date = cal.date(byAdding: .day, value: off, to: today) ?? today
            let dow = df.string(from: date).uppercased()
            let num = String(cal.component(.day, from: date))
            return DayItem(dow: dow, num: num, date: date)
        }
    }

    /// Слоты выбранного дня. Slot.timeStart может нести дату/время; при отсутствии
    /// сопоставления по дате показываем все слоты (сервер сам ограничивает выдачу).
    private var slotsForDay: [Slot] {
        vm.slots
    }

    private func slotLabel(_ slot: Slot) -> String {
        // timeStart формата "HH:mm" или "yyyy-MM-dd HH:mm:ss" — показываем HH:mm.
        let s = slot.timeStart ?? ""
        if s.count >= 16, s.contains(" ") {
            return String(s.dropFirst(11).prefix(5))
        }
        return String(s.prefix(5))
    }

    private func book() {
        guard let slotId = selectedSlot, let slot = vm.slots.first(where: { $0.id == slotId }) else { return }
        // Гость: раньше запрос уходил без токена и человек видел «Сессия
        // истекла, войдите снова» без кнопки входа. Сначала — вход.
        guard Session.shared.isLoggedIn else { showAuth = true; return }
        Task {
            let ok = await vm.book(slot: slot)
            if ok {
                Haptics.success()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { dismiss() }
            } else {
                Haptics.error()
            }
        }
    }
}
