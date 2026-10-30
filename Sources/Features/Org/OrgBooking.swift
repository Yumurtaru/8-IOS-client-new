import SwiftUI

//
//  OrgBooking.swift — запись на услуги (для организаций mode == "service").
//  1:1 с Android OrgBooking.kt (премиум-стиль YM*).
//
//  Поток:
//    GET  api/v1/shops/{slug}/services            -> ServicesResponse(.services: [ServiceItem])
//    выбор услуги -> GET api/v1/services/{id}/slots?date=YYYY-MM-DD -> [Slot]
//    выбор слота  -> подтверждение -> POST api/v1/appointments (AppointmentBody{slotId})
//                                     -> OrderCreateResult(.id) -> экран «Вы записаны»
//
//  Деньги — только Decimal через Money (никогда Double в UI).
//  Дата — "yyyy-MM-dd", сегодня + ближайшие 13 дней (bookingDays). В ленте —
//  только даты, где есть свободные окна (см. «обзор дат» ниже).
//  А115: лента дат — одним запросом GET api/v1/services/{id}/dates?from=&days=14
//  ([{date, free_slots}], только дни со свободным окном). Окна дня — как раньше,
//  /slots?date= выбранной даты. Ручки нет (404), сеть, 5xx — прежний обход по дням.
//  NULL-безопасность: списки ?? [], строки isEmpty.
//

// MARK: - Одна дата в ленте выбора

/// Сколько дней вперёд смотрим окна записи. Даты с окнами — одним запросом
/// GET api/v1/services/{id}/dates (А115). Старый сервер такой ручки не знает:
/// тогда каждую дату ленты спрашиваем отдельно (/slots?date=) — не больше
/// bookingScanParallel запросов одновременно. 1:1 с Android.
private let bookingDays = 14
private let bookingScanParallel = 4
/// Сколько обзор дат считается свежим (с): свежий показываем без запросов.
private let dayScanFreshSeconds: TimeInterval = 60

/// Итог обзора дат одной услуги. slots — окна по датам (даты с упавшим запросом
/// в нём отсутствуют), empty — даты, где окон точно нет. at — когда обзор начат.
/// free — число свободных окон по датам (free_slots ручки /dates); nil — обзор
/// шёл старым обходом по дням. Окон дат при обзоре одним запросом в slots нет:
/// их грузит выбор даты.
private struct DayScan {
    let serviceId: Int
    let dates: [String]
    var slots: [String: [Slot]]
    let empty: Set<String>
    let at: Date
    var free: [String: Int]? = nil
}

/// Число окон со свободным местом — как free_slots сервера.
private func bookingFreeCount(_ list: [Slot]) -> Int {
    list.filter { $0.freeValue >= 1 }.count
}

/// Строка ответа GET api/v1/services/{id}/dates: {date, free_slots}.
private struct ServiceFreeDate: Decodable {
    let date: String?
    @LenientInt var freeSlots: Int?
}

/// data ручки /dates — строго массив: другой ответ (не та ручка, старый сервер)
/// — ошибка разбора и прежний обход по дням, а не «свободных дат нет».
private struct ServiceFreeDates: Decodable {
    let days: [ServiceFreeDate]
    init(from decoder: Decoder) throws {
        let arr = try [LossyElement<ServiceFreeDate>](from: decoder)
        days = arr.compactMap { $0.value }
    }
}

/// Итог запроса дат одним запросом.
private enum BookingDatesResult {
    /// Дата → free_slots (только дни со свободным окном).
    case dates([String: Int])
    /// Ручки нет (404 старого сервера: «Эндпоинт не найден», code no_route), сеть,
    /// 5xx, 429 (у /slots лимита нет, а 429 бывает за общим NAT), непонятный
    /// ответ — прежний обход по дням.
    case fallback
    /// 404 «Услуга не найдена» нового сервера (услугу или заведение сняли):
    /// обходить дни незачем — «запись недоступна» с повтором. 1:1 с Android.
    case gone
}

private func bookingFreeDates(_ serviceId: Int, from: String, days: Int) async -> BookingDatesResult {
    do {
        let r: ServiceFreeDates = try await API.shared.get(
            "api/v1/services/\(serviceId)/dates", query: ["from": from, "days": String(days)])
        var out: [String: Int] = [:]
        for d in r.days {
            guard let day = d.date?.prefix(10), day.count == 10 else { continue }
            out[String(day)] = max(0, d.freeSlots ?? 0)
        }
        return .dates(out)
    } catch {
        // Старый сервер на неизвестную ручку — 404 с code no_route (index.php),
        // снятая услуга — 404 «Услуга не найдена» без кода (как Android).
        if let e = error as? APIError, case .rejected(404, let msg, _) = e, e.errorCode != "no_route",
           msg.trimmingCharacters(in: .whitespacesAndNewlines) == "Услуга не найдена" {
            return .gone
        }
        // Отмена — тоже сюда: обзор проверит Task.isCancelled и ничего не запишет.
        return .fallback
    }
}

/// Окна даты, обновлённые на месте (запись, перечитывание): обзор, начатый
/// раньше, их не перетирает.
private struct LocalDaySlots {
    let at: Date
    let slots: [Slot]
}

/// Обзор дат живёт вне вью: при каждом возврате с карточки товара (.task)
/// уходило 14 запросов. Ключ — заведение + услуга + первый день ленты. 1:1 с Android.
@MainActor
private final class DayScanCache {
    static let shared = DayScanCache()
    private var map: [String: DayScan] = [:]
    private var order: [String] = []
    /// Правки на месте: "заведение|услуга|дата" -> окна и когда. Обзор, начатый
    /// раньше правки, при сохранении её не затирает — иначе занятое записью
    /// окно всплывало бы из «свежего» обзора как свободное.
    private var patches: [String: LocalDaySlots] = [:]
    private var patchOrder: [String] = []

    private func key(_ slug: String, _ serviceId: Int, _ firstDay: String) -> String {
        "\(slug)|\(serviceId)|\(firstDay)"
    }

    func get(_ slug: String, _ serviceId: Int, _ firstDay: String) -> DayScan? {
        map[key(slug, serviceId, firstDay)]
    }

    /// Сохраняет обзор с правками, сделанными после его начала; возвращает итог.
    @discardableResult
    func put(_ slug: String, _ scan: DayScan) -> DayScan {
        guard let first = scan.dates.first else { return scan }
        var slots = scan.slots
        var empty = scan.empty
        var free = scan.free
        for d in scan.dates {
            guard let pt = patches["\(slug)|\(scan.serviceId)|\(d)"], pt.at > scan.at else { continue }
            slots[d] = pt.slots
            if !pt.slots.isEmpty { empty.remove(d) }
            if free != nil { free?[d] = bookingFreeCount(pt.slots) }
        }
        let merged = DayScan(serviceId: scan.serviceId, dates: scan.dates, slots: slots, empty: empty, at: scan.at,
                             free: free)
        let k = key(slug, scan.serviceId, first)
        map[k] = merged
        order.removeAll { $0 == k }
        order.append(k)
        while order.count > 24 { map[order.removeFirst()] = nil }
        return merged
    }

    /// Окна даты изменились на месте (запись, перечитывание) — правим и обзор.
    func patch(_ slug: String, _ serviceId: Int, _ date: String, _ list: [Slot]) {
        let pk = "\(slug)|\(serviceId)|\(date)"
        patches[pk] = LocalDaySlots(at: Date(), slots: list)
        patchOrder.removeAll { $0 == pk }
        patchOrder.append(pk)
        while patchOrder.count > 64 { patches[patchOrder.removeFirst()] = nil }
        let prefix = "\(slug)|\(serviceId)|"
        for k in map.keys where k.hasPrefix(prefix) {
            guard var e = map[k], e.dates.contains(date) else { continue }
            e.slots[date] = list
            if e.free != nil { e.free?[date] = bookingFreeCount(list) }
            map[k] = e
        }
    }
}

/// Окна одной даты для обзора дат. nil — запрос не удался (сеть, сбой): такая
/// дата из ленты не прячется.
private func bookingDaySlots(_ serviceId: Int, _ date: String) async -> [Slot]? {
    do {
        let list: [Slot] = try await API.shared.list("api/v1/services/\(serviceId)/slots", query: ["date": date])
        return list
    } catch {
        return nil
    }
}

