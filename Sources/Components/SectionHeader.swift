import SwiftUI

/// Заголовок секции с опциональной ссылкой «Все» справа (золото).
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = "Все"
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            Spacer()
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
            }
        }
        .padding(.horizontal, YMSpace.xl)
    }
}
