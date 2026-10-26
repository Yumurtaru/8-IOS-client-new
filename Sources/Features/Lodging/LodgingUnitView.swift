import SwiftUI

/*
 ============================================================================
  Карточка объекта размещения + бронирование.

  Расчёт стоимости делает сервер (/api/v1/lodging/{slug}/quote) и отдаёт
  готовые строки — экран их только показывает, ничего не пересчитывая. Поэтому
  сумма здесь, на сайте и в Android совпадает по построению.

  ДВА ПРАВИЛА НАВИГАЦИИ, КОТОРЫЕ ЗДЕСЬ НАРУШАТЬ НЕЛЬЗЯ:
   • ОДИН navigationDestination на экран (второй SwiftUI просто не сработает —
     см. предупреждение в HomeView / DiscoverView);
   • ОДНА шторка на экран, через .sheet(item:) и enum. Несколько
     .sheet(isPresented:) на одной вьюхе — классический источник «шторка не
     открывается»: побеждает последняя.
 ============================================================================
 */

// MARK: - Модель

@MainActor
final class LodgingUnitVM: ObservableObject {
    @Published var data: LodgingUnitResp?
    @Published var days: [String: LodgingDay] = [:]
    @Published var loading = true

    /// Расчёт: quote == nil и quoteLoading == false → даты не выбраны.
    @Published var quoteLoading = false
    @Published var quote: LodgingQuoteResp?
    @Published var quoteError: String?

    @Published var message: String?
    @Published var sending = false

    /// Имя и телефон берём из профиля: заставлять человека вводить свой же
    /// телефон на экране бронирования — лишний шаг.
    @Published var myName = ""
    @Published var myPhone = ""

    /// Объект не загрузился (сеть, 5xx) — это не «снят с публикации».
    @Published var loadError: String?

