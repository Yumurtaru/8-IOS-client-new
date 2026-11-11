import SwiftUI

/// Плашка «Нет связи — данные на 14:32», когда экран показан из офлайн-кэша.
/// Подключается к экрану через `.staleDataBanner()`.
struct StaleDataBanner: View {
    @ObservedObject private var cache = OfflineCache.shared
    @EnvironmentObject private var net: NetworkMonitor

    var body: some View {
        if let at = cache.staleAt, !net.online {
            HStack(spacing: 6) {
                Image(systemName: "icloud.slash").accessibilityHidden(true)
                Text("Нет связи — данные на \(OfflineCache.timeText(at))")
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .font(YMFont.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(Color.black.opacity(0.75))
            .accessibilityElement(children: .combine)
        }
    }
}

extension View {
    func staleDataBanner() -> some View {
        VStack(spacing: 0) {
            StaleDataBanner()
            self
        }
    }
}
