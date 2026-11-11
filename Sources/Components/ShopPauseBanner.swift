import SwiftUI

/// Плашка «пауза приёма»: заведение видно, но заказы не принимает (сервер А719).
/// title — «Заведение временно не принимает заказы до 18:30» (ShopPause.title),
/// reason — причина от продавца отдельной строкой (nil — строки нет).
/// Паритет с Android (ui/components/ShopPauseBanner.kt).
struct ShopPauseBanner: View {
    let title: String
    let reason: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .ymFont(14.5, weight: .bold)
                .foregroundStyle(YMColor.text)
            if let r = reason, !r.isEmpty {
                Text(r)
                    .ymFont(12.5)
                    .foregroundStyle(YMColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.statusCancel.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(YMColor.statusCancel.opacity(0.35), lineWidth: 1))
    }
}