    func load(slug: String) async {
        loading = true
        // .task срабатывает и при возврате с «Моих поездок» / заведения: раньше
        // сбой повторной загрузки стирал уже открытый объект, а сбой первой
        // писал «Объект не найден» без повтора.
        do {
            data = try await API.shared.lodgingUnit(slug: slug)
            loadError = nil
        } catch is CancellationError {
        } catch {
            if data == nil { loadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить объект" }
        }
        await reloadCalendar(slug: slug)
        // Гостю профиль не запрашиваем: каждый показ объекта слал запрос без
        // входа (401 → попытка продления → «выход» гостя). После входа .task
        // срабатывает снова при возврате на экран — тогда и подставим.
        if Session.shared.isLoggedIn, let p: Profile = try? await API.shared.get("api/v1/profile") {
            myName = p.name ?? ""
            myPhone = p.phone ?? ""
        }
        loading = false
    }

    func reloadCalendar(slug: String) async {
        if let cal = try? await API.shared.lodgingCalendar(slug: slug, months: 4) {
            days = cal.byDate
        }
    }

    func recalc(slug: String, from: String?, to: String?, adults: Int, children: Int, planId: Int?) async {
        guard let f = from, let t = to, LodgingDate.nights(f, t) >= 1 else {
            quote = nil
            quoteError = nil
            quoteLoading = false
            return
        }
        quoteLoading = true
        quoteError = nil
        do {
            quote = try await API.shared.lodgingQuote(
                slug: slug,
                body: LodgingQuoteReq(dateFrom: f, dateTo: t, adults: adults,
                                      children: children, rooms: 1, ratePlanId: planId)
            )
        } catch is CancellationError {
            return
        } catch {
            quote = nil
            // Отказ сервера (422 «минимальный срок…», «даты прошли») — его текстом;
            // «Проверьте связь» — только когда связи и правда нет.
            let api = error as? APIError
            var answered = api?.rejectStatus != nil
            if let a = api, case .server = a { answered = true }
            if answered, let a = api {
                quoteError = a.errorDescription ?? "Не удалось посчитать"
            } else {
                quoteError = "Не удалось посчитать. Проверьте связь."
            }
        }
        quoteLoading = false
    }

    /// Возвращает бронь, чтобы экран сам показал итоговую шторку (одна шторка
    /// на экран — состоянием владеет вьюха, а не модель).
    /// Один ключ на набор условий; сумма во входах — после 409 price_changed ключ новый.
    private var bookKey: (params: String, key: String)?
    private func bookIdemKey(for params: String) -> String {
        if let k = bookKey, k.params == params { return k.key }
        let k = UUID().uuidString.lowercased(); bookKey = (params, k); return k
    }

    func book(slug: String, from: String, to: String, adults: Int, children: Int,
              planId: Int?, name: String, phone: String, comment: String) async -> LodgingBookResp? {
        guard !sending else { return nil }   // двойной тап не создаёт вторую бронь
        sending = true
        defer { sending = false }
        do {
            let resp = try await API.shared.lodgingBook(
                slug: slug,
                body: LodgingBookReq(dateFrom: from, dateTo: to, adults: adults,
                                     children: children, rooms: 1, ratePlanId: planId,
                                     guestName: name.isEmpty ? nil : name,
                                     guestPhone: phone.isEmpty ? nil : phone,
                                     guestComment: comment.isEmpty ? nil : comment,
                                     // Сумма из расчёта: сервер не оформит бронь
                                     // дороже той, что гость видел на экране.
                                     expectedTotal: quote.map { "\($0.totalValue)" },
                                     idempotencyKey: bookIdemKey(for: "\(slug)|\(from)|\(to)|\(adults)|\(children)|\(planId ?? 0)|\(quote?.totalValue ?? 0)"))
            )
            bookKey = nil
            Haptics.success()
            // Даты после брони заняты — обновляем календарь, чтобы их нельзя
            // было выбрать повторно, не выходя с экрана.
            await reloadCalendar(slug: slug)
            return resp
        } catch {
            Haptics.error()
            // APIError — LocalizedError, поэтому тут уже текст сервера
            // («Минимальный срок…»), а не «Ошибка 422».
            message = error.localizedDescription
            // ПЕРЕСЧИТЫВАЕМ. Отказ «цена изменилась» приходит вместе с новой
            // суммой, и без пересчёта повторное нажатие отправляло прежнюю
            // ожидаемую сумму и получало тот же отказ — экран становился
            // тупиком. Так же поступает сайт.
            await recalc(slug: slug, from: from, to: to, adults: adults, children: children, planId: planId)
            return nil
        }
    }

    /// true — заявка ушла (экран тогда забывает черновик формы).
    @discardableResult
    func longRequest(slug: String, desiredFrom: String?, months: Int, adults: Int, children: Int,
                     name: String, phone: String, comment: String) async -> Bool {
        // Вторая заявка, пока первая ещё уходит, хозяину не нужна (как у брони).
        guard !sending else { return false }
        sending = true
        defer { sending = false }
        do {
            let r = try await API.shared.lodgingLongRequest(
                slug: slug,
                body: LodgingLongRequestReq(desiredFrom: desiredFrom, months: months,
                                            adults: adults, children: children, pets: false,
                                            name: name.isEmpty ? nil : name,
                                            phone: phone.isEmpty ? nil : phone,
                                            message: comment.isEmpty ? nil : comment)
            )
            message = r.isDuplicate
                ? "Заявка уже отправлена, хозяин с вами свяжется"
                : "Заявка отправлена, хозяин свяжется с вами"
            return true
        } catch {
            message = error.localizedDescription
            return false
        }
    }
}

// MARK: - Экран

struct LodgingUnitView: View {
    let slug: String

    @EnvironmentObject private var session: Session
    @StateObject private var vm = LodgingUnitVM()

    @State private var from: String?
    @State private var to: String?
    @State private var adults = 2
    @State private var children = 0
    @State private var planId: Int?
    @State private var booked: LodgingBookResp?

