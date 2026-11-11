import SwiftUI
import WidgetKit

//  Фирменные цвета Yumurta для расширения (значения из DesignSystem основного приложения).

enum WidgetTheme {
    static let gold      = Color(red: 0.910, green: 0.706, blue: 0.290)   // #E8B44A
    static let goldDeep  = Color(red: 0.839, green: 0.584, blue: 0.157)   // #D69528
    static let goldInk   = Color(red: 0.102, green: 0.071, blue: 0.024)   // #1A1206
    static let graphite  = Color(red: 0.102, green: 0.102, blue: 0.114)   // #1A1A1D
    static let graphite2 = Color(red: 0.141, green: 0.141, blue: 0.157)   // #242428
    static let cream     = Color(red: 0.980, green: 0.969, blue: 0.945)   // #FAF7F1
    static let muted     = Color(red: 0.690, green: 0.671, blue: 0.639)
    static let danger    = Color(red: 0.878, green: 0.329, blue: 0.294)
}

extension View {
    /// Фон виджета: iOS 17 требует containerBackground, на iOS 16 - обычный background.
    @ViewBuilder
    func ymWidgetBackground(_ color: Color) -> some View {
        if #available(iOS 17.0, *) {
            self.containerBackground(color, for: .widget)
        } else {
            self.background(color)
        }
    }
}

/// Иконка шага заказа.
func ymStepIcon(_ step: OrderStep) -> String {
    switch step {
    case .placed:    return "bag.fill"
    case .preparing: return "flame.fill"
    case .onWay:     return "bicycle"
    case .done:      return "checkmark.circle.fill"
    case .cancelled: return "xmark.circle.fill"
    }
}

/// Шкала из четырёх делений: оформлен, готовится, в пути, доставлен.
struct OrderStepBar: View {
    let step: OrderStep

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<4, id: \.self) { i in
                Capsule()
                    .fill(color(for: i))
                    .frame(height: 5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title(isPickup: false))
    }

    private func color(for i: Int) -> Color {
        if step == .cancelled { return i == 0 ? WidgetTheme.danger : WidgetTheme.graphite2 }
        return i <= step.index ? WidgetTheme.gold : WidgetTheme.graphite2
    }
}
