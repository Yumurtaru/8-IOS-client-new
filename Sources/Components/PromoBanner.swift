import SwiftUI

/// Промо-баннер (118pt, r22, золотое свечение в углу). Вариант Premium из макета:
/// тёмная плашка, золотой kicker, кнопка «Забрать промокод».
struct PromoBanner: View {
    var kicker: String = "Маркетплейс вашего города"
    var title: String = "Магазины, рестораны и услуги"
    var cta: String = "О Yumurta"
    var action: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            // тёмная база
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .fill(Color(hex: "#17171A"))
            // золотое свечение из правого верхнего угла
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [YMPalette.gold.opacity(0.22), .clear],
                        center: .topTrailing, startRadius: 8, endRadius: 220
                    )
                )
            // декоративный круг
            Circle()
                .fill(YMPalette.gold.opacity(0.10))
                .frame(width: 150, height: 150)
                .offset(x: 150, y: -40)

            VStack(alignment: .leading, spacing: 6) {
                Text(kicker.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(YMPalette.gold)
                Text(title)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(Color(hex: "#F5EEDE"))
                    .lineLimit(2)
                    .frame(maxWidth: 210, alignment: .leading)
                Button(action: { Haptics.light(); action() }) {
                    Text(cta)
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(YMColor.onAccent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(YMPalette.gold, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            .padding(.horizontal, 20)
        }
        .frame(height: 118)
        .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .padding(.horizontal, YMSpace.xl)
    }
}
