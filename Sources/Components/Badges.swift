import SwiftUI

/// Бейдж рейтинга с blur-подложкой (для фото карточек).
struct RatingBadge: View {
    let rating: Double
    var body: some View {
        HStack(spacing: 3) {
            Text("★").ymFont(11)
            Text(String(format: "%.1f", rating)).ymFont(11, weight: .bold)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(.ultraThinMaterial.opacity(0.9), in: Capsule())
        .background(Color.black.opacity(0.35), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Рейтинг " + String(format: "%.1f", rating))
    }
}

/// Кнопка-сердце ♡ на blur-подложке (избранное). Пружинная анимация при тапе.
struct HeartButton: View {
    @Binding var isFav: Bool
    var size: CGFloat = 32
    /// Цвет залитого сердечка «в избранном». По умолчанию — золото (карточки на фото),
    /// для избранного магазина/товара передаём красный (YMColor.statusCancel).
    var favColor: Color = YMColor.accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bump = false
    @State private var sparkKey = 0

    var body: some View {
        Button {
            Haptics.light()
            let becomesFav = !isFav
            isFav.toggle()
            // Поп и искры — только при включении; при снятии — без эффектов.
            if becomesFav && !reduceMotion {
                withAnimation(.spring(response: 0.16, dampingFraction: 0.55)) { bump = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.5)) { bump = false }
                }
                sparkKey += 1
            }
        } label: {
            Image(systemName: isFav ? "heart.fill" : "heart")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(isFav ? favColor : .white)
                .frame(width: size, height: size)
                .background(Color.black.opacity(0.42), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .scaleEffect(bump ? 1.35 : 1)
                .overlay(
                    Group {
                        if sparkKey > 0 {
                            YMBurst(config: .sparks(size: size, colors: [favColor, YMPalette.goldBright]))
                                .id(sparkKey)
                                .frame(width: size * 2.4, height: size * 2.4)
                        }
                    }
                    .allowsHitTesting(false)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFav ? "Убрать из избранного" : "Добавить в избранное")
    }
}

/// Инфо-бейдж на blur-подложке (время доставки и т.п.).
struct BlurInfoBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .ymFont(12, weight: .semibold)
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.black.opacity(0.55), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Статус-pill по семантике YMColor.status* («Открыто», «В пути» и т.п.).
struct StatusPill: View {
    enum Kind { case open, pending, enRoute, done, cancel }
    let text: String
    let kind: Kind
    /// solid = сплошная заливка (на фото), false = мягкая (на surface).
    var solid: Bool = true

    private var color: Color {
        switch kind {
        case .open, .done: return YMColor.statusDone
        case .pending:     return YMColor.statusPending
        case .enRoute:     return YMColor.statusEnRoute
        case .cancel:      return YMColor.statusCancel
        }
    }

    var body: some View {
        Text(text)
            .ymFont(11.5, weight: .bold)
            .foregroundStyle(solid ? .white : color)
            .padding(.horizontal, 11).padding(.vertical, 5)
            .background(solid ? color : color.opacity(0.15), in: Capsule())
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// Звёзды рейтинга (для отзывов/карточек).
struct RatingStars: View {
    let rating: Double
    var size: CGFloat = 13
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: starName(i))
                    .font(.system(size: size))
                    .foregroundStyle(YMColor.accent)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Рейтинг " + String(format: "%.1f", rating) + " из 5")
    }
    private func starName(_ i: Int) -> String {
        let v = rating - Double(i)
        if v >= 1 { return "star.fill" }
        if v >= 0.5 { return "star.leadinghalf.filled" }
        return "star"
    }
}