private struct DayOption: Identifiable, Equatable {
    let value: String    // "yyyy-MM-dd" — для API
    let weekday: String  // "Сегодня" / "Пн" …
    let dayNum: String   // "3"
    var id: String { value }
}

// MARK: - Секция записи (встраивается в sheet OrgView как обычный VStack)

struct OrgBookingSection: View {
    let slug: String
    let detail: ShopDetail?
    /// Гость нажал «Записаться» — родитель показывает вход.
    var onNeedAuth: () -> Void = {}
    /// Организация услуг (mode == "service") — у неё это основной раздел.
    /// У ресторана или магазина услуги идут дополнительным блоком: меняется
    /// заголовок, а при пустом списке блок не рисуется вовсе (hideWhenEmpty).
    var serviceOrg: Bool = true
    var hideWhenEmpty: Bool = false

    @State private var services: [ServiceItem] = []
    @State private var loading = true
    @State private var error: String?

    @State private var days: [DayOption] = OrgBookingSection.nearestDays(bookingDays)
    @State private var selectedDate: String = ""
    @Environment(\.scenePhase) private var scenePhase
    /// Приложение уходило в фон (а не просто шторка уведомлений сверху).
    @State private var wasInBackground = false
    @State private var selected: ServiceItem?

    @State private var slots: [Slot] = []
    @State private var loadingSlots = false
    @State private var slotsError: String?

    // Обзор дат: в ленте только дни, где у выбранной услуги есть свободные окна.
    // daySlots — окна по датам (кеш для переключения дат без запроса), dayEmpty —
    // даты, где окон точно нет (их прячем). Дата, запрос которой не удался, в
    // dayEmpty не попадает и остаётся в ленте: из-за сбоя связи не должны
    // исчезнуть все дни. scanFor — для какой услуги эти данные.
    @State private var daySlots: [String: [Slot]] = [:]
    @State private var dayEmpty: Set<String> = []
    /// А115: свободных окон по датам (free_slots) — мелко под датой. nil — обзор
    /// старым обходом по дням: числа не показываем.
    @State private var dayFree: [String: Int]?
    /// "услуга|дата", чьи окна сейчас в slots: перечитывание той же даты (после
    /// обзора дат, из фона) идёт без индикатора — список не мигает.
    @State private var slotsKey: String?
    /// А115: /dates ответил «Услуга не найдена» — вместо ленты «запись недоступна»
    /// с повтором. Снимает удачный обзор.
    @State private var datesGone: Int?
    @State private var scanFor: Int?
    @State private var scanning = false
    /// Номер обзора: ответ устаревшего обзора (сменили услугу) ничего не пишет.
    @State private var scanGen = 0
    @State private var scanTask: Task<Void, Never>?
    /// Итог обзора, который ещё не показан: пока открыто подтверждение, дату и
    /// окна под ним не меняем — применяем после закрытия.
    @State private var scanArrived: DayScan?
    /// "услуга|дата" -> окна, обновлённые на месте.
    @State private var localFresh: [String: LocalDaySlots] = [:]

