import SwiftUI

//
//  CheckoutExtras.swift — добавки оформления заказа (П-72 п.4 + К-56 К3):
//   • «Если товара нет» → substitution_default ("similar" | "call" | "remove");
//   • «Комментарий к блюду» → items[].comment (≤ 200 символов).
//  Вынесено из CheckoutView.swift, чтобы не раздувать файл.
//

/// Что делать, если товара не окажется в наличии. Значения — как в контракте.
enum SubstitutionChoice: String, CaseIterable, Identifiable {
    case similar, call, remove
    var id: String { rawValue }

    /// «Позвонить мне» — безопасный вариант по умолчанию: ничего не заменяется и не
    /// убирается без ведома клиента.
    static let fallback: SubstitutionChoice = .call
    static let storageKey = "substitutionDefault"

    var title: String {
        switch self {
        case .similar: return "Заменить похожим"
        case .call:    return "Позвонить мне"
        case .remove:  return "Убрать из заказа"
        }
    }
    var hint: String {
        switch self {
        case .similar: return "Продавец предложит замену — вы подтвердите её в заказе"
        case .call:    return "Продавец позвонит вам и уточнит"
        case .remove:  return "Позиция просто не попадёт в заказ"
        }
    }
    /// Из сохранённой строки; мусор → значение по умолчанию.
    static func from(_ raw: String) -> SubstitutionChoice { SubstitutionChoice(rawValue: raw) ?? fallback }
}

/// Блок «Если товара нет» на оформлении. Выбор запоминается (@AppStorage).
struct SubstitutionPickerBlock: View {
    @AppStorage(SubstitutionChoice.storageKey) private var raw = SubstitutionChoice.fallback.rawValue