    /// Даты и число гостей из поиска. Раньше карточка открывалась пустой
    /// («Выбрать даты», 2 взрослых), и выбранное в поиске приходилось вводить
    /// заново. Без параметров — как прежде (из «Моих поездок», по ссылке).
    init(slug: String, from: String? = nil, to: String? = nil, guests: Int? = nil) {
        self.slug = slug
        if let f = from, let t = to, LodgingDate.nights(f, t) >= 1 {
            _from = State(initialValue: f)
            _to = State(initialValue: t)
        }
        if let g = guests, g > 0 { _adults = State(initialValue: g) }
    }
    /// Данные гостя из шторки брони. Бронь стартует ПОСЛЕ закрытия шторки
    /// (как пополнение в кошельке): быстрый ответ приходил, пока шторка ещё
    /// уезжала, и «Забронировано» или ошибка не показывались вовсе.
    private struct PendingBook { let name: String; let phone: String; let comment: String }
    @State private var pendingBook: PendingBook?
    /// Заявка на длительную аренду — тоже после закрытия шторки: ответ
    /// («Заявка отправлена» или ошибка) приходил, пока шторка уезжала, и
    /// алерт с ним не показывался — человек не знал, ушла ли заявка.
    @State private var pendingLong: PendingBook?
    /// Что гость ввёл в шторке брони / заявки. Бронь не прошла (нет сети,
    /// сессия, отказ) — раньше при повторном открытии пожелания пропадали,
    /// а имя и телефон сбрасывались на профиль. Забываем только после успеха.
    @State private var bookDraft: PendingBook?
    @State private var longDraft: PendingBook?

    private func startPendingBook() {
        if let l = pendingLong {
            pendingLong = nil
            Task {
                let ok = await vm.longRequest(slug: slug, desiredFrom: from,
                                              months: vm.data?.unit?.longTerm?.minMonthsValue ?? 1,
                                              adults: adults, children: children,
                                              name: l.name, phone: l.phone, comment: l.comment)
                if ok { longDraft = nil }
            }
        }
        guard let p = pendingBook else { return }
        pendingBook = nil
        guard let f = from, let t = to else { return }
        Task {
            if let resp = await vm.book(slug: slug, from: f, to: t,
                                        adults: adults, children: children, planId: planId,
                                        name: p.name, phone: p.phone, comment: p.comment) {
                booked = resp
                bookDraft = nil
                sheet = .booked
                // Даты уже забронированы: прежний расчёт оставлял активной
                // «Забронировать», и повторное нажатие оформляло вторую бронь
                // (ключ повтора после успеха новый). Сбрасываем выбор дат.
                from = nil
                to = nil
            }
        }
    }

    /// ОДНА шторка на экран (см. шапку файла).
    private enum Sheet: Int, Identifiable {
        case dates, booking, long, booked
        var id: Int { rawValue }
    }
    @State private var sheet: Sheet?

    /// ОДНО состояние навигации на экран (см. шапку файла).
    private enum Route: Hashable {
        case org(String)
        case trips
        case auth
    }
    @State private var route: Route?

    /// «Мои поездки» из шторки «Бронь оформлена» пушились, пока шторка ещё
    /// уезжала, а долгое «Назад» снимало несколько экранов сразу — сеттер
    /// navigationDestination(isPresented:) не звался, route «висел», и кнопки
    /// «Организация» / «Мои поездки» больше ничего не открывали (как на
    /// Главной). Сначала сбрасываем, потом идём.
    private func go(_ r: Route) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    /// Ключ расчёта: меняется — .task(id:) сам пересчитывает и отменяет предыдущий.
    private struct QuoteKey: Equatable {
        let from: String?
        let to: String?
        let adults: Int
        let children: Int
        let planId: Int?
    }
    private var quoteKey: QuoteKey {
        QuoteKey(from: from, to: to, adults: adults, children: children, planId: planId)
    }

