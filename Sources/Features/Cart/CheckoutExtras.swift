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