    var body: some View {
        let current = SubstitutionChoice.from(raw)
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            ForEach(SubstitutionChoice.allCases) { c in
                Button {
                    Haptics.light()
                    raw = c.rawValue
                } label: {
                    HStack(alignment: .top, spacing: YMSpace.md) {
                        Image(systemName: c == current ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(c == current ? YMColor.accent : YMColor.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title).font(YMFont.body).foregroundStyle(YMColor.text)
                            Text(c.hint).font(YMFont.caption).foregroundStyle(YMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(c == current ? .isSelected : [])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    /// Выбранное значение для тела заказа.
    static var current: String {
        SubstitutionChoice.from(UserDefaults.standard.string(forKey: SubstitutionChoice.storageKey) ?? "").rawValue
    }
}

/// Поле «Комментарий к блюду» под позицией оформления (свёрнуто, пока пусто).
struct DishCommentField: View {
    static let maxLength = 200
    @Binding var text: String
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            if open || !text.isEmpty {
                TextField("Комментарий к блюду", text: $text)
                    .font(YMFont.callout)
                    .padding(.horizontal, YMSpace.md).padding(.vertical, 8)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: text) { v in
                        if v.count > Self.maxLength { text = String(v.prefix(Self.maxLength)) }
                    }
            } else {
                Button("Комментарий к блюду") { open = true }
                    .font(YMFont.caption).foregroundStyle(YMColor.accent)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - П-83: чаевые курьеру и правило замены по позиции

/// Чаевые курьеру: tip в POST /orders — строка с двумя знаками («150.00»), 0…100 000.
/// Сервер при мусоре отвечает 422; здесь ввод проверяется заранее.
enum TipLogic {
    static let maxRub: Decimal = 100_000
    static let presets: [Int] = [0, 50, 100, 150]
    static let customKey = "custom"

    /// «Своя сумма»: пусто → 0; запятая или точка, до двух знаков; иначе nil (ввод неверный).
    static func parseCustom(_ text: String) -> Decimal? {
        let s = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        if s.isEmpty { return 0 }
        let parts = s.components(separatedBy: ".")
        if parts.count > 2 { return nil }
        let whole = parts[0]
        let frac = parts.count == 2 ? parts[1] : ""
        let digits = CharacterSet.decimalDigits
        func onlyDigits(_ t: String) -> Bool { t.unicodeScalars.allSatisfy { digits.contains($0) } }
        if whole.isEmpty || whole.count > 7 || !onlyDigits(whole) || frac.count > 2 || !onlyDigits(frac) { return nil }
        guard let v = Decimal(string: frac.isEmpty ? whole : whole + "." + frac) else { return nil }
        return v > maxRub ? nil : v
    }

    /// Сумма по выбору («0»/«50»/… или «custom» + текст); неверный ввод → nil.
    static func amount(choice: String, custom: String) -> Decimal? {
        if choice == customKey { return parseCustom(custom) }
        return Decimal(Int(choice) ?? 0)
    }

    /// Строка для tip: всегда два знака. Ноль → nil (поля нет — «Без чаевых»).
    static func wire(_ amount: Decimal) -> String? {
        guard amount > 0 else { return nil }
        let cents = NSDecimalNumber(decimal: amount * 100).intValue
        let frac = cents % 100
        return "\(cents / 100)." + (frac < 10 ? "0\(frac)" : "\(frac)")
    }
}

/// Правило замены по позиции: поле items[].substitution есть только при явном выборе.
enum ItemSubstitution {
    static let values = ["similar", "call", "remove"]
    static func title(_ v: String?) -> String {
        switch v {
        case "similar": return "Похожий"
        case "call":    return "Позвонить"
        case "remove":  return "Убрать"
        default:        return "Как в общем правиле"
        }
    }
    /// Что слать: только similar | call | remove; всё прочее — nil (поля нет).
    static func wire(_ v: String?) -> String? {
        guard let v = v, values.contains(v) else { return nil }
        return v
    }
}

/// Блок «Чаевые курьеру»: «Без чаевых» / 50 / 100 / 150 / «Своя сумма».
struct TipPickerBlock: View {
    @Binding var choice: String
    @Binding var custom: String
    let invalid: Bool

    private func label(_ p: Int) -> String { p == 0 ? "Без чаевых" : "\(p) ₽" }

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: YMSpace.sm) {
                ForEach(TipLogic.presets, id: \.self) { p in chip(String(p), label(p)) }
                chip(TipLogic.customKey, "Своя сумма")
            }
            if choice == TipLogic.customKey {
                TextField("Сумма, ₽ (до 100 000)", text: $custom)
                    .keyboardType(.decimalPad)
                    .font(YMFont.body)
                    .padding(.horizontal, YMSpace.md).padding(.vertical, 10)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .onChange(of: custom) { v in
                        let f = String(v.filter { $0.isNumber || $0 == "." || $0 == "," }.prefix(10))
                        if f != v { custom = f }
                    }
                if invalid {
                    Text("Введите сумму от 0 до 100 000 ₽ (не больше двух знаков после запятой)")
                        .font(YMFont.caption).foregroundStyle(Color.red)
                }
            }
            Text("Чаевые получит курьер, который привезёт заказ")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func chip(_ key: String, _ title: String) -> some View {
        let on = choice == key
        return Button {
            Haptics.light()
            choice = key
        } label: {
            Text(title).font(YMFont.callout)
                .foregroundStyle(on ? Color.white : YMColor.text)
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(on ? YMColor.accent : Color.clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? YMColor.accent : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Маленький выбор под позицией: «как в общем правиле / похожий / позвонить / убрать».
struct ItemSubstitutionMenu: View {
    @Binding var value: String?

    var body: some View {
        HStack(spacing: YMSpace.xs) {
            Text("Если нет в наличии:").font(YMFont.caption).foregroundStyle(YMColor.muted)
            Menu {
                Button("Как в общем правиле") { value = nil }
                ForEach(ItemSubstitution.values, id: \.self) { v in
                    Button(ItemSubstitution.title(v)) { value = v }
                }
            } label: {
                Text(ItemSubstitution.title(value)).font(YMFont.caption).foregroundStyle(YMColor.accent)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
