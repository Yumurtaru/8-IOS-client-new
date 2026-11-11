import SwiftUI
import WidgetKit

//  Виджет «Активный заказ»: статус последнего незавершённого заказа.
//  Нет активного - предлагает «Повторить заказ» (диплинк yumurta://order/<id>?repeat=1).

struct ActiveOrderWidget: Widget {
    let kind = "ru.marketplace.client.premium.activeOrder"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            ActiveOrderView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Активный заказ")
        .description("Статус вашего текущего заказа и быстрый повтор прошлого.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

struct ActiveOrderView: View {
    let snapshot: YumurtaWidgetSnapshot
    @Environment(\.widgetFamily) private var family

    private var step: OrderStep {
        OrderStep.parse(snapshot.step)
    }

    var body: some View {
        content
            .widgetURL(linkURL)
            .ymWidgetBackground(family == .accessoryRectangular ? Color.clear : WidgetTheme.graphite)
    }

    private var linkURL: URL {
        if let id = snapshot.orderId { return YumurtaLinks.order(id) }
        return YumurtaLinks.orders
    }

    @ViewBuilder
    private var content: some View {
        if family == .accessoryRectangular {
            accessory
        } else if snapshot.hasActiveOrder {
            active
        } else {
            idle
        }
    }

    private var accessory: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.hasActiveOrder ? "Заказ \(snapshot.orderNumber ?? "")" : "Yumurta")
                .font(.headline)
                .lineLimit(1)
            Text(snapshot.hasActiveOrder ? (snapshot.statusText ?? "") : "Нет активных заказов")
                .font(.caption)
                .lineLimit(2)
        }
    }

    private var active: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(snapshot.shopName ?? "Заказ")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(WidgetTheme.muted)
                    .lineLimit(1)
                Spacer()
                Text(snapshot.orderNumber ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(WidgetTheme.gold)
            }
            HStack(spacing: 6) {
                Image(systemName: ymStepIcon(step)).foregroundColor(WidgetTheme.gold)
                Text(snapshot.statusText ?? step.title(isPickup: false))
                    .font(.headline)
                    .foregroundColor(WidgetTheme.cream)
                    .lineLimit(2)
            }
            OrderStepBar(step: step)
            Spacer(minLength: 0)
        }
        .padding(2)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Нет активных заказов")
                .font(.headline)
                .foregroundColor(WidgetTheme.cream)
                .lineLimit(2)
            if let last = snapshot.lastOrderId {
                if let shop = snapshot.lastShopName, !shop.isEmpty {
                    Text(shop)
                        .font(.caption)
                        .foregroundColor(WidgetTheme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Link(destination: YumurtaLinks.order(last, repeatOrder: true)) {
                    Text("Повторить заказ")
                        .font(.caption.weight(.bold))
                        .foregroundColor(WidgetTheme.goldInk)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(WidgetTheme.gold)
                        .clipShape(Capsule())
                }
            } else {
                Text("Откройте Yumurta, чтобы заказать")
                    .font(.caption)
                    .foregroundColor(WidgetTheme.muted)
                Spacer(minLength: 0)
            }
        }
        .padding(2)
    }
}
