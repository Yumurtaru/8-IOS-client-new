import SwiftUI

/// Плавающая корзина (ТЗ 5.7): золотая капсула по центру внизу, не на всю ширину.
/// Слева — до трёх круглых миниатюр последних добавленных товаров стопкой (30 pt, белая
/// обводка 2, перекрытие −10), справа — «Корзина · N» и сумма. Деньги — Decimal.
///
/// Появляется только когда в корзине есть позиции (решает вызывающий: count > 0).
/// Появление/исчезновение (снизу, 0,3 с) задаёт вызывающий через `.transition`.
struct StickyCartBar: View {
    /// Количество позиций (Cart.count).
    let count: Int
    /// Сумма корзины (Decimal — деньги только Decimal).
    let total: Decimal
    /// Позиции корзины (для миниатюр; берутся последние три). Пусто — миниатюр нет.
    var lines: [CartLine] = []
    var action: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pressed = false
    @State private var myCenter: CGPoint?

    private let thumb: CGFloat = 30
    private let overlap: CGFloat = 10

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

    private var recent: [CartLine] { Array(lines.suffix(3)) }

    var body: some View {
        Button {
            Haptics.medium()
            action()
        } label: {
            HStack(spacing: 10) {
                if recent.isEmpty {
                    Image(systemName: "bag.fill")
                        .ymIcon(18, weight: .semibold)
                        .accessibilityHidden(true)
                } else {
                    thumbs
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Корзина · \(count)")
                        .ymFont(11, weight: .semibold)
                        .lineLimit(1)
                        .opacity(0.7)
                        .ymNumeric(count)
                    Text(Money.format(total))
                        .ymText(YMText.button)
                        .lineLimit(1)
                        .ymNumeric(total)
                }
            }
            .foregroundStyle(YMColor.onAccent)
            .padding(.leading, 10)
            .padding(.trailing, 18)
            .frame(height: 52)
            .background(YMUi.accentFill, in: Capsule())
            .shadow(color: Color.black.opacity(0.18), radius: 14, y: 5)
            .ymBumpGloss(trigger: total, radius: 26)
            .scaleEffect(pressed && !reduceMotion ? YMMotion.pressScale : 1)
            .background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { let c = Self.center(g); myCenter = c; YMFlightHost.cartPillCenter = c }
                        .onChange(of: g.size) { _ in let c = Self.center(g); myCenter = c; YMFlightHost.cartPillCenter = c }
                }
            )
            .onDisappear {
                // Сбрасываем только свой центр: центр новой пилюли не трогаем.
                if YMFlightHost.cartPillCenter == myCenter { YMFlightHost.cartPillCenter = nil }
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { withAnimation(.easeOut(duration: YMDur.press)) { pressed = true } } }
                .onEnded   { _ in withAnimation(.easeOut(duration: YMDur.press)) { pressed = false } }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Корзина: \(count) \(itemsWord) на сумму \(Money.format(total))")
        .accessibilityHint("Открыть корзину")
        .accessibilityAddTraits(.isButton)
    }

    private static func center(_ g: GeometryProxy) -> CGPoint {
        let f = g.frame(in: .global)
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// Стопка миниатюр: новая — справа и сверху; появляется масштабом (при Reduce Motion — без анимации).
    private var thumbs: some View {
        let items = recent
        let width = thumb + CGFloat(max(0, items.count - 1)) * (thumb - overlap)
        return ZStack(alignment: .leading) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, line in
                PhotoPlaceholder(url: API.imageURL(line.photo), label: "",
                                 radius: thumb / 2, tone: line.productId, fit: true)
                    .frame(width: thumb, height: thumb)
                    .background(YMUi.photoBg)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .offset(x: CGFloat(i) * (thumb - overlap))
                    .zIndex(Double(i))
                    .transition(reduceMotion ? .identity : .scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: width, height: thumb, alignment: .leading)
        .animation(reduceMotion ? nil : .easeOut(duration: YMDur.plusToStepper), value: items.map { $0.id })
        .accessibilityHidden(true)
    }
}
