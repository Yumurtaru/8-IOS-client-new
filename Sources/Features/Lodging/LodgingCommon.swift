import SwiftUI

/*
 ============================================================================
  Раздел «Жильё» — общие элементы интерфейса: шаг «− N +», сетка месяца,
  лист выбора дат.

  Даты и весь текст раздела живут в LodgingText.swift (там только Foundation,
  поэтому их проверяют тестами на реальных ответах сервера). Здесь —
  исключительно SwiftUI.
 ============================================================================
 */

/// Шаг «− N +»: гости, дети, номера.
struct LodgingStepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var hint: String? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(YMFont.body).foregroundColor(YMColor.text)
                if let h = hint, !h.isEmpty {
                    Text(h).font(YMFont.caption).foregroundColor(YMColor.muted)
                }
            }
            Spacer()
            stepButton("−", enabled: value > range.lowerBound) { value -= 1 }
            Text("\(value)")
                .font(YMFont.headline).foregroundColor(YMColor.text)
                .frame(width: 44)
            stepButton("+", enabled: value < range.upperBound) { value += 1 }
        }
        .padding(.vertical, 2)
    }

    private func stepButton(_ t: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: { if enabled { Haptics.selection(); action() } }) {
            Text(t)
                .font(YMFont.headline)
                .foregroundColor(enabled ? YMColor.text : YMColor.muted)
                .frame(width: 36, height: 36)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                        .stroke(YMColor.hairline, lineWidth: 1)
                )
        }
        .disabled(!enabled)
    }
}

/**
 Сетка месяца с выбором диапазона в два нажатия.

 `days` — календарь объекта (цена и остаток на дату). Может быть пустым: тогда
 это обычный выбор даты, без цен, — так он работает на экране поиска, где
 конкретный объект ещё не выбран.

 Правило выбора совпадает с серверным: первое нажатие — заезд, второе — выезд;
 день выезда не занимается, поэтому он может быть днём заезда другой брони.
 Даты с нулевым остатком и закрытые выбрать нельзя.
 */
struct LodgingMonthGrid: View {
    let monthShift: Int
    let from: String?
    let to: String?
    let days: [String: LodgingDay]
    let onPick: (String) -> Void

    /// Один календарь на все сетки: раньше он создавался заново при каждом
    /// обращении — по нескольку раз на каждую из ~120 клеток листа дат.
    private static let utcCal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2   // понедельник
        return c
    }()
    private var cal: Calendar { Self.utcCal }

    private var monthStart: Date {
        // «Сегодня» — по Москве, как и отсечка прошедших дней (LodgingDate.today).
        // По UTC с полуночи до трёх ночи 1-го числа первым показывался прошлый
        // месяц целиком серым.
        let now = LodgingDate.api.date(from: LodgingDate.today) ?? Date()
        let comps = cal.dateComponents([.year, .month], from: now)
        let first = cal.date(from: comps) ?? now
        return cal.date(byAdding: .month, value: monthShift, to: first) ?? first
    }

    private var title: String {
        Self.titleOut.string(from: monthStart).capitalized
    }
    /// Один форматтер на все месяцы: раньше каждое касание по дню пересоздавало
    /// его в каждой из четырёх сеток листа дат.
    private static let titleOut: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "LLLL yyyy"
        return f
    }()

    var body: some View {
        let daysInMonth = cal.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        // weekday: 1=Вс … 7=Сб. Нам нужна неделя с понедельника.
        let firstWeekday = cal.component(.weekday, from: monthStart)
        let lead = (firstWeekday + 5) % 7
        // Один раз на отрисовку месяца, а не дважды на каждую клетку.
        let blocked = firstBlocked
        // Начало месяца и «сегодня» — тоже один раз на месяц: раньше каждая
        // клетка заново разбирала дату и форматировала «сегодня».
        let start = monthStart
        let today = LodgingDate.today

        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text(title).font(YMFont.headline).foregroundColor(YMColor.text)
            HStack(spacing: 0) {
                ForEach(["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"], id: \.self) { d in
                    Text(d).font(YMFont.caption).foregroundColor(YMColor.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 2) {
                ForEach(0..<lead, id: \.self) { _ in Color.clear.frame(height: 52) }
                ForEach(1...daysInMonth, id: \.self) { day in
                    let iso = isoFor(day, start)
                    let info = days[iso]
                    // Без календаря объекта считаем день доступным: на экране
                    // поиска остатки ещё неизвестны, их проверит сервер.
                    let free = info?.canStay ?? true
                    let past = iso < today
                    // Выбираем выезд: день выезда ночь не занимает и может быть
                    // занят (кто-то в этот день заезжает). Раньше такой день был
                    // серым, и бронь «10–12, а 12-го заезд другого гостя» сделать
                    // было нельзя. Зато все ночи до выезда должны быть свободны.
                    let pickingCheckout = from != nil && to == nil && iso > from!
                    let checkoutOk = pickingCheckout && !(info?.noDeparture ?? false)
                        && (blocked == nil || iso <= blocked!)
                    // Свободный день за занятой ночью остаётся активным: нажатие
                    // по нему начинает новый выбор с этого дня (см. pick).
                    // День «без заезда» (cta) нельзя выбрать заездом: раньше он был
                    // активен, и расчёт после выбора дат отвечал «нельзя». Выездом
                    // такой день по-прежнему выбирается (checkoutOk).
                    let canPick = checkoutOk || (free && !(info?.noArrival ?? false))
                    let selected = iso == from || iso == to
                    let inRange = from != nil && to != nil && iso >= from! && iso <= to!
                    LodgingDayCell(
                        dayNum: day,
                        priceText: info.flatMap { LodgingText.shortPrice($0.priceValue) },
                        enabled: canPick && !past,
                        selected: selected,
                        inRange: inRange
                    ) { onPick(iso) }
                }
            }
        }
    }

    /// Первая занятая ночь после дня заезда — один раз на месяц, а не перебор
    /// дат для каждой клетки (раньше — десятки тысяч разборов дат на кадр).
    private var firstBlocked: String? {
        guard let f = from, to == nil else { return nil }
        return days.filter { $0.key >= f && !$0.value.canStay }.keys.min()
    }

    private func isoFor(_ day: Int, _ start: Date) -> String {
        var comps = cal.dateComponents([.year, .month], from: start)
        comps.day = day
        guard let d = cal.date(from: comps) else { return "" }
        return LodgingDate.api.string(from: d)
    }
}

