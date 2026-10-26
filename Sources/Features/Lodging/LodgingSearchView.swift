import SwiftUI

/*
 ============================================================================
  Раздел «Жильё» — поиск: даты, гости, тип жилья, посуточно / длительно.

  Цену и доступность считает СЕРВЕР (/api/v1/lodging). Здесь только показ:
  повторять формулу на трёх платформах — верный способ разойтись в копейках.

  Навигация: у экрана ОДИН navigationDestination (см. предупреждение в
  HomeView / DiscoverView — второй в SwiftUI просто не срабатывает).
  Карточка объекта и «Мои поездки» открываются через одно состояние route,
  а дальше каждый пушенный экран ведёт свою навигацию сам.
 ============================================================================
 */

/// Подтипы жилья для фильтра. Ключи совпадают с Lodging::SUBTYPES на сервере.
private struct LodgingSubtypeChip: Identifiable, Hashable {
    let key: String
    let name: String
    var id: String { key }
}

private let lodgingSubtypes: [LodgingSubtypeChip] = [
    .init(key: "all", name: "Любое"),
    .init(key: "hotel", name: "Отель"),
    .init(key: "mini_hotel", name: "Мини-отель"),
    .init(key: "hostel", name: "Хостел"),
    .init(key: "apart_hotel", name: "Апарт-отель"),
    .init(key: "guest_house", name: "Гостевой дом"),
    .init(key: "apartment", name: "Квартира"),
    .init(key: "studio", name: "Студия"),
    .init(key: "house", name: "Дом"),
    .init(key: "room", name: "Комната"),
    .init(key: "resort", name: "База отдыха"),
    .init(key: "glamping", name: "Глэмпинг"),
]

// MARK: - Модель

@MainActor
final class LodgingSearchVM: ObservableObject {
    @Published var items: [LodgingItem] = []
    @Published var total = 0
    @Published var loading = true
    @Published var failed = false
    /// Причина сбоя: текст сервера (422 «даты уже прошли» и т. п.) или сети.
    /// Раньше на любой отказ писалось «Проверьте связь».
    @Published var failText: String?
    // Догрузка. Сервер отдаёт результаты страницами, а экран раньше брал
    // только первую: «Найдено: 45», а карточек — одна страница и никакой
    // «следующей». gen — номер выборки: догрузка по старым фильтрам выбрасывается.
    @Published var page = 1
    @Published var moreFailed = false
    private var loadingMore = false
    private var gen = 0
    private var lastQuery: (cityId: Int?, rentLong: Bool, subtype: String, from: String?, to: String?, guests: Int)?

    var hasMore: Bool { !loading && !items.isEmpty && items.count < total }

    func search(cityId: Int?, rentLong: Bool, subtype: String,
                from: String?, to: String?, guests: Int) async {
        loading = true
        failed = false
        gen += 1
        // «Повторить» идёт мимо .task(id:) и не отменяется сменой фильтра:
        // его поздний ответ ложился под новый фильтр. Чужую выборку отбрасываем.
        let myGen = gen
        page = 1; moreFailed = false; loadingMore = false
        lastQuery = (cityId, rentLong, subtype, from, to, guests)
        do {
            let resp = try await API.shared.lodgingSearch(
                cityId: cityId,
                dateFrom: rentLong ? nil : from,
                dateTo: rentLong ? nil : to,
                guests: guests,
                subtype: subtype == "all" ? nil : subtype,
                rent: rentLong ? "long" : "daily"
            )
            guard myGen == gen else { return }
            items = resp.itemsList
            total = resp.totalValue
        } catch is CancellationError {
            // Отмена (быстро сменили фильтр) — состояние не трогаем: его
            // выставит следующая задача, иначе экран мигнёт пустым списком.
            return
        } catch {
            guard myGen == gen else { return }
            items = []
            total = 0
            failed = true
            failText = (error as? LocalizedError)?.errorDescription
        }
        loading = false
    }

    func loadMore() async {
        guard hasMore, !loadingMore, let q = lastQuery else { return }
        loadingMore = true; moreFailed = false
        let myGen = gen, next = page + 1
        do {
            let resp = try await API.shared.lodgingSearch(
                cityId: q.cityId,
                dateFrom: q.rentLong ? nil : q.from,
                dateTo: q.rentLong ? nil : q.to,
                guests: q.guests,
                subtype: q.subtype == "all" ? nil : q.subtype,
                rent: q.rentLong ? "long" : "daily",
                page: next
            )
            guard myGen == gen else { return }
            let fresh = resp.itemsList
            let known = Set(items.map(\.id))
            items += fresh.filter { !known.contains($0.id) }
            page = next
            total = resp.totalValue
            // Пустая страница — дальше идти некуда, иначе подвал крутился бы вечно.
            if fresh.isEmpty { total = items.count }
        } catch is CancellationError {
        } catch {
            if myGen == gen { moreFailed = true }
        }
        if myGen == gen { loadingMore = false }
    }
}