    var body: some View {
        ScrollView {
            if let unit = vm.data?.unit {
                LazyVStack(alignment: .leading, spacing: YMSpace.md) {
                    photos
                    headline(unit)
                    if let d = unit.description, !d.isEmpty {
                        Text(d)
                            .font(YMFont.body)
                            .foregroundStyle(YMColor.text)
                            .padding(.horizontal, YMSpace.xl)
                    }
                    if unit.isDaily {
                        bookingCard(unit)
                    }
                    amenities
                    rules(unit)
                    // Блок с «Оставить заявку» не прячем и без цены за месяц: объект стоит
                    // в «Длительно», сервер заявку принимает, другой кнопки на экране нет.
                    if let lt = unit.longTerm {
                        longTerm(lt)
                    }
                    Color.clear.frame(height: YMSpace.xxxl)
                }
                .padding(.top, YMSpace.sm)
            } else if vm.loading {
                VStack(spacing: YMSpace.md) {
                    SkeletonBox(radius: YMRadius.card).frame(height: 190)
                    SkeletonBox(radius: YMRadius.control).frame(height: 24)
                    SkeletonBox(radius: YMRadius.control).frame(height: 180)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.md)
            } else if let e = vm.loadError {
                // Ошибка загрузки — с повтором.
                ErrorRetryView(message: e) { Task { await vm.load(slug: slug) } }
                    .padding(.top, 40)
            } else {
                Text("Объект не найден или снят с публикации.")
                    .font(YMFont.callout)
                    .foregroundStyle(YMColor.muted)
                    .padding(YMSpace.xl)
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle(vm.data?.unit?.title ?? "Жильё")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await vm.load(slug: slug)
            // Объект на одного гостя открывался с «2 взрослых»: «+» выключен,
            // первый расчёт отвечал «нельзя». Не больше вместимости.
            if let u = vm.data?.unit, adults > u.maxGuestsValue { adults = u.maxGuestsValue }
        }
        .task(id: quoteKey) {
            await vm.recalc(slug: slug, from: from, to: to,
                            adults: adults, children: children, planId: planId)
        }
        .sheet(item: $sheet, onDismiss: startPendingBook) { which in
            switch which {
            case .dates:
                LodgingDatesSheet(from: from, to: to,
                                  minNights: vm.data?.unit?.minNightsValue ?? 1,
                                  days: vm.days) { f, t in
                    from = f
                    to = t
                }
            case .booking:
                LodgingGuestSheet(
                    title: "Бронирование",
                    confirmTitle: "Забронировать",
                    name: bookDraft?.name ?? vm.myName,
                    phone: bookDraft?.phone ?? vm.myPhone,
                    comment: bookDraft?.comment ?? "",
                    note: "По телефону с вами свяжутся при опоздании или вопросах по заселению."
                ) { name, phone, comment in
                    let p = PendingBook(name: name, phone: phone, comment: comment)
                    pendingBook = p
                    bookDraft = p
                }
            case .long:
                LodgingGuestSheet(
                    title: "Заявка на длительную аренду",
                    confirmTitle: "Отправить",
                    name: longDraft?.name ?? vm.myName,
                    phone: longDraft?.phone ?? vm.myPhone,
                    comment: longDraft?.comment ?? "",
                    note: "Онлайн такая аренда не бронируется: хозяин свяжется с вами и договорится о просмотре."
                ) { name, phone, comment in
                    // Отправка — в onDismiss шторки (startPendingBook).
                    let p = PendingBook(name: name, phone: phone, comment: comment)
                    pendingLong = p
                    longDraft = p
                }
            case .booked:
                if let b = booked {
                    LodgingBookedSheet(resp: b) {
                        sheet = nil
                        go(.trips)
                    }
                }
            }
        }
        .alert(vm.message ?? "", isPresented: Binding(
            get: { vm.message != nil }, set: { if !$0 { vm.message = nil } }
        )) {
            Button("Понятно") { vm.message = nil }
        }
        .navigationDestination(isPresented: Binding(
            get: { route != nil }, set: { if !$0 { route = nil } }
        )) {
            switch route {
            case .org(let s):  OrgView(shopSlug: s)
            case .trips:       LodgingTripsView()
            case .auth:        AuthView()
            case .none:        EmptyView()
            }
        }
    }

    // ── Части экрана ──

    @ViewBuilder
    private var photos: some View {
        let list = vm.data?.photosList ?? []
        if list.isEmpty {
            PhotoPlaceholder(url: nil, label: "ФОТО", radius: YMRadius.card, tone: 0)
                .frame(height: 190)
                .padding(.horizontal, YMSpace.xl)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMSpace.sm) {
                    ForEach(list) { p in
                        PhotoPlaceholder(
                            url: API.imageURL(p.path),
                            label: "ФОТО",
                            radius: YMRadius.card,
                            tone: p.identifier
                        )
                        .frame(width: 280, height: 190)
                    }
                }
                .padding(.horizontal, YMSpace.xl)
            }
        }
    }

