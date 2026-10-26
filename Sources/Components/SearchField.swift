import SwiftUI

/// Поиск-плашка (46pt, surface, r14). На Главной — некликабельная «витрина»,
/// tap ведёт на экран поиска. На экране поиска — активное поле ввода.
struct SearchField: View {
    var placeholder: String = "Рестораны, товары, услуги…"
    var text: Binding<String>? = nil   // nil = витрина (не редактируется)
    var active: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(YMColor.muted)
            if let text {
                TextField(placeholder, text: text)
                    .font(YMFont.body)
                    .foregroundStyle(YMColor.text)
                    .autocorrectionDisabled()
            } else {
                Text(placeholder).font(YMFont.body).foregroundStyle(YMColor.muted)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 46)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(active ? YMColor.accent : YMColor.hairline, lineWidth: active ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}
