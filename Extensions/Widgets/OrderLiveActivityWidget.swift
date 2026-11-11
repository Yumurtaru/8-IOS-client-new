import ActivityKit
import SwiftUI
import WidgetKit

//  Live Activity «Статус заказа»: экран блокировки и Dynamic Island.
//  Данные приходят из основного приложения (ActivityKit) или push liveactivity.

@available(iOS 16.1, *)
struct OrderLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OrderActivityAttributes.self) { context in
            OrderLockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(WidgetTheme.graphite)
                .activitySystemActionForegroundColor(WidgetTheme.gold)
                .widgetURL(YumurtaLinks.order(context.attributes.orderId))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: ymStepIcon(context.state.step))
                        .font(.title2)
                        .foregroundColor(WidgetTheme.gold)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    OrderEtaView(state: context.state)
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(WidgetTheme.gold)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.statusText)
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        OrderStepBar(step: context.state.step)
                        Text("\(context.attributes.shopName) \(context.attributes.orderNumber)")
                            .font(.caption)
                            .foregroundColor(WidgetTheme.muted)
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                Image(systemName: ymStepIcon(context.state.step))
                    .foregroundColor(WidgetTheme.gold)
            } compactTrailing: {
                OrderCompactTrailing(state: context.state)
            } minimal: {
                Image(systemName: ymStepIcon(context.state.step))
                    .foregroundColor(WidgetTheme.gold)
            }
            .keylineTint(WidgetTheme.gold)
            .widgetURL(YumurtaLinks.order(context.attributes.orderId))
        }
    }
}

/// Экран блокировки.
@available(iOS 16.1, *)
struct OrderLockScreenView: View {
    let attributes: OrderActivityAttributes
    let state: OrderActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(attributes.shopName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(WidgetTheme.cream)
                    .lineLimit(1)
                Spacer()
                Text(attributes.orderNumber)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(WidgetTheme.gold)
            }
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: ymStepIcon(state.step))
                    .foregroundColor(WidgetTheme.gold)
                Text(state.statusText)
                    .font(.title3.weight(.bold))
                    .foregroundColor(WidgetTheme.cream)
                    .lineLimit(1)
                Spacer()
                OrderEtaView(state: state)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(WidgetTheme.gold)
            }
            OrderStepBar(step: state.step)
            if let name = state.courierName, state.step == .onWay {
                Text("Курьер: \(name)")
                    .font(.caption)
                    .foregroundColor(WidgetTheme.muted)
                    .lineLimit(1)
            }
        }
        .padding(16)
    }
}

/// Время прибытия: точное «к 18:40» (если есть) или «~25 мин».
@available(iOS 16.1, *)
struct OrderEtaView: View {
    let state: OrderActivityAttributes.ContentState

    var body: some View {
        if state.step == .done || state.step == .cancelled {
            EmptyView()
        } else if let at = state.etaAt, at > 0 {
            HStack(spacing: 3) {
                Text("к")
                Text(Date(timeIntervalSince1970: TimeInterval(at)), style: .time)
            }
        } else if let m = state.etaMinutes, m > 0 {
            Text("~\(m) мин")
        } else {
            EmptyView()
        }
    }
}

/// Правая часть компактного острова: обратный отсчёт или значок завершения.
@available(iOS 16.1, *)
struct OrderCompactTrailing: View {
    let state: OrderActivityAttributes.ContentState

    var body: some View {
        if state.step == .done {
            Image(systemName: "checkmark").foregroundColor(WidgetTheme.gold)
        } else if state.step == .cancelled {
            Image(systemName: "xmark").foregroundColor(WidgetTheme.danger)
        } else if let at = state.etaAt, at > Int(Date().timeIntervalSince1970) {
            Text(Date(timeIntervalSince1970: TimeInterval(at)), style: .timer)
                .monospacedDigit()
                .frame(maxWidth: 48)
                .foregroundColor(WidgetTheme.gold)
        } else {
            EmptyView()
        }
    }
}