    // Единый модальный поток: подтверждение → успех (один .sheet во избежание
    // конфликта двух одновременных .sheet на одной вью).
    private enum BookingSheet: Identifiable {
        case confirm(Slot)
        case success(Int)
        var id: String {
            switch self {
            case .confirm(let s): return "confirm-\(s.id)"
            case .success(let o): return "success-\(o)"
            }
        }
    }
    @State private var sheet: BookingSheet?
    @State private var confirming = false
    /// Ключ повтора записи: один на окно подтверждения — новый при каждом его
    /// открытии (сервер А316+: новый ключ — новая запись, «склейки» 10 минут
    /// больше нет). После окончательного ответа — забыт.
    @State private var apptKey: (params: String, key: String)?
    /// Исход записи неизвестен (обрыв после отправки, таймаут, 5xx): форма заперта,
    /// «Подтвердить» уйдёт тем же ключом и тем же телом.
    @State private var apptUnsure = false
    /// Окно закрыли с неизвестным исходом (или сессия умерла / 401 на повторе):
    /// запоминаем окно с составом, ключ и тело. Снова то же окно с тем же составом —
    /// тот же ключ и запертая форма (новый ключ создал бы вторую запись в окне на
    /// несколько мест: сервер с ключом склейку не делает). Забывается только после
    /// окончательного ответа по этому окну.
    @State private var apptPending: (params: String, key: String, address: VisitAddress, comment: String)?
    /// Ошибка связи прошлой попытки — в самом окне подтверждения (оно не закрывается).
    @State private var confirmError: String?
    /// Адрес визита — только для выездной услуги (сантехник, уборка на дом).
    /// Заполняется в окне подтверждения: у записи, в отличие от доставки,
    /// другого места спросить адрес нет.
    @State private var visitAddress = VisitAddress()
    /// Сохранённые адреса клиента — чтобы не набирать заново то, что уже есть
    /// в профиле. Грузим только если среди услуг есть выездные.
    @State private var savedAddresses: [Address] = []
    /// А63: «Комментарий мастеру» (до 300 знаков) — сервер сохраняет и
    /// показывает мастеру. Очищается после успешной записи.
    @State private var masterComment = ""
    @State private var actionMessage: String?
    /// Человек и часов в брони. Сбрасываются при смене услуги: у каждой свои
    /// пределы, и «3 человека» от игрового зала на массаже неуместны.
    @State private var guests = 1
    @State private var hours = 1
    /// Данные успешной брони — экран успеха печатает их как есть, без расчётов.
    @State private var lastBooking: AppointmentResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // У ресторана или магазина это не «запись к мастеру», а бронь
            // игрового зала или кинозала — заголовок должен это отражать.
            Text(serviceOrg ? "Запись на услугу" : "Услуги и бронирование")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)

            Group {
                if loading {
                    VStack(spacing: 10) {
                        ForEach(0..<3, id: \.self) { _ in
                            SkeletonBox(radius: 16).frame(height: 72)
                        }
                    }
                } else if let e = error, !e.isEmpty {
                    // Ошибка загрузки услуг — с «Повторить»: раньше повторить можно
                    // было только выйдя из заведения и зайдя снова.
                    VStack(spacing: 8) {
                        BookingNotice(text: e)
                        Button("Повторить") { Task { await loadServices() } }
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(YMColor.accent)
                    }
                } else if services.isEmpty {
                    BookingNotice(text: "Услуги появятся позже")
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(services.enumerated()), id: \.element.id) { idx, sv in
                            // Подзаголовок группы («Игровой зал», «Кинозал»):
                            // сервер уже отдаёт услуги в порядке групп.
                            if let g = sv.groupName, !g.isEmpty,
                               idx == 0 || services[idx - 1].groupName != g {
                                Text(g)
                                    .font(.system(size: 13, weight: .heavy))
                                    .foregroundStyle(YMColor.muted)
                                    .padding(.top, idx == 0 ? 0 : 6)
                            }
                            serviceBlock(sv)
                        }
                    }
                }
            }

            if let msg = actionMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YMColor.statusCancel)
                    .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Пустой дополнительный блок не занимает места и не пишет «услуги
        // появятся позже» на витрине кафе, у которого их просто нет.
        .opacity(hideWhenEmpty && !loading && services.isEmpty ? 0 : 1)
        .frame(height: hideWhenEmpty && !loading && services.isEmpty ? 0 : nil)
        .clipped()
        // Услуги — только если их ещё нет (или была ошибка): .task срабатывает и при
        // возврате с карточки товара, и раньше весь блок мигал скелетоном, а
        // меню под ним прыгало.
        .task {
            let daysChanged = refreshDaysIfStale(); if selectedDate.isEmpty { selectedDate = days.first?.value ?? "" }
            // Вернулись на экран с выбранной услугой (или сменился день) — даты
            // перечитываем фоном, даже если обзор в памяти свежий: окна могли
            // разобрать или добавить. Старая лента остаётся, индикатора нет.
            if selected != nil, sheet == nil || daysChanged { startDayScan(force: true) }
            if services.isEmpty || error != nil { await loadServices() }
        }
        // Вернулись в приложение на следующий день — дни пересчитываем.
        // Вернулись из фона — свободное время перечитываем: за это время окна
        // могли занять, и человек выбирал уже занятое (отказ на подтверждении).
        // День сменился — перечитает onChange даты. При открытом подтверждении
        // не трогаем: цена в нём считается по текущему списку окон.
        .onChange(of: scenePhase) { phase in
            if phase == .background { wasInBackground = true }
            guard phase == .active else { return }
            let daysChanged = refreshDaysIfStale()
            // Даты и окна перечитываем обзором дат (он же обновит выбранную дату).
            if selected != nil, (wasInBackground && sheet == nil) || daysChanged {
                startDayScan(force: true)
            }
            wasInBackground = false
        }
        // Уход с экрана — обзор дат больше не нужен.
        .onDisappear { stopDayScan() }
        // Подтверждение закрыто — показываем обзор, пришедший, пока оно было открыто.
        .onChange(of: sheet?.id) { _ in
            if !confirmOpen, let r = scanArrived { scanArrived = nil; applyScan(r) }
        }
        .sheet(item: $sheet) { s in
            switch s {
            case .confirm(let slot): confirmSheet(slot: slot)
            case .success(let oid):
                SuccessBookingSheet(orderId: oid, info: lastBooking) {
                    sheet = nil; actionMessage = nil; lastBooking = nil
                }
            }
        }
    }

    // MARK: Блок услуги + раскрывающийся выбор даты/слотов

    private func serviceBlock(_ sv: ServiceItem) -> some View {
        let isSel = selected?.id == sv.id
        let gone = datesGone == sv.id
        let daysReady = scanFor == sv.id && !gone
        let shownDays = daysReady ? days.filter { !dayEmpty.contains($0.value) } : []
        return VStack(spacing: 0) {
            ServiceRow(service: sv, selected: isSel, fee: clientFee(Money.dec(sv.price))) {
                Haptics.selection()
                withAnimation(.easeInOut(duration: 0.2)) {
                    selected = isSel ? nil : sv
                }
                if selected == nil { stopDayScan() }
            }
            if isSel {
                VStack(alignment: .leading, spacing: 10) {
                    // Лента — только даты с окнами (и те, что не удалось проверить).
                    // Пока даты проверяются — индикатор, а не пустое состояние.
                    if gone {
                        // А115: услугу сняли — без ленты, с повтором обзора по нажатию.
                        Button { startDayScan(force: true) } label: {
                            Text("Запись на эту услугу сейчас недоступна\nНажмите, чтобы повторить")
                                .font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 8)
                    } else if !daysReady {
                        HStack { Spacer(); ProgressView().tint(YMColor.accent); Spacer() }
                            .padding(.vertical, 14)
                    } else if shownDays.isEmpty {
                        Text("Свободных окон пока нет — загляните позже")
                            .font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
                            .padding(.vertical, 8)
                    } else {
                        DaySelector(days: shownDays, selected: selectedDate, free: dayFree ?? [:]) { d in
                            Haptics.selection()
                            selectedDate = d
                        }
                        // Сколько человек и на сколько часов. Показываем только там,
                        // где это что-то значит: у обычной услуги блока нет.
                        if sv.needsGuests {
                            CountStepper(
                                label: "Человек", value: $guests,
                                min: sv.guestsMin, max: sv.guestsMax,
                                hint: "Одновременно до \(sv.capacityValue)"
                            )
                        }
                        if sv.needsHours {
                            CountStepper(
                                label: "Часов подряд", value: $hours,
                                min: 1, max: sv.maxSlotsValue,
                                hint: "По \(Self.stepHint(sv, slots)) мин"
                            )
                        }
                        if sv.needsGuests || sv.needsHours {
                            HStack {
                                Text("Стоимость брони")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(YMColor.muted)
                                Spacer()
                                // Длину берём у первого доступного времени: сетка
                                // могла остаться от прежней длительности услуги, и
                                // цена «по услуге» расходилась бы с шагом
                                // подтверждения и с чеком.
                                Text(Money.format(sv.quote(guests: guests, slots: hours,
                                    minutesTotal: Self.previewMinutes(sv, slots, guests: guests, hours: hours))))
                                    .font(.system(size: 15, weight: .heavy))
                                    .foregroundStyle(YMColor.text)
                            }
                        }
                        Text("Свободное время")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(YMColor.muted)
                        slotsView
                    }
                }
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: selected?.id) { newId in
            // Обработчик висит на КАЖДОЙ строке услуги: раньше одно нажатие
            // запускало столько загрузок окон, сколько услуг в списке.
            // Реагирует только строка выбранной услуги.
            guard newId == sv.id else { return }
            // Пределы у новой услуги свои — сбрасываем выбор.
            guests = selected?.guestsMin ?? 1
            hours = 1
            // Обзор дат новой услуги; окна выбранной даты придут с ним.
            startDayScan()
            Task { await loadSlots() }
        }
        .onChange(of: selectedDate) { _ in if isSel { Task { await loadSlots() } } }
    }

    /// Окна, с которых можно начать бронь при текущем выборе человек/часов.
    private var startableSlots: [Slot] {
        Self.bookableStarts(slots, guests: guests, hours: hours, buffer: selected?.bufferMinutes ?? 0)
    }

    @ViewBuilder
    private var slotsView: some View {
        if loadingSlots {
            HStack { Spacer(); ProgressView().tint(YMColor.accent); Spacer() }
                .padding(.vertical, 8)
        } else if let e = slotsError, !e.isEmpty {
            // Повтор по нажатию: раньше после сбоя оставалось только переключать
            // день туда-обратно.
            Button { Task { await loadSlots(force: true) } } label: {
                Text("\(e). Нажмите, чтобы повторить")
                    .font(.system(size: 14.5)).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        } else if slots.isEmpty {
            Text("На эту дату нет свободных слотов")
                .font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
        } else {
            // Начать бронь можно только с окна, за которым идёт нужное число
            // окон подряд и в каждом хватает мест. Сервер проверит это ещё раз
            // под блокировкой — здесь мы просто не показываем занятое.
            if startableSlots.isEmpty {
                Text("На эту дату нет подходящего времени — попробуйте меньше часов или человек")
                    .font(.system(size: 14.5)).foregroundStyle(YMColor.muted)
            } else {
                SlotGrid(slots: startableSlots, showFree: (selected?.capacityValue ?? 1) > 1) { slot in
                    // Отказ прошлой попытки («окно занято») не висит над новой.
                    actionMessage = nil
                    if Session.shared.isLoggedIn {
                        confirmError = nil
                        let p = apptParams(slot.id)
                        if let m = apptPending, m.params == p {
                            // То же окно и состав после неизвестного исхода — тот же ключ
                            // и то же тело, форма заперта.
                            apptKey = (m.params, m.key); apptUnsure = true
                            visitAddress = m.address; masterComment = m.comment
                        } else {
                            // Новое окно подтверждения — новый ключ повтора.
                            apptKey = nil; apptUnsure = false
                        }
                        sheet = .confirm(slot)
                    } else { onNeedAuth() }
                }
            }
        }
    }

    // MARK: Подтверждение

    private func confirmSheet(slot: Slot) -> some View {
        let atClient = selected?.isAtClient ?? false
        // Цена брони, а не цена услуги: у игрового зала это 150 ₽ × человек × часы.
        // Длину берём у выбранных окон: 30 + 60 мин — это 1,5 часа, а не 2×30.
        let chain = Self.chainMinutes(slots, from: slot, hours: hours, buffer: selected?.bufferMinutes ?? 0)
        let price = selected?.quote(guests: guests, slots: hours, minutesTotal: chain) ?? 0
        let travel = atClient ? Money.dec(selected?.travelFee) : 0
        // Сервисный сбор считается от полной суммы, включая выезд, — ровно так
        // же, как на сервере. Иначе итог на экране разойдётся с чеком.
        let fee = clientFee(price + travel)
        let total = price + travel + fee
        return ConfirmBookingSheet(
            dateLabel: fmtDateHuman(selectedDate),
            // Интервал, а не одно время: бронь на 2 часа — это 19:00–21:00.
            timeLabel: Self.slotRangeLabel(slot, slotMinutes: selected?.slotMinutes ?? 0, hours: hours, chainMinutes: chain),
            serviceName: selected?.name ?? "",
            composition: Self.bookingComposition(selected, guests: guests, hours: hours, minutes: chain),
            price: price, travel: travel, fee: fee, total: total,
            atClient: atClient,
            address: $visitAddress,
            comment: $masterComment,
            saved: savedAddresses,
            onPickSaved: { applyAddress($0) },
            confirming: confirming,
            locked: apptUnsure,
            error: confirmError,
            onConfirm: { book(slot: slot) },
            onDismiss: {
                guard !confirming else { return }
                let reload = apptUnsure
                if apptUnsure { rememberPending() }
                apptKey = nil; apptUnsure = false; confirmError = nil
                sheet = nil
                // После неизвестного исхода запись могла создаться — перечитываем окна.
                if reload { Task { await loadSlots(force: true) } }
            }
        )
    }

    // MARK: Сеть

    private func loadServices() async {
        loading = true; error = nil
        do {
            let r: ServicesResponse = try await API.shared.get("api/v1/shops/\(slug)/services")
            services = r.services ?? []
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        if services.contains(where: { $0.isAtClient }) { await loadAddresses() }
    }

    /// Адреса из профиля: подставляем адрес по умолчанию в форму выезда.
    /// Ошибку глотаем — адрес всегда можно ввести руками.
    private func loadAddresses() async {
        // Город известен всегда (выбран в приложении) — он идёт в value.
        if visitAddress.value.isEmpty { visitAddress.value = Session.shared.cityName ?? "" }
        guard Session.shared.isLoggedIn else { return }
        let list: [Address] = (try? await API.shared.list("api/v1/profile/addresses")) ?? []
        savedAddresses = list
        if visitAddress.isComplete { return }
        if let a = list.first(where: { $0.isDefaultBool }) ?? list.first { applyAddress(a) }
    }

    private func applyAddress(_ a: Address) {
        visitAddress.street    = a.street ?? ""
        visitAddress.house     = a.house ?? ""
        visitAddress.apartment = a.apartment ?? ""
        visitAddress.entrance  = a.entrance ?? ""
        visitAddress.floor     = a.floor ?? ""
        // value — ТОЛЬКО город: сервер склеивает адрес как «value, улица, д. N».
        // Если положить сюда a.display, город и улица задвоятся в «Мои записи».
        visitAddress.value     = a.city ?? Session.shared.cityName ?? ""
        visitAddress.lat       = a.lat
        visitAddress.lng       = a.lng
    }

    /// Обзор дат выбранной услуги: окна всех дат ленты, не больше
    /// bookingScanParallel запросов сразу. Новый обзор отменяет прежний, а ответ
    /// прежнего (сменили услугу) отбрасывается по номеру обзора.
    /// force — перечитать, даже если обзор в памяти свежий (возврат на экран, из фона).
    private func startDayScan(force: Bool = false) {
        scanTask?.cancel()
        scanGen &+= 1
        guard let sel = selected else { scanning = false; return }
        let gen = scanGen
        let sid = sel.id
        let dates = days.map(\.value)
        // Обзор в памяти: свежий — показываем и не спрашиваем; устаревший —
        // показываем сразу (без индикатора) и обновляем фоном.
        if let mem = DayScanCache.shared.get(slug, sid, dates.first ?? "") {
            offerScan(mem)
            if !force, Date().timeIntervalSince(mem.at) < dayScanFreshSeconds { scanning = false; return }
        }
        scanning = true
        scanTask = Task { await scanDays(serviceId: sid, dates: dates, gen: gen) }
    }

    private var confirmOpen: Bool {
        if case .confirm = sheet { return true }
        return false
    }

    /// Показать обзор сейчас или, если открыто подтверждение, после его закрытия.
    private func offerScan(_ r: DayScan) {
        if confirmOpen { scanArrived = r } else { applyScan(r) }
    }

    private func applyScan(_ r: DayScan) {
        guard r.serviceId == selected?.id else { return }
        var merged = r.slots
        var free = r.free
        let prefix = "\(r.serviceId)|"
        for (k, v) in localFresh where k.hasPrefix(prefix) && v.at > r.at {
            let d = String(k.dropFirst(prefix.count))
            if r.dates.contains(d) {
                merged[d] = v.slots
                if free != nil { free?[d] = bookingFreeCount(v.slots) }
            }
        }
        daySlots = merged
        dayEmpty = r.empty
        dayFree = free
        scanFor = r.serviceId
        // По умолчанию — первая дата с окнами; выбранную оставляем, если она есть в ленте.
        let shown = r.dates.filter { !r.empty.contains($0) }
        if let first = shown.first, !shown.contains(selectedDate) {
            selectedDate = first   // окна подставит onChange(selectedDate) — из кеша
        } else {
            Task { await loadSlots() }
        }
    }

    /// Окна даты обновлены на месте — помним, чтобы старый обзор их не вернул.
    private func noteLocal(_ serviceId: Int, _ date: String, _ list: [Slot]) {
        localFresh["\(serviceId)|\(date)"] = LocalDaySlots(at: Date(), slots: list)
        if scanFor == serviceId {
            daySlots[date] = list
            if dayFree != nil { dayFree?[date] = bookingFreeCount(list) }
        }
        DayScanCache.shared.patch(slug, serviceId, date, list)
    }

    private func stopDayScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGen &+= 1
        scanning = false
    }

    private func scanDays(serviceId: Int, dates: [String], gen: Int) async {
        let startedAt = Date()
        var fresh: [String: [Slot]] = [:]
        var empty: Set<String> = []
        var free: [String: Int]?
        // А115: даты с окнами — одним запросом. Не вышло (старый сервер, сеть,
        // 5xx) — прежний обход по дням.
        switch await bookingFreeDates(serviceId, from: dates.first ?? "", days: dates.count) {
        case .dates(let map):
            free = map
            for d in dates where map[d] == nil { empty.insert(d) }
        case .gone:
            guard !Task.isCancelled, gen == scanGen, selected?.id == serviceId else { return }
            scanning = false
            datesGone = serviceId
            return
        case .fallback:
            guard !Task.isCancelled else { return }
            await scanEachDay(serviceId: serviceId, dates: dates, fresh: &fresh, empty: &empty)
        }
        // Отменённый обзор (ушли с экрана, сменили услугу) не пишет ничего: его
        // «упавшие» даты — это отмена, а не сбой.
        guard !Task.isCancelled else { return }
        let raw = DayScan(serviceId: serviceId, dates: dates, slots: fresh, empty: empty, at: startedAt, free: free)
        // Обзор без единых данных (все запросы упали) в кеш не кладём: иначе
        // «нескрытая» лента без данных считалась бы свежей и прятала повтор.
        let noData = free == nil && fresh.isEmpty && empty.isEmpty
        let scan = noData ? raw : DayScanCache.shared.put(slug, raw)
        guard gen == scanGen, selected?.id == serviceId else { return }
        scanning = false
        datesGone = nil
        offerScan(scan)
    }

    /// Прежний обход: окна каждой даты ленты, не больше bookingScanParallel
    /// запросов сразу. Дата с упавшим запросом не попадает ни в fresh, ни в empty.
    private func scanEachDay(serviceId: Int, dates: [String],
                             fresh: inout [String: [Slot]], empty: inout Set<String>) async {
        var got: [String: [Slot]] = [:]
        var none: Set<String> = []
        await withTaskGroup(of: (String, [Slot]?).self) { group in
            var rest = dates.makeIterator()
            for _ in 0..<bookingScanParallel {
                guard let d = rest.next() else { break }
                group.addTask { (d, await bookingDaySlots(serviceId, d)) }
            }
            while let r = await group.next() {
                if let list = r.1 {
                    got[r.0] = list
                    if list.isEmpty { none.insert(r.0) }
                }
                if let d = rest.next() {
                    group.addTask { (d, await bookingDaySlots(serviceId, d)) }
                }
            }
        }
        fresh = got
        empty = none
    }

    /// Окна выбранной даты: из обзора дат, без повторного запроса. Запрос — для
    /// даты, которую обзор не смог загрузить, и после отказа/«повторить» (force).
    private func loadSlots(force: Bool = false) async {
        guard let sel = selected, !selectedDate.isEmpty else { return }
        let date = selectedDate
        // Первый обзор дат ещё идёт — весь блок под индикатором, окна придут с ним.
        guard scanFor == sel.id, datesGone != sel.id else { return }
        // Открыто подтверждение — окна под ним не трогаем: по ним считается цена.
        if confirmOpen && !force { return }
        let key = "\(sel.id)|\(date)"
        if !force, let hit = daySlots[date] {
            slots = hit; slotsError = nil; loadingSlots = false; slotsKey = key
            return
        }
        // Окна этой даты уже на экране (перечитываем после обзора дат или из
        // фона) — тихо: без индикатора, список остаётся до ответа.
        let quiet = !force && slotsKey == key && slotsError == nil
        if quiet {
            if scanning { return }
        } else {
            loadingSlots = true; slotsError = nil; slots = []; slotsKey = nil
            // Обновление дат уже идёт — эта дата придёт с ним (или её загрузит
            // показ обзора: обзор одним запросом окон дат не приносит).
            if scanning && !force { return }
        }
        // Ответ применяем, только если услуга и день не сменились, пока он шёл.
        // Раньше «Сегодня» → «Завтра» (или услуга А → Б) и опоздавший ответ
        // подменял список: в подтверждении — завтра и услуга Б, а бронировалось
        // окно сегодняшнего дня или услуги А.
        var still: Bool { selected?.id == sel.id && selectedDate == date }
        do {
            let list: [Slot] = try await API.shared.list("api/v1/services/\(sel.id)/slots", query: ["date": date])
            guard still else { return }
            // Пока шёл тихий запрос, открыли подтверждение — окна под ним не меняем.
            if quiet && confirmOpen { return }
            slots = list
            slotsKey = key
            noteLocal(sel.id, date, list)
        } catch is CancellationError {
        } catch {
            guard still else { return }
            // Тихое перечитывание не удалось — остаётся прежний список (запись
            // сервер всё равно проверит, отказ перечитает окна заново).
            if quiet { return }
            slotsError = error.localizedDescription
        }
        if still && !quiet { loadingSlots = false }
    }

    /// Окно и состав записи — то, к чему привязан ключ повтора.
    private func apptParams(_ slotId: Int) -> String {
        "\(slotId)|\((selected?.needsGuests ?? false) ? guests : 0)|\((selected?.needsHours ?? false) ? hours : 0)|\(selected?.isAtClient ?? false)"
    }

    /// Запомнить неотвеченную запись (ключ, тело) — см. apptPending.
    private func rememberPending() {
        guard let k = apptKey else { return }
        apptPending = (k.params, k.key, visitAddress, masterComment)
    }

    /// Окончательный ответ по этому окну — запомненный ключ больше не нужен.
    private func forgetPending(_ params: String) {
        if apptPending?.params == params { apptPending = nil }
    }

    private func book(slot: Slot) {
        guard !confirming else { return }   // двойной тап не создаёт вторую запись
        confirming = true
        confirmError = nil
        let wasUnsure = apptUnsure
        let params = apptParams(slot.id)
        if apptKey?.params != params {
            apptKey = (params, UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        }
        let key = apptKey?.key
        // А63: комментарий не входит в params ключа повтора — повтор после
        // обрыва с поправленным текстом не должен создать вторую запись.
        let note = String(masterComment.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        Task {
            do {
                let atClient = selected?.isAtClient ?? false
                let sel = selected
                let r: AppointmentResult = try await API.shared.post(
                    "api/v1/appointments",
                    body: AppointmentBody(
                        slotId: slot.id,
                        address: atClient ? visitAddress : nil,
                        // Отправляем только то, что клиент реально выбирал: у
                        // обычной услуги тело запроса остаётся прежним.
                        guests: (sel?.needsGuests ?? false) ? guests : nil,
                        slots: (sel?.needsHours ?? false) ? hours : nil,
                        idempotencyKey: key,
                        comment: note.isEmpty ? nil : note))
                let taken = guests
                await MainActor.run {
                    apptKey = nil
                    apptUnsure = false
                    forgetPending(params)
                    confirming = false
                    masterComment = ""
                    // Окно убираем из списка только если мест больше не осталось:
                    // в игровом зале после брони на 3 человека остаётся ещё 5.
                    if slot.capacityValue > 1, slot.freeValue - taken > 0 {
                        slots = slots.map { x in
                            guard x.id == slot.id else { return x }
                            var y = x
                            y.free = x.freeValue - taken
                            y.booked = (x.booked ?? 0) + taken
                            return y
                        }
                    } else {
                        slots.removeAll { $0.id == slot.id }
                    }
                    // Кеш дат — тоже, чтобы при возврате на эту дату не всплыло уже
                    // занятое окно. Дату из ленты не убираем — как раньше.
                    if let s = sel { noteLocal(s.id, selectedDate, slots) }
                    lastBooking = r
                    sheet = .success(r.orderId ?? 0)   // подтверждение → успех в том же .sheet
                    Haptics.success()
                }
            } catch {
                let api = error as? APIError
                let notSent: Bool = { if case .notConnected? = api { return true }; return false }()
                // Не APIError (обрыв без разбора) — как Android: исход неизвестен.
                let unknown = api?.isUnknownOutcome ?? !(error is CancellationError)
                let keepOpen: Bool = await MainActor.run {
                    confirming = false
                    let logged = Session.shared.isLoggedIn
                    if logged && (unknown || (notSent && wasUnsure)) {
                        // Исход неизвестен — сервер мог записать. Окно остаётся, форма
                        // заперта: «Подтвердить» уйдёт с тем же ключом и тем же телом,
                        // запись не задвоится. Повтор, который не ушёл (нет сети), о первой
                        // отправке ничего не говорит — блокировка остаётся.
                        apptUnsure = true
                        confirmError = error.localizedDescription
                        return true
                    }
                    // Повтор после неизвестного исхода получил 429 — исход первой отправки
                    // всё ещё неизвестен: ключ держим, форма заперта, окно можно закрыть.
                    if wasUnsure && logged && api?.rejectStatus == 429 {
                        confirmError = error.localizedDescription
                        return true
                    }
                    // Сессия умерла посреди повтора (401) — окно закрываем, но ключ и тело
                    // запоминаем: после входа то же окно уйдёт тем же ключом.
                    let authDead: Bool = { if case .unauthorized? = api { return true }; return !logged }()
                    if wasUnsure && authDead {
                        rememberPending()
                        apptKey = nil
                        apptUnsure = false
                        confirmError = nil
                        sheet = nil
                        actionMessage = error.localizedDescription
                        return false
                    }
                    if logged && notSent {
                        // Точно не ушло (нет сети) — окно остаётся, правка разрешена;
                        // следующее нажатие — с новым ключом.
                        apptKey = nil
                        confirmError = error.localizedDescription
                        return true
                    }
                    // Окончательный ответ: отказ сервера (окно занято, 422, 409 too_many —
                    // текст сервера как есть), 429 или конец сессии на первой отправке —
                    // блокировку снимаем, ключ забываем, окно закрываем.
                    forgetPending(params)
                    apptKey = nil
                    apptUnsure = false
                    confirmError = nil
                    sheet = nil
                    actionMessage = error.localizedDescription
                    return false
                }
                // Окно могли занять, пока человек подтверждал: перечитываем свободное
                // время, иначе занятое окно оставалось в списке и отказ повторялся.
                if !keepOpen { await loadSlots(force: true) }
            }
        }
    }

    // MARK: Сервисный сбор клиента (Decimal, как считает сервер)

    private func clientFee(_ price: Decimal) -> Decimal {
        guard let d = detail else { return 0 }
        // Как на сервере (api_v1.php, запись): сбор не берётся только при payer == "shop";
        // пустое поле — это клиент (раньше давало 0, а сервер сбор добавлял).
        if (d.serviceFeePayer ?? "") == "shop" { return 0 }
        if (d.serviceFeeType ?? "percent") == "fixed" {
            return Money.dec(d.serviceFeeFixed)
        }
        let pct = Money.dec(d.serviceFeePercent)
        var raw = price * pct / 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &raw, 2, .plain)
        return rounded
    }

    // MARK: Ближайшие дни

    /// Дни строились один раз при открытии экрана. Организация, оставленная
    /// открытой до утра (или в фоне), показывала «Сегодня» на вчерашнюю дату:
    /// окна грузились за прошедший день, записаться было нельзя.
    /// true — список дней сменился (наступил новый день).
    @discardableResult
    private func refreshDaysIfStale() -> Bool {
        let fresh = OrgBookingSection.nearestDays(bookingDays)
        guard fresh.first?.value != days.first?.value else { return false }
        days = fresh
        if !fresh.contains(where: { $0.value == selectedDate }) { selectedDate = fresh.first?.value ?? "" }
        return true
    }

    fileprivate static func nearestDays(_ count: Int) -> [DayOption] {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "ru_RU")
        // «Сегодня» считаем по времени ПЛОЩАДКИ, а не телефона: свободные окна
        // сервер отсекает своим `date()`, и у покупателя восточнее/западнее
        // Москвы чип «Сегодня» указывал на другой день — сегодняшние окна он не
        // видел вовсе, а на «Сегодня» приходили окна следующих суток.
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        let api = DateFormatter(); api.calendar = cal; api.timeZone = cal.timeZone
        api.locale = Locale(identifier: "en_US_POSIX"); api.dateFormat = "yyyy-MM-dd"
        let weekdays = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"] // weekday: 1 = Вс
        let today = Date()
        return (0..<count).compactMap { i in
            guard let day = cal.date(byAdding: .day, value: i, to: today) else { return nil }
            let comps = cal.dateComponents([.weekday, .day], from: day)
            let wd = (comps.weekday ?? 1) - 1
            return DayOption(
                value: api.string(from: day),
                weekday: i == 0 ? "Сегодня" : weekdays[max(0, min(6, wd))],
                dayNum: "\(comps.day ?? 0)"
            )
        }
    }

    // MARK: Отбор окон и подписи брони (1:1 с Android OrgBooking.kt)

    /// Суммарная длина `hours` окон подряд, начиная с `slot`. 0 — сервер длины
    /// не прислал: тогда считаем по длительности услуги, как раньше.
    fileprivate static func chainMinutes(_ slots: [Slot], from slot: Slot, hours: Int, buffer: Int = 0) -> Int {
        guard let i = slots.firstIndex(where: { $0.id == slot.id }) else { return 0 }
        var sum = 0
        for k in 0..<max(1, hours) {
            let idx = i + k
            guard idx < slots.count else { return fallbackMinutes(slots[i], hours: hours) }
            if slots[idx].minutesValue <= 0 { return fallbackMinutes(slots[i], hours: hours) }
            if k > 0, !adjacent(slots[idx - 1], slots[idx], buffer: buffer) {
                return fallbackMinutes(slots[i], hours: hours)
            }
            sum += slots[idx].minutesValue
        }
        return sum
    }

    /// Так же, как сервер, когда длину всей цепочки посчитать не удалось:
    /// берём длину первого окна × число окон (serviceSlotMinutes × slotsCount).
    private static func fallbackMinutes(_ first: Slot, hours: Int) -> Int {
        first.minutesValue > 0 ? first.minutesValue * max(1, hours) : 0
    }

    /// Окна соседние, если следующее начинается сразу после предыдущего или
    /// ровно через перерыв (buffer_min) — тот же допуск, что у serviceSlotChain.
    fileprivate static func adjacent(_ prev: Slot, _ cur: Slot, buffer: Int) -> Bool {
        let hhmm: (String?) -> Int = { t in
            let p = String(t ?? "").split(separator: ":").map(String.init)
            return (Int(p.first ?? "0") ?? 0) * 60 + (Int(p.count > 1 ? p[1] : "0") ?? 0)
        }
        let gap = hhmm(cur.timeStart) - hhmm(prev.timeEnd)
        return gap == 0 || (buffer > 0 && gap == buffer)
    }

    /// Длина брони для предпросмотра ДО выбора времени: по первому окну, с
    /// которого бронь можно начать. 0 — свободного времени нет или сервер длин
    /// не прислал, тогда экран считает по длительности услуги, как раньше.
    fileprivate static func previewMinutes(_ sv: ServiceItem, _ slots: [Slot], guests: Int, hours: Int) -> Int {
        let starts = bookableStarts(slots, guests: guests, hours: hours, buffer: sv.bufferMinutes)
        guard let first = starts.first else { return 0 }
        return chainMinutes(slots, from: first, hours: hours, buffer: sv.bufferMinutes)
    }

    /// «По 30 мин» — длина окна для подсказки степпера: фактическая, если она
    /// известна, иначе длительность услуги.
    fileprivate static func stepHint(_ sv: ServiceItem, _ slots: [Slot]) -> Int {
        let starts = bookableStarts(slots, guests: 1, hours: 1, buffer: sv.bufferMinutes)
        let m = starts.first?.minutesValue ?? 0
        return m > 0 ? m : sv.slotMinutes
    }

    /// Окна, с которых можно НАЧАТЬ бронь: нужно `hours` окон подряд (следующее
    /// начинается сразу после предыдущего или ровно через перерыв `buffer`) и в
    /// каждом хватает мест.
    ///
    /// Тот же отбор делает сервер под блокировкой (serviceSlotChain +
    /// serviceSlotsHaveRoom) — здесь он нужен, чтобы не предлагать занятое время.
    fileprivate static func bookableStarts(_ slots: [Slot], guests: Int, hours: Int, buffer: Int = 0) -> [Slot] {
        if hours <= 1 && guests <= 1 { return slots.filter { $0.freeValue >= 1 } }
        var out: [Slot] = []
        for i in slots.indices {
            var ok = true
            for k in 0..<hours {
                let idx = i + k
                guard idx < slots.count else { ok = false; break }
                if slots[idx].freeValue < guests { ok = false; break }
                if k > 0, !adjacent(slots[idx - 1], slots[idx], buffer: buffer) { ok = false; break }
            }
            if ok { out.append(slots[i]) }
        }
        return out
    }

    /// «19:00» или «19:00–21:00» для брони на несколько окон.
    fileprivate static func slotRangeLabel(_ slot: Slot, slotMinutes: Int, hours: Int, chainMinutes: Int = 0) -> String {
        let start = String((slot.timeStart ?? "").prefix(5))
        let span = chainMinutes > 0 ? chainMinutes : slotMinutes * hours
        guard hours > 1, span > 0, start.count >= 4 else { return start }
        let parts = start.split(separator: ":").map(String.init)
        let mins = (Int(parts.first ?? "0") ?? 0) * 60 + (Int(parts.count > 1 ? parts[1] : "0") ?? 0)
            + span
        let end = String(format: "%02d:%02d", (mins / 60) % 24, mins % 60)
        return "\(start)–\(end)"
    }

    /// «3 чел. · 1,5 ч» — состав брони. nil, если выбирать было нечего.
    /// `minutes` — фактическая длина цепочки: два окна по 30 и 60 мин — это
    /// 1,5 часа, и цена на том же экране считается именно так.
    fileprivate static func bookingComposition(_ service: ServiceItem?, guests: Int, hours: Int, minutes: Int = 0) -> String? {
        guard let sv = service else { return nil }
        var parts: [String] = []
        if sv.needsGuests { parts.append("\(guests) чел.") }
        if sv.needsHours {
            let span = minutes > 0 ? minutes : sv.slotMinutes * max(1, hours)
            parts.append(hoursLabel(span))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// «2 ч» / «1,5 ч» — часы по длине окон, запятая как в остальном интерфейсе.
    fileprivate static func hoursLabel(_ minutes: Int) -> String {
        let h = Double(max(0, minutes)) / 60
        if h == h.rounded() { return "\(Int(h)) ч" }
        // %.2f всегда пишет точку независимо от языка устройства: «1.50».
        var s = String(format: "%.2f", h)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s.replacingOccurrences(of: ".", with: ",") + " ч"
    }
}

// MARK: - Шаг «−  N  +» для количества человек и часов

private struct CountStepper: View {
    let label: String
    @Binding var value: Int
    let min: Int
    let max: Int
    let hint: String

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.text)
                Text(hint).font(.system(size: 11)).foregroundStyle(YMColor.muted)
            }
            Spacer()
            stepButton("minus", enabled: value > min) { value = Swift.max(min, value - 1) }
            Text("\(value)")
                .font(.system(size: 17, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .frame(width: 40)
            stepButton("plus", enabled: value < max) { value = Swift.min(max, value + 1) }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(enabled ? YMColor.text : YMColor.muted)
                .frame(width: 36, height: 36)
                .background(enabled ? YMColor.surface2 : YMColor.surface, in: Circle())
                .overlay(Circle().strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Строка услуги

private struct ServiceRow: View {
    /// «до 8 чел. одновременно · до 6 ч». nil — обычная услуга на одного.
    fileprivate static func capacityNote(_ s: ServiceItem) -> String? {
        var parts: [String] = []
        if s.capacityValue > 1 { parts.append("до \(s.capacityValue) чел. одновременно") }
        if s.maxSlotsValue > 1 { parts.append("до \(s.maxSlotsValue) ч") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    let service: ServiceItem
    let selected: Bool
    let fee: Decimal
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(service.name ?? "—")
                                .font(.system(size: 15.5, weight: .bold))
                                .foregroundStyle(YMColor.text)
                                .lineLimit(2)
                            if service.isAtClient {
                                Text("Выезд к вам")
                                    .font(.system(size: 10.5, weight: .heavy))
                                    .foregroundStyle(YMColor.accent)
                                    .padding(.horizontal, 7).padding(.vertical, 3)
                                    .background(YMColor.accent.opacity(0.14), in: Capsule())
                            }
                        }
                        if let d = service.description, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 12))
                                .foregroundStyle(YMColor.muted)
                                .lineLimit(2)
                        }
                        if let dm = service.durationMin, dm > 0 {
                            Text("🕑 \(dm) мин")
                                .font(.system(size: 12))
                                .foregroundStyle(YMColor.muted)
                        }
                        // Игровой зал: «до 8 чел. одновременно · до 6 ч».
                        // У обычной услуги (1 место, 1 окно) строки нет.
                        if let note = Self.capacityNote(service) {
                            Text(note)
                                .font(.system(size: 12))
                                .foregroundStyle(YMColor.muted)
                        }
                        // Кто оказывает услугу: «мастер Анна» / «мастера: Анна, Ольга».
                        if let who = service.mastersLabel {
                            Text(who)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(YMColor.accent)
                        }
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Money.format(Money.dec(service.price)))
                            .font(.system(size: 15.5, weight: .heavy))
                            .foregroundStyle(YMColor.text)
                        // «за человека в час» — подпись готовит сервер (price_unit).
                        if let unit = service.priceUnit, !unit.isEmpty, unit != "за услугу" {
                            Text(unit)
                                .font(.system(size: 11))
                                .foregroundStyle(YMColor.muted)
                        }
                        // Стоимость выезда показываем отдельной строкой: гость
                        // должен видеть её до выбора времени, а не в чеке.
                        if service.isAtClient, Money.dec(service.travelFee) > 0 {
                            Text("+ \(Money.format(Money.dec(service.travelFee))) выезд")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(YMColor.accent)
                        }
                    }
                }
                if selected && fee > 0 {
                    HStack {
                        Text("Сервисный сбор")
                            .font(.system(size: 12)).foregroundStyle(YMColor.muted)
                        Spacer()
                        Text(Money.format(fee))
                            .font(.system(size: 12)).foregroundStyle(YMColor.text)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? YMColor.surface2 : YMColor.surface,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? YMColor.accent.opacity(0.6) : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(CardPressStyle())
    }
}

// MARK: - Лента выбора даты

private struct DaySelector: View {
    let days: [DayOption]
    let selected: String
    /// А115: свободных окон по датам (free_slots); пусто — подписи нет.
    var free: [String: Int] = [:]
    var onSelect: (String) -> Void = { _ in }

    private func freeLabel(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        let word: String
        if (11...14).contains(m100) { word = "окон" }
        else if m10 == 1 { word = "окно" }
        else if (2...4).contains(m10) { word = "окна" }
        else { word = "окон" }
        return "\(n) \(word)"
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days) { d in
                    let active = d.value == selected
                    Button { onSelect(d.value) } label: {
                        VStack(spacing: 2) {
                            Text(d.weekday)
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(active ? YMColor.onAccent : YMColor.muted)
                            Text(d.dayNum)
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
                            if !free.isEmpty {
                                // Пустая строка у даты без числа — чипы одной высоты.
                                Text((free[d.value] ?? 0) > 0 ? freeLabel(free[d.value] ?? 0) : " ")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(active ? YMColor.onAccent.opacity(0.85) : YMColor.muted)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(active ? YMColor.accent : YMColor.surface,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(active ? YMColor.accent : YMColor.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Сетка слотов

private struct SlotGrid: View {
    let slots: [Slot]
    /// Показывать «N св.» — только для окон с ёмкостью больше одного места.
    var showFree: Bool = false
    var onPick: (Slot) -> Void = { _ in }

    private let columns = [GridItem(.adaptive(minimum: 78), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(slots) { slot in
                Button { Haptics.light(); onPick(slot) } label: {
                    VStack(spacing: 0) {
                        Text(String((slot.timeStart ?? "").prefix(5)))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(YMColor.text)
                        if showFree {
                            Text("\(slot.freeValue) св.")
                                .font(.system(size: 11))
                                .foregroundStyle(YMColor.muted)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(YMColor.surface, in: Capsule())
                    .overlay(Capsule().strokeBorder(YMColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Мягкая инфо-плашка

private struct BookingNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14.5))
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22).padding(.horizontal, 16)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

// MARK: - Лист подтверждения записи

private struct ConfirmBookingSheet: View {
    let dateLabel: String
    let timeLabel: String
    let serviceName: String
    /// «3 чел. · 2 ч». nil — выбирать было нечего (обычная услуга).
    var composition: String?
    let price: Decimal
    /// Выезд мастера. Только для услуги с location_type == "at_client".
    let travel: Decimal
    let fee: Decimal
    let total: Decimal
    /// Услуга выездная — просим адрес и не даём подтвердить без улицы и дома.
    let atClient: Bool
    @Binding var address: VisitAddress
    /// А63: «Комментарий мастеру» (до 300 знаков).
    @Binding var comment: String
    /// Адреса из профиля — подставить в один тап.
    var saved: [Address] = []
    var onPickSaved: (Address) -> Void = { _ in }
    let confirming: Bool
    /// Исход прошлой попытки неизвестен: правка заперта, повтор — тем же телом.
    var locked: Bool = false
    /// Ошибка связи при прошлой попытке — показываем над кнопкой.
    var error: String? = nil
    var onConfirm: () -> Void = {}
    var onDismiss: () -> Void = {}

    /// Кнопку блокируем, пока выездной адрес неполный: сервер всё равно вернёт
    /// 422 «нужен адрес», и лучше показать это до нажатия, а не после.
    private var canConfirm: Bool { !confirming && (locked || !atClient || address.isComplete) }
    private var editable: Bool { !confirming && !locked }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Подтверждение записи")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                if !serviceName.isEmpty {
                    Text(serviceName)
                        .font(.system(size: 15))
                        .foregroundStyle(YMColor.muted)
                        .padding(.top, 4)
                }

                HStack {
                    Text("Дата и время")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(YMColor.muted)
                    Spacer()
                    Text("\(dateLabel) · \(timeLabel)")
                        .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.text)
                }
                .padding(14)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 12)

                // Состав брони: гость должен видеть, за что платит, до подтверждения.
                if let comp = composition {
                    HStack {
                        Text("Бронь")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(YMColor.muted)
                        Spacer()
                        Text(comp)
                            .font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.text)
                    }
                    .padding(14)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 8)
                }

                if atClient { addressBlock.padding(.top, 12) }

                commentBlock.padding(.top, 12)

                priceRow(atClient ? "Стоимость услуги" : "Стоимость", price, bold: false).padding(.top, 12)
                if travel > 0 { priceRow("Выезд мастера", travel, bold: false) }
                if fee > 0 { priceRow("Сервисный сбор", fee, bold: false) }
                priceRow("Итого", total, bold: true).padding(.top, 4)

                if let e = error, !e.isEmpty {
                    Text(e)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YMColor.statusCancel)
                        .padding(.top, 18)
                }

                Button(action: onConfirm) {
                    Text(confirming ? "Записываем…" : (locked ? "Повторить запись" : "Подтвердить запись"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(!canConfirm)
                .opacity(canConfirm ? 1 : 0.5)
                .padding(.top, (error ?? "").isEmpty ? 18 : 8)

                if atClient && !address.isComplete {
                    Text("Укажите улицу и номер дома — мастер приедет по этому адресу")
                        .font(.system(size: 12.5))
                        .foregroundStyle(YMColor.muted)
                        .padding(.top, 8)
                }

                if locked && !confirming {
                    Text("Запись могла уйти — проверьте «Мои записи»")
                        .font(.system(size: 12.5))
                        .foregroundStyle(YMColor.muted)
                        .padding(.top, 8)
                }

                // Пока запрос идёт — закрыть нельзя; исход неизвестен — «Закрыть».
                Button(locked ? "Закрыть" : "Отмена", action: onDismiss)
                    .buttonStyle(YMSecondaryButtonStyle())
                    .disabled(confirming)
                    .padding(.top, 10)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        // С полем комментария средней высоты мало (клавиатура закрывает
        // кнопку) — можно растянуть шторку.
        .presentationDetents(atClient ? [.large] : [.medium, .large])
        // Пока запись отправляется, шторку не смахнуть: «Отмена» уже выключена,
        // а жестом окно закрывалось, человек выбирал другое время, и пришедший
        // ответ первой записи подменял новое окно экраном «Вы записаны».
        // После неизвестного исхода — тоже: закрывает только «Закрыть» (ключ забыт,
        // окна перечитаны).
        .interactiveDismissDisabled(confirming || locked)
    }

    // MARK: Куда приехать

    @ViewBuilder
    private var addressBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "location.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(YMColor.accent)
                Text("Куда приехать")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(YMColor.text)
            }

            if !saved.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(saved) { a in
                            Button {
                                Haptics.selection()
                                onPickSaved(a)
                            } label: {
                                Text(a.label?.isEmpty == false ? (a.label ?? "") : a.display)
                                    .font(.system(size: 12.5, weight: .bold))
                                    .lineLimit(1)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(YMColor.surface, in: Capsule())
                                    .foregroundStyle(YMColor.text)
                            }
                            .buttonStyle(.plain)
                            .disabled(!editable)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }

            // П-25 №6: пределы адреса выезда — как хранит сервер (лишнее он режет молча).
            addrField("Улица", text: $address.street, limit: 190)
            HStack(spacing: 8) {
                addrField("Дом", text: $address.house, limit: 30)
                addrField("Кв.", text: $address.apartment, numeric: true, limit: 30)
            }
            HStack(spacing: 8) {
                addrField("Подъезд", text: $address.entrance, numeric: true, limit: 20)
                addrField("Этаж", text: $address.floor, numeric: true, limit: 20)
            }
            // «Комментарий для мастера» переименован: рядом теперь отдельное
            // поле «Комментарий мастеру» (А63), а это — про адрес.
            addrField("Комментарий к адресу (домофон, как пройти)", text: $address.comment, limit: 500)
        }
        .padding(14)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: Комментарий мастеру (А63)

    private var commentBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Комментарий мастеру")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(YMColor.text)
            TextField("Пожелания, важные детали", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 14.5))
                .foregroundStyle(YMColor.text)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .disabled(!editable)
                .ymMaxLength($comment, 300)
            Text("Необязательно · до 300 знаков")
                .font(.system(size: 11.5))
                .foregroundStyle(YMColor.muted)
        }
        .padding(14)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func addrField(_ placeholder: String, text: Binding<String>,
                           numeric: Bool = false, limit: Int = 500) -> some View {
        TextField(placeholder, text: text)
            .ymMaxLength(text, limit)
            .keyboardType(numeric ? .numbersAndPunctuation : .default)
            .font(.system(size: 14.5))
            .foregroundStyle(YMColor.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .disabled(!editable)
    }

    private func priceRow(_ label: String, _ value: Decimal, bold: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: bold ? 17 : 13, weight: bold ? .heavy : .semibold))
                .foregroundStyle(bold ? YMColor.text : YMColor.muted)
            Spacer()
            Text(Money.format(value))
                .font(.system(size: bold ? 17 : 13, weight: bold ? .heavy : .bold))
                .foregroundStyle(YMColor.text)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Лист успеха

private struct SuccessBookingSheet: View {
    let orderId: Int
    /// Данные с сервера — печатаем как есть, ничего не пересчитываем.
    var info: AppointmentResult?
    var onClose: () -> Void = {}

    private var summary: String? {
        guard let r = info else { return nil }
        var when: [String] = []
        // Дата приходит как в базе («2026-10-12») — человеку пишем «12 октября»;
        // время «19:00:00» — без секунд. Неожиданный вид печатаем как есть.
        if let d = r.date, !d.isEmpty { when.append(DateFmt.day(d) != nil ? fmtDateHuman(String(d.prefix(10))) : d) }
        // Без цепочки compactMap/filter/map: на Xcode 26 она не укладывалась в
        // лимит проверки типов и роняла сборку 74.
        let times: [String?] = [r.time, r.timeEnd]
        var t: [String] = []
        for p in times {
            guard let s = p, !s.isEmpty else { continue }
            t.append(Self.hhmm(s))
        }
        if !t.isEmpty { when.append(t.joined(separator: "–")) }
        var what: [String] = []
        if (r.guests ?? 1) > 1 { what.append("\(r.guests ?? 1) чел.") }
        // Число окон — не часы: два окна по 30 мин печатались «2 ч» рядом с
        // «19:00–20:00». Длину берём из hours сервера; нет его — как раньше.
        if (r.slots ?? 1) > 1 {
            let h = r.hours ?? 0
            let mins = Int((h * 60).rounded())
            what.append(h > 0 ? OrgBookingSection.hoursLabel(mins) : "\(r.slots ?? 1) ч")
        }
        let all = [when.joined(separator: ", "), what.joined(separator: " · ")].filter { !$0.isEmpty }
        return all.isEmpty ? nil : all.joined(separator: " · ")
    }

    /// «19:00:00» → «19:00»; другой вид — как есть.
    private static func hhmm(_ s: String) -> String {
        let colons = s.filter { $0 == ":" }.count
        return (s.count == 8 && colons == 2) ? String(s.prefix(5)) : s
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(YMColor.statusDone)
                .padding(.bottom, 6)
            Text("Вы записаны!")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            // П-28.11: есть номер записи за день — показываем его (по нему
            // запись находят в заведении); нет — прежний номер заказа.
            if let n = info?.dailyNumber, n > 0 {
                Text("Номер записи №\(n)")
                    .font(.system(size: 15))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 4)
            } else if orderId > 0 {
                Text("Заказ №\(orderId)")
                    .font(.system(size: 15))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 4)
            }
            if let sum = summary {
                Text(sum)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(YMColor.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            Button("Готово", action: onClose)
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.top, 18)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, 28)
        .frame(maxWidth: .infinity)
        .presentationDetents([.height(280)])
    }
}

// MARK: - Хелпер даты

/// "yyyy-MM-dd" -> "3 июля".
private func fmtDateHuman(_ date: String) -> String {
    let p = date.split(separator: "-").map(String.init)
    guard p.count == 3 else { return date }
    let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                  "июля", "августа", "сентября", "октября", "ноября", "декабря"]
    let m = min(max(Int(p[1]) ?? 1, 1), 12)
    guard let day = Int(p[2]) else { return date }
    return "\(day) \(months[m - 1])"
}
