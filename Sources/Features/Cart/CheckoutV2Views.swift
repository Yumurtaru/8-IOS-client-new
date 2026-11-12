import SwiftUI

//
//  CheckoutV2Views.swift — новый вид оформления заказа (редизайн, этап 10; ТЗ 5.9).
//
//  Здесь ТОЛЬКО разметка: блоки получают данные, биндинги и замыкания от CheckoutView.
//  Расчёты суммы/бонусов/промокода, оплата, создание заказа, идемпотентность, общий заказ,
//  замены, комментарии к блюдам — остаются в CheckoutView.swift и работают одинаково в обоих видах.
//  Включается переключателем YMFlags.newOrderLookKey (по умолчанию включён).
//

// MARK: - Белая карточка

struct CheckoutV2Card<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YMForm.cardGap) {
            if let t = title {
                Text(t).ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMForm.cardPadding)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }
}

/// Рамка поля ввода: в новом виде — светло-серая подложка внутри белой карточки,
/// в прежнем — ровно прежняя рамка (поверхность + тонкая линия, у комментария — пунктир).
struct CheckoutFieldBox: ViewModifier {
    let v2: Bool
    var dashedOld: Bool = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if v2 {
            content
                .padding(12)
                .background(YMUi.segmentBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        } else if dashedOld {
            content
                .padding(14)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                        .foregroundStyle(YMColor.hairline)
                )
        } else {
            content
                .padding(14)
                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        }
    }
}

// MARK: - «Откуда» / «Заберу здесь»

struct CheckoutV2PlaceRow: View {
    let kicker: String
    let name: String
    let lines: [String]
    let icon: String