/// Push/строка ленты о брони жилья (screen=trips): открыть «Мои поездки».
/// Ставит вызывающий прямо перед NavCoordinator.openLodging(); забирает
/// LodgingSearchView при появлении. Старше 15 с не исполняется — чтобы не
/// сработать позже, при обычном входе в «Жильё».
enum LodgingPushIntent {
    private static var tripsAt: Date?
    static func openTrips() { tripsAt = Date() }
    static func take() -> Bool {
        guard let at = tripsAt else { return false }
        tripsAt = nil
        return Date().timeIntervalSince(at) < 15
    }
}

// MARK: - Экран

struct LodgingSearchView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = LodgingSearchVM()

    @State private var rentLong = false          // false — посуточно, true — длительно
    @State private var subtype = "all"
    @State private var from: String?
    @State private var to: String?
    @State private var guests = 2
    @State private var showDates = false

    /// ОДНО состояние навигации на экран (см. шапку файла).
    private enum Route: Hashable {
        case unit(String)
        case trips
    }
    @State private var route: Route?

    /// Стек сняли не кнопкой «Назад» (долгое нажатие «Назад» на несколько
    /// экранов, закрытие поверх) — сеттер navigationDestination(isPresented:)
    /// SwiftUI не зовёт, route «висит», и карточки больше не открывались
    /// (как на Главной). Сначала сбрасываем, потом идём.
    private func go(_ r: Route) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    /// Ключ запроса: меняется — .task(id:) сам перезапускает поиск и отменяет
    /// предыдущий. Ручной дебаунс не нужен.
    private struct QueryKey: Equatable {
        let city: Int?
        let rentLong: Bool
        let subtype: String
        let from: String?
        let to: String?
        let guests: Int
    }

    /// Ключ последнего удачного поиска: .task(id:) срабатывает и на возврат
    /// из объявления — список с 3-й страницы обрезался до 1-й и прыгал.
    @State private var searchedKey: QueryKey?

    private var queryKey: QueryKey {
        QueryKey(city: session.cityId, rentLong: rentLong, subtype: subtype,
                 from: from, to: to, guests: guests)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: YMSpace.md) {
                YMSegmented(options: [false, true], selection: $rentLong) {
                    $0 ? "Длительно" : "Посуточно"
                }
                .padding(.horizontal, YMSpace.xl)

                if !rentLong {
                    datesRow
                }

                guestsBox

                subtypeChips

                Text(resultLabel)
                    .font(YMFont.callout)
                    .foregroundStyle(YMColor.muted)
                    .padding(.horizontal, YMSpace.xl)

                ForEach(vm.items) { item in
                    Button {
                        if let slug = item.unit?.slug, !slug.isEmpty {
                            Haptics.light()
                            go(.unit(slug))
                        }
                    } label: {
                        LodgingResultCard(item: item, rentLong: rentLong)
                    }
                    .buttonStyle(CardPressStyle())
                    .padding(.horizontal, YMSpace.xl)
                }

                if vm.hasMore {
                    LoadMoreFooter(page: vm.page, failed: vm.moreFailed) { await vm.loadMore() }
                }

                if vm.loading && vm.items.isEmpty {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBox(radius: YMRadius.card)
                            .frame(height: 220)
                            .padding(.horizontal, YMSpace.xl)
                    }
                } else if !vm.loading && vm.items.isEmpty {
                    // Без дат и фильтра «пусто» — это «жилья ещё нет» (новый город,
                    // раздел только открылся): совет «другие даты» тут сбивал с толку.
                    // Гостей больше 2 (по умолчанию) — тоже фильтр, паритет с Android.
                    let noFilters: Bool = from == nil && to == nil && subtype == "all" && guests <= 2
                    let dailyEmpty: String = noFilters
                        ? "Посуточного жилья здесь пока нет. Загляните позже."
                        : "Попробуйте другие даты или снимите фильтр по типу жилья."
                    Text(vm.failed
                         ? (vm.failText ?? "Не удалось загрузить. Проверьте связь.")
                         : (rentLong
                            ? "На длительный срок пока ничего не сдают. Попробуйте посуточно."
                            : dailyEmpty))
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .padding(.horizontal, YMSpace.xl)
                    // Сбой сети — раньше без повтора: фильтры не менялись, и
                    // поиск заново не запускался ничем, кроме ухода с экрана.
                    if vm.failed {
                        Button("Повторить") {
                            Task {
                                await vm.search(cityId: session.cityId, rentLong: rentLong, subtype: subtype,
                                                from: from, to: to, guests: guests)
                            }
                        }
                        .font(YMFont.subhead)
                        .foregroundStyle(YMColor.accent)
                        .padding(.horizontal, YMSpace.xl)
                    }
                }

                Color.clear.frame(height: YMSpace.xxl)
            }
            .padding(.top, YMSpace.md)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Жильё")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Мои поездки") { go(.trips) }
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.accent)
            }
        }
        // Push/строка ленты о брони (screen=trips): раньше открывался поиск, и
        // «Мои поездки» человек искал сам. Раздел только что открыт — сразу туда.
        .onAppear {
            if LodgingPushIntent.take() { DispatchQueue.main.async { go(.trips) } }
        }
        .task(id: queryKey) {
            if searchedKey == queryKey, !vm.failed, !vm.items.isEmpty { return }
            await vm.search(cityId: session.cityId, rentLong: rentLong, subtype: subtype,
                            from: from, to: to, guests: guests)
            if !Task.isCancelled { searchedKey = queryKey }
        }
        .sheet(isPresented: $showDates) {
            // Календарь объекта тут неизвестен (объект ещё не выбран) — сетка
            // работает как обычный выбор дат, остатки проверит сервер.
            LodgingDatesSheet(from: from, to: to, minNights: 1) { f, t in
                from = f
                to = t
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { route != nil }, set: { if !$0 { route = nil } }
        )) {
            switch route {
            case .unit(let slug):
                // Выбранные в поиске даты и гости переходят в карточку объекта:
                // раньше там всё выбиралось заново. У длительной аренды дат нет.
                LodgingUnitView(slug: slug, from: rentLong ? nil : from,
                                to: rentLong ? nil : to, guests: guests)
            case .trips:
                LodgingTripsView()
            case .none:
                EmptyView()
            }
        }
    }

    // ── Части экрана ──

    private var datesRow: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            HStack(spacing: YMSpace.sm) {
                // Даты необязательны: без них раздел работает как каталог и
                // показывает цену «от» — так ведут себя все сервисы брони.
                dateBox(label: "Заезд", value: from.map(LodgingDate.human) ?? "выберите")
                dateBox(label: "Выезд", value: to.map(LodgingDate.human) ?? "выберите")
            }
            // Выбранные даты раньше нельзя было снять: вернуться к каталогу
            // без дат (цена «за ночь», все объекты) было невозможно.
            if from != nil || to != nil {
                Button("Сбросить даты") {
                    Haptics.light()
                    from = nil
                    to = nil
                }
                .font(YMFont.caption)
                .foregroundStyle(YMColor.accent)
            }
        }
        .padding(.horizontal, YMSpace.xl)
    }

    private func dateBox(label: String, value: String) -> some View {
        Button {
            Haptics.light()
            showDates = true
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(YMFont.caption).foregroundStyle(YMColor.muted)
                Text(value).font(YMFont.body).foregroundStyle(YMColor.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, YMSpace.md)
            .padding(.vertical, YMSpace.sm)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var guestsBox: some View {
        LodgingStepper(label: "Гостей", value: $guests, range: 1...20)
            .padding(.horizontal, YMSpace.md)
            .padding(.vertical, YMSpace.sm)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.hairline, lineWidth: 1)
            )
            .padding(.horizontal, YMSpace.xl)
    }

    private var subtypeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: YMSpace.sm) {
                ForEach(lodgingSubtypes) { s in
                    Chip(label: s.name, active: s.key == subtype) {
                        Haptics.selection()
                        subtype = s.key
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private var resultLabel: String {
        if vm.loading { return "Ищем…" }
        if vm.total > 0 { return "Найдено: \(vm.total)" }
        return "Ничего не нашлось"
    }
}

// MARK: - Карточка в выдаче

struct LodgingResultCard: View {
    let item: LodgingItem
    let rentLong: Bool

    var body: some View {
        let u = item.unit
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PhotoPlaceholder(
                    url: API.imageURL(u?.photo),
                    label: "ФОТО",
                    radius: YMRadius.card,
                    tone: u?.id ?? 0
                )
                .frame(height: 190)
                .frame(maxWidth: .infinity)

                HStack(spacing: YMSpace.xs) {
                    if !item.isAvailable {
                        // Причина от сервера: «занято» писалось и на прошедшие
                        // даты, и на закрытые, и на слишком короткий срок.
                        Text(item.reasonText ?? "занято на эти даты")
                            .font(YMFont.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Color.black.opacity(0.55), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if let r = item.shop?.rating, r > 0 {
                        RatingBadge(rating: NSDecimalNumber(decimal: r).doubleValue)
                    }
                }
                .padding(YMSpace.sm)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(u?.title ?? "Жильё")
                    .font(YMFont.headline)
                    .foregroundStyle(YMColor.text)
                    .lineLimit(2)
                Text(subtitle(u))
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
                if !place.isEmpty {
                    Text(place)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                        .lineLimit(1)
                }
                Text(priceText)
                    .font(YMFont.headline)
                    .foregroundStyle(YMColor.text)
                    .padding(.top, YMSpace.xs)
                if let badges = item.badges, !badges.isEmpty {
                    HStack(spacing: YMSpace.xs) {
                        ForEach(badges.prefix(2), id: \.self) { b in
                            Text(b)
                                .font(YMFont.caption2)
                                .foregroundStyle(YMColor.muted)
                                .padding(.horizontal, YMSpace.sm).padding(.vertical, 4)
                                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                        }
                    }
                    .padding(.top, YMSpace.xs)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.md)
        }
        .ymCard()
    }

    private func subtitle(_ u: LodgingUnitBrief?) -> String { LodgingText.unitSubtitle(u) }
    private var place: String { LodgingText.place(item) }
    private var priceText: String { LodgingText.price(item, rentLong: rentLong) }
}