    private func headline(_ unit: LodgingUnitFull) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(unit.title ?? "Жильё")
                .font(YMFont.title2)
                .foregroundStyle(YMColor.text)
            Text(LodgingText.unitPlace(unit, shop: vm.data?.shop))
                .font(YMFont.caption)
                .foregroundStyle(YMColor.muted)
            if let sh = vm.data?.shop, let sl = sh.slug, !sl.isEmpty {
                Button(sh.name ?? "Организация") { go(.org(sl)) }
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.accent)
                    .padding(.top, YMSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, YMSpace.xl)
    }

    private func bookingCard(_ unit: LodgingUnitFull) -> some View {
        let plans = vm.data?.plansList ?? []
        let canBook = vm.quote?.canBook == true
        return VStack(alignment: .leading, spacing: YMSpace.sm) {
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(Money.format(unit.priceNightValue))
                    .font(YMFont.title3).foregroundStyle(YMColor.text)
                Text("за ночь").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            if let w = unit.priceWeekend, w > 0 {
                Text("В пятницу и субботу " + Money.format(w))
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }

            Button {
                Haptics.light()
                sheet = .dates
            } label: {
                Text(LodgingText.datesTitle(from, to))
                    .font(YMFont.body)
                    .foregroundStyle(YMColor.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(YMSpace.md)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            LodgingStepper(label: "Взрослых", value: $adults, range: 1...unit.maxGuestsValue)
            if unit.childrenMax > 0 {
                LodgingStepper(label: "Детей", value: $children, range: 0...unit.childrenMax)
            }

            if !plans.isEmpty {
                Text("Тариф").font(YMFont.subhead).foregroundStyle(YMColor.text)
                planRow(title: "Базовый", subtitle: nil, selected: planId == nil) { planId = nil }
                ForEach(plans) { p in
                    planRow(title: p.title, subtitle: p.mealLabel, selected: planId == p.identifier) {
                        planId = p.identifier
                    }
                }
            }

            quoteBlock

            // Бронь требует аккаунта (сервер: ['auth']). Гостя ведём на вход,
            // а не показываем ему форму, которая закончится «сессия истекла».
            // «Выберите даты» писалось и при выбранных датах — пока идёт расчёт
            // или когда объект на них занят (причина выше); это сбивало с толку.
            // Паритет с Android: без дат кнопка «Выберите даты» открывает календарь
            // (раньше была серой и не нажималась).
            let needDates = (from == nil || to == nil) && !vm.sending
            Button(canBook || (from != nil && to != nil) ? "Забронировать" : "Выберите даты") {
                Haptics.medium()
                if needDates { sheet = .dates; return }
                if session.isLoggedIn { sheet = .booking } else { go(.auth) }
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(!(canBook || needDates) || vm.sending)
            .opacity(canBook || needDates ? 1 : 0.5)

            Text(LodgingText.bookingNote(unit))
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        .padding(YMSpace.md)
        .ymCard()
        .padding(.horizontal, YMSpace.xl)
    }

    private func planRow(title: String, subtitle: String?, selected: Bool,
                         action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(YMFont.body).foregroundStyle(YMColor.text)
                if let s = subtitle, !s.isEmpty {
                    Text(s).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, YMSpace.md).padding(.vertical, YMSpace.sm)
            .background(selected ? YMColor.surface2 : Color.clear,
                        in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                    .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var quoteBlock: some View {
        if vm.quoteLoading {
            Text("Считаем…").font(YMFont.caption).foregroundStyle(YMColor.muted)
        } else if let e = vm.quoteError {
            Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
        } else if let q = vm.quote {
            if q.canBook {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(q.linesList) { l in
                        HStack {
                            Text(l.labelText).font(YMFont.callout).foregroundStyle(YMColor.muted)
                            Spacer()
                            Text(Money.format(l.amountValue)).font(YMFont.callout).foregroundStyle(YMColor.text)
                        }
                    }
                    HStack {
                        Text("Итого").font(YMFont.headline).foregroundStyle(YMColor.text)
                        Spacer()
                        Text(Money.format(q.totalValue)).font(YMFont.headline).foregroundStyle(YMColor.text)
                    }
                    .padding(.top, YMSpace.xs)
                    if q.prepayValue > 0 {
                        Text("Предоплата " + Money.format(q.prepayValue) + " — запросит объект")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    if q.depositValue > 0 {
                        Text("Залог " + Money.format(q.depositValue) + " — возвращается при выезде")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    if let dl = q.cancelDeadline, !dl.isEmpty {
                        Text("Бесплатная отмена до " + LodgingDate.human(dl))
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                }
            } else {
                Text(q.reasonText ?? "На эти даты забронировать нельзя")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
            }
        } else {
            Text("Выберите даты — посчитаем стоимость.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
    }

    @ViewBuilder
    private var amenities: some View {
        let list = vm.data?.amenitiesList ?? []
        if !list.isEmpty {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Text("Удобства").font(YMFont.title3).foregroundStyle(YMColor.text)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(list) { a in
                        Text(((a.icon ?? "") + " " + (a.name ?? "")).trimmingCharacters(in: .whitespaces))
                            .font(YMFont.callout)
                            .foregroundStyle(YMColor.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private func rules(_ unit: LodgingUnitFull) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text("Правила и оплата").font(YMFont.title3).foregroundStyle(YMColor.text)
                .padding(.bottom, YMSpace.xs)
            ForEach(LodgingText.rules(unit), id: \.self) { line in
                ruleLine(line)
            }
            if let t = unit.rulesText, !t.isEmpty {
                Text(t).font(YMFont.callout).foregroundStyle(YMColor.text)
                    .padding(.top, YMSpace.xs)
            }
            if let no = unit.registry?.no, !no.isEmpty {
                // ПП РФ 1853: номер в реестре классифицированных средств
                // размещения обязателен к показу.
                Text("Номер в реестре средств размещения: " + no)
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .padding(.top, YMSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, YMSpace.xl)
    }

    private func ruleLine(_ text: String) -> some View {
        Text("• " + text)
            .font(YMFont.callout)
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func longTerm(_ lt: LodgingLongTerm) -> some View {
        let deposit = lt.depositMonth ?? 0
        return VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text("Длительная аренда").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(LodgingText.longTerm(lt))
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
            if deposit > 0 {
                Text("Залог " + Money.format(deposit))
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            Button("Оставить заявку") {
                Haptics.light()
                if session.isLoggedIn { sheet = .long } else { go(.auth) }
            }
            .buttonStyle(YMSecondaryButtonStyle())
            // Пока прежняя заявка/бронь уходит, новую форму не открываем:
            // её отправка молча отбросилась бы.
            .disabled(vm.sending)
            .padding(.top, YMSpace.xs)
            Text("Онлайн такая аренда не бронируется: хозяин свяжется с вами и договорится о просмотре.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, YMSpace.xl)
    }
}

// MARK: - Форма гостя (бронь и заявка на аренду)

struct LodgingGuestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let confirmTitle: String
    let note: String
    let onConfirm: (String, String, String) -> Void

    @State private var name: String
    @State private var phone: String
    @State private var comment = ""

    /// comment — пожелания из прошлой неудачной попытки (по умолчанию пусто).
    init(title: String, confirmTitle: String, name: String, phone: String,
         comment: String = "",
         note: String, onConfirm: @escaping (String, String, String) -> Void) {
        self.title = title
        self.confirmTitle = confirmTitle
        self.note = note
        self.onConfirm = onConfirm
        self._name = State(initialValue: name)
        self._phone = State(initialValue: phone)
        self._comment = State(initialValue: comment)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YMSpace.md) {
                    // П-25 №6: пределы брони жилья (guest_name 190, guest_phone 32,
                    // guest_comment 1000) — длиннее сервер режет молча.
                    field("Имя гостя", text: $name, keyboard: .default, caps: true)
                        .ymMaxLength($name, 190)
                    field("Телефон", text: $phone, keyboard: .phonePad, caps: false)
                        .ymMaxLength($phone, 32)
                    // Без телефона кнопка вверху серая, и было непонятно почему
                    // (в профиле телефона нет — поле пустое).
                    if phoneTooShort {
                        Text("Укажите телефон — без него «\(confirmTitle)» недоступно")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    }
                    field("Пожелания", text: $comment, keyboard: .default, caps: false)
                        .ymMaxLength($comment, 1000)
                    Text(note).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.md)
            }
            // У цифровой клавиатуры телефона нет «Готово» — убираем жестом прокрутки.
            .scrollDismissesKeyboard(.interactively)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) {
                        onConfirm(name.trimmingCharacters(in: .whitespaces),
                                  phone.trimmingCharacters(in: .whitespaces),
                                  comment.trimmingCharacters(in: .whitespaces))
                        dismiss()
                    }
                    .disabled(phoneTooShort)
                }
            }
        }
    }

    private var phoneTooShort: Bool { phone.trimmingCharacters(in: .whitespaces).count < 5 }

    private func field(_ label: String, text: Binding<String>,
                       keyboard: UIKeyboardType, caps: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(YMFont.caption).foregroundStyle(YMColor.muted)
            TextField("", text: text)
                .font(YMFont.body)
                .keyboardType(keyboard)
                .textInputAutocapitalization(caps ? .words : .never)
                .autocorrectionDisabled(!caps)
                .padding(YMSpace.md)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1)
                )
        }
    }
}

// MARK: - Итог брони

struct LodgingBookedSheet: View {
    @Environment(\.dismiss) private var dismiss
    let resp: LodgingBookResp
    let onTrips: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                Text(LodgingText.bookedTitle(resp))
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                Text(LodgingText.bookedSummary(resp))
                    .font(YMFont.body).foregroundStyle(YMColor.muted)
                Text(LodgingText.stay(checkIn: resp.checkInFrom, checkOut: resp.checkOutUntil) + ".")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                if resp.prepayValue > 0 {
                    Text("Предоплата " + Money.format(resp.prepayValue) + " — объект свяжется с вами")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                if let dl = resp.cancelDeadline, !dl.isEmpty {
                    Text("Бесплатная отмена до " + LodgingDate.human(dl))
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                Spacer()
                Button("Мои поездки") { onTrips() }
                    .buttonStyle(YMPrimaryButtonStyle())
                Button("Закрыть") { dismiss() }
                    .buttonStyle(YMGhostButtonStyle())
            }
            .padding(YMSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Бронь оформлена")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