    var body: some View {
        HStack(alignment: .top, spacing: YMSpace.md) {
            Image(systemName: icon)
                .ymIcon(16, weight: .semibold)
                .foregroundStyle(YMColor.accent)
                .frame(width: 36, height: 36)
                .background(YMUi.segmentBg, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                Text(name).ymText(YMText.body).fontWeight(.semibold).foregroundStyle(YMUi.text)
                ForEach(lines, id: \.self) { l in
                    Text(l).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - «Когда»

private func checkoutV2MinutesWord(_ n: Int) -> String {
    (n % 10 == 1 && n % 100 != 11) ? "минуты" : "минут"
}

struct CheckoutV2WhenCard: View {
    let title: String
    /// Заведение закрыто: доступен только «Ко времени» (предзаказ).
    let closed: Bool
    let statusText: String?
    /// Верхняя граница времени доставки, минут (nil — не показываем «около N минут»).
    let etaMax: Int?
    let days: [PreorderDay]
    /// Выбранное время ещё есть в графике.
    let selectionValid: Bool
    @Binding var byTime: Bool
    @Binding var preorderAt: String?

    @State private var showWheel = false

    private var fastLabel: String {
        if let n = etaMax, n > 0 { return "Побыстрее, около \(n) \(checkoutV2MinutesWord(n))" }
        return "Побыстрее"
    }

    /// «Сегодня · 17:30» — выбранное время на варианте «Ко времени».
    private var timeLabel: String {
        guard selectionValid, let p = preorderAt, p.count >= 16 else { return "Ко времени" }
        let date = String(p.prefix(10))
        let time = String(p.dropFirst(11).prefix(5))
        let day = days.first(where: { $0.date == date })?.label ?? date
        return day + " · " + time
    }

    private func pill(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Text(text)
                .ymText(YMText.body)
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? YMColor.onAccent : YMUi.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 8)
                .background(selected ? YMUi.accentFill : YMUi.segmentBg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var body: some View {
        CheckoutV2Card(title: title) {
            if closed {
                let st = (statusText ?? "").trimmingCharacters(in: .whitespaces)
                Text((st.isEmpty ? "Заведение сейчас закрыто" : st) + ". Предзаказ — выберите день и время в часы работы.")
                    .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if days.isEmpty && (closed || byTime) {
                Text("В ближайшие 7 дней свободного времени нет — заведение не работает.")
                    .ymText(YMText.caption).foregroundStyle(YMColor.statusCancel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: YMSpace.sm) {
                if !closed {
                    pill(fastLabel, selected: !byTime) { byTime = false }
                }
                pill(timeLabel, selected: closed || byTime) {
                    if !days.isEmpty { showWheel = true }
                }
            }
            if (closed || byTime) && selectionValid == false && !days.isEmpty {
                Text("Выберите время, чтобы оформить заказ.")
                    .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            }
        }
        .sheet(isPresented: $showWheel) {
            CheckoutV2TimeWheel(days: days, initial: selectionValid ? preorderAt : nil) { value in
                preorderAt = value
                byTime = true
            }
            .presentationDetents([.height(360)])
        }
    }
}

/// Лист с колёсами: день и время — те же допустимые значения (PreorderSlots), что и раньше.
struct CheckoutV2TimeWheel: View {
    let days: [PreorderDay]
    let onChoose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var date: String
    @State private var time: String

    init(days: [PreorderDay], initial: String?, onChoose: @escaping (String) -> Void) {
        self.days = days
        self.onChoose = onChoose
        let initDate: String = initial.map { String($0.prefix(10)) } ?? ""
        let initTime: String = initial.map { String($0.dropFirst(11).prefix(5)) } ?? ""
        let day: PreorderDay? = days.first(where: { $0.date == initDate }) ?? days.first
        _date = State(initialValue: day?.date ?? "")
        let t: String = (day?.slots.contains(initTime) == true) ? initTime : (day?.slots.first ?? "")
        _time = State(initialValue: t)
    }

    private var slots: [String] { days.first(where: { $0.date == date })?.slots ?? [] }

    var body: some View {
        VStack(spacing: YMSpace.md) {
            Text("Ко времени").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                .padding(.top, YMSpace.lg)
            HStack(spacing: 0) {
                Picker("День", selection: $date) {
                    ForEach(days) { d in Text(d.label).tag(d.date) }
                }
                .pickerStyle(.wheel)
                Picker("Время", selection: $time) {
                    ForEach(slots, id: \.self) { t in Text(t).tag(t) }
                }
                .pickerStyle(.wheel)
            }
            .frame(height: 170)
            .onChange(of: date) { _ in
                if !slots.contains(time) { time = slots.first ?? "" }
            }
            Button {
                Haptics.light()
                onChoose(PreorderSlots.value(date, time))
                dismiss()
            } label: {
                Text("Выбрать")
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(time.isEmpty)
            .padding(.bottom, YMSpace.lg)
        }
        .padding(.horizontal, YMForm.screenPadding)
    }
}

// MARK: - «Оплата»

struct CheckoutV2PaymentCard<Option: Hashable, Extra: View>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    let extra: Extra

    @State private var showPicker = false

    init(options: [Option], selection: Binding<Option>, title: @escaping (Option) -> String,
         @ViewBuilder extra: () -> Extra) {
        self.options = options
        self._selection = selection
        self.title = title
        self.extra = extra()
    }

    var body: some View {
        CheckoutV2Card {
            Button {
                Haptics.light()
                showPicker = true
            } label: {
                HStack(spacing: YMSpace.md) {
                    Text("Оплата").ymText(YMText.body).fontWeight(.semibold).foregroundStyle(YMUi.text)
                    Spacer(minLength: 8)
                    Text(title(selection)).ymText(YMText.body).foregroundStyle(YMUi.textSecondary)
                    Image(systemName: "chevron.right").ymIcon(13, weight: .semibold).foregroundStyle(YMUi.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            extra
        }
        .sheet(isPresented: $showPicker) {
            VStack(spacing: 0) {
                Text("Способ оплаты").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                    .padding(.vertical, YMSpace.lg)
                ForEach(options, id: \.self) { o in
                    Button {
                        Haptics.selection()
                        selection = o
                        showPicker = false
                    } label: {
                        HStack {
                            Text(title(o)).ymText(YMText.body).foregroundStyle(YMUi.text)
                            Spacer()
                            if o == selection {
                                Image(systemName: "checkmark").ymIcon(15, weight: .semibold).foregroundStyle(YMColor.accent)
                            }
                        }
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(o == selection ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, YMForm.screenPadding)
            .presentationDetents([.height(CGFloat(110 + options.count * 52))])
        }
    }
}

// MARK: - «Бонусы»

struct CheckoutV2BonusCard: View {
    @Binding var spend: Bool
    /// «Можете использовать N ₽» — уже отформатировано через Money.format.
    let availableText: String
    /// Строка списания (nil — не раскрыта).
    let spentText: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CheckoutV2Card {
            Toggle(isOn: $spend) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Бонусы").ymText(YMText.body).fontWeight(.semibold).foregroundStyle(YMUi.text)
                    Text("Можете использовать \(availableText)")
                        .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                }
            }
            .tint(YMColor.accent)
            if let s = spentText {
                HStack {
                    Text("Списываем").ymText(YMText.body).foregroundStyle(YMColor.accent)
                    Spacer()
                    Text("−" + s).ymText(YMText.body).fontWeight(.semibold).foregroundStyle(YMColor.accent)
                        .ymNumeric(s)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: YMDur.bonusToggle), value: spentText != nil)
    }
}

// MARK: - «Сумма заказа»

struct CheckoutV2Row: Identifiable {
    let label: String
    let value: String
    var accent: Bool = false
    var id: String { label }
}

struct CheckoutV2SumCard<Extra: View, Promo: View>: View {
    let before: [CheckoutV2Row]
    let extra: Extra
    let after: [CheckoutV2Row]
    let total: Decimal
    let promo: Promo

    init(before: [CheckoutV2Row], after: [CheckoutV2Row], total: Decimal,
         @ViewBuilder extra: () -> Extra, @ViewBuilder promo: () -> Promo) {
        self.before = before
        self.after = after
        self.total = total
        self.extra = extra()
        self.promo = promo()
    }

    private func row(_ r: CheckoutV2Row) -> some View {
        HStack {
            Text(r.label).ymText(YMText.body).foregroundStyle(r.accent ? YMColor.accent : YMUi.textSecondary)
            Spacer()
            Text(r.value).ymText(YMText.body).fontWeight(.semibold)
                .foregroundStyle(r.accent ? YMColor.accent : YMUi.text)
                .ymNumeric(r.value)
        }
    }

    var body: some View {
        CheckoutV2Card(title: "Сумма заказа") {
            VStack(spacing: 9) {
                ForEach(before) { row($0) }
                extra
                ForEach(after) { row($0) }
            }
            Divider()
            HStack {
                Text("Итого").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                Spacer()
                Text(Money.format(total)).ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                    .ymNumeric(total)
            }
            promo
        }
    }
}
