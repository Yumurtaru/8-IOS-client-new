import SwiftUI

/// Плавающая золотая корзина внизу экрана организации (56pt):
/// «Корзина · N блюд» слева, сумма на тёмной плашке справа. Золотое свечение,
/// лёгкий scale при нажатии. Деньги — Decimal через Money.format.
///
/// Появляется только когда в корзине есть позиции (count > 0).
struct StickyCartBar: View {
    /// Количество позиций (Cart.count).
    let count: Int
    /// Сумма корзины (Decimal — деньги только Decimal).
    let total: Decimal
    var action: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false

    // Склонение «товар / товара / товаров». Паритет с Android: «блюд» было
    // неверно у магазина, аптеки или цветочного — плашка одна на все заведения.
    private var itemsWord: String {
        let n = abs(count) % 100
        let n1 = n % 10
        if n > 10 && n < 20 { return "товаров" }
        if n1 > 1 && n1 < 5 { return "товара" }
        if n1 == 1 { return "товар" }
        return "товаров"
    }

    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            HStack(spacing: YMSpace.md) {
                Image(systemName: "bag.fill")
                    .ymIcon(16, weight: .semibold)
                    .accessibilityHidden(true)
                Text("Корзина · \(count) \(itemsWord)")
                    .ymFont(16, weight: .heavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .ymNumeric(count)
                Spacer(minLength: YMSpace.md)
                Text(Money.format(total))
                    .ymFont(15, weight: .heavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Color(hex: "#F5D98A"))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color(hex: "#1A1206"), in: Capsule())
                    .ymNumeric(total)
            }
            .foregroundStyle(YMColor.onAccent)
            .padding(.horizontal, YMSpace.lg)
            .frame(height: 56)
            .frame(maxWidth: .infinity)
            .ymFloatingSurface(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous), fill: YMColor.accent)
            .shadow(color: YMPalette.gold.opacity(0.5), radius: 30, y: 8)
            .ymBumpGloss(trigger: total, radius: YMRadius.control)
            .scaleEffect(pressed && !reduceMotion ? YMMotion.pressScale : 1)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(YMMotion.snappy) { pressed = true } } }
                .onEnded   { _ in withAnimation(YMMotion.snappy) { pressed = false } }
        )
        .padding(.horizontal, YMSpace.xl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Корзина, \(count) \(itemsWord), \(Money.format(total))")
        .accessibilityHint("Открыть корзину")
        .accessibilityAddTraits(.isButton)
    }
}