private struct LodgingDayCell: View {
    let dayNum: Int
    let priceText: String?
    let enabled: Bool
    let selected: Bool
    let inRange: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { if enabled { Haptics.selection(); action() } }) {
            VStack(spacing: 1) {
                Text("\(dayNum)")
                    .font(YMFont.callout)
                    .foregroundColor(selected ? YMColor.onAccent : (enabled ? YMColor.text : YMColor.muted))
                if let p = priceText {
                    Text(p).font(YMFont.caption2)
                        .foregroundColor(selected ? YMColor.onAccent : YMColor.muted)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(
                RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                    .fill(selected ? YMColor.accent : (inRange ? YMColor.surface2 : Color.clear))
            )
        }
        .disabled(!enabled)
    }
}

/// Лист выбора дат. Используется и в поиске, и на карточке объекта.
struct LodgingDatesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let days: [String: LodgingDay]
    let minNights: Int
    @State private var pickFrom: String?
    @State private var pickTo: String?
    @State private var month = 0
    let onApply: (String, String) -> Void

    init(from: String?, to: String?, minNights: Int, days: [String: LodgingDay] = [:],
         onApply: @escaping (String, String) -> Void) {
        self.days = days
        self.minNights = max(1, minNights)
        self._pickFrom = State(initialValue: from)
        self._pickTo = State(initialValue: to)
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YMSpace.md) {
                    Text(hintText).font(YMFont.callout).foregroundColor(YMColor.muted)
                    ForEach(0..<4, id: \.self) { shift in
                        LodgingMonthGrid(
                            monthShift: month + shift,
                            from: pickFrom,
                            to: pickTo,
                            days: days,
                            onPick: pick
                        )
                    }
                    if minNights > 1 {
                        Text("Минимальный срок — " + LodgingDate.plural(minNights, "ночь", "ночи", "ночей"))
                            .font(YMFont.caption).foregroundColor(YMColor.muted)
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, YMSpace.xxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Даты поездки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Выбрать") {
                        if let f = pickFrom, let t = pickTo { onApply(f, t); dismiss() }
                    }
                    .disabled(!canApply)
                }
            }
        }
    }

    private var canApply: Bool {
        guard let f = pickFrom, let t = pickTo else { return false }
        return LodgingDate.nights(f, t) >= minNights
    }

    private var hintText: String {
        if let f = pickFrom, let t = pickTo {
            let n = LodgingDate.nights(f, t)
            let base = LodgingDate.human(f) + " — " + LodgingDate.human(t) + ", " +
                LodgingDate.plural(n, "ночь", "ночи", "ночей")
            // Срок короче минимального — «Выбрать» серая, а подсказка о минимуме
            // была внизу, под четырьмя месяцами: казалось, кнопка не работает.
            if n < minNights {
                return base + ". Минимум — " + LodgingDate.plural(minNights, "ночь", "ночи", "ночей")
            }
            return base
        }
        if let f = pickFrom { return "Заезд " + LodgingDate.human(f) + ". Выберите день выезда." }
        return "Выберите день заезда"
    }

    private func pick(_ iso: String) {
        if pickFrom == nil || pickTo != nil { pickFrom = iso; pickTo = nil }
        else if let f = pickFrom, iso <= f { pickFrom = iso; pickTo = nil }
        // Между заездом и этим днём есть занятая ночь — такой выезд невозможен:
        // начинаем выбор заново с этого дня.
        // Выезд в день «без выезда» (ctd) тоже нельзя.
        else if let f = pickFrom,
                (days[iso]?.noDeparture ?? false) || !lodgingNightsFree(days, f, iso) { pickFrom = iso; pickTo = nil }
        else { pickTo = iso }
    }
}

/// Все ночи с from (включительно) до to (не включая) можно занять. Без
/// календаря объекта (экран поиска) не знаем — проверит сервер.
func lodgingNightsFree(_ days: [String: LodgingDay], _ from: String, _ to: String) -> Bool {
    !days.contains { $0.key >= from && $0.key < to && !$0.value.canStay }
}
