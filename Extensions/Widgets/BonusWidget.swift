import SwiftUI
import WidgetKit

//  Виджет «Бонусы»: баланс баллов (строку готовит основное приложение).

struct BonusWidget: Widget {
    let kind = "ru.marketplace.client.premium.bonuses"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { entry in
            BonusView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Бонусы")
        .description("Ваш баланс баллов Yumurta.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

struct BonusView: View {
    let snapshot: YumurtaWidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        content
            .widgetURL(YumurtaLinks.bonuses)
            .ymWidgetBackground(family == .accessoryRectangular ? Color.clear : WidgetTheme.graphite)
    }

    @ViewBuilder
    private var content: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 2) {
                Text("Бонусы Yumurta").font(.caption)
                Text(snapshot.bonusText ?? "Войдите в аккаунт").font(.headline).lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "star.circle.fill").foregroundColor(WidgetTheme.gold)
                    Text("Бонусы")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(WidgetTheme.muted)
                }
                Spacer(minLength: 0)
                Text(snapshot.bonusText ?? "—")
                    .font(.title.weight(.bold))
                    .foregroundColor(WidgetTheme.gold)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(snapshot.bonusText == nil ? "Откройте приложение" : "на вашем счёте")
                    .font(.caption2)
                    .foregroundColor(WidgetTheme.muted)
            }
            .padding(2)
        }
    }
}
