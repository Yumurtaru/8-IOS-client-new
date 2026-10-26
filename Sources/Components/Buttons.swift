import SwiftUI

// Primary кнопка — YMPrimaryButtonStyle уже в DesignSystem.swift.
// Здесь — secondary (обводка) и ghost (текст) в едином стиле токенов.

/// Вторичная кнопка: поверхность surface2 + hairline, текст акцентом.
struct YMSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YMFont.headline)
            .foregroundStyle(YMColor.accent)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.35), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? YMMotion.pressScale : 1)
            .animation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

/// Ghost-кнопка: только текст (например «У меня есть аккаунт»).
struct YMGhostButtonStyle: ButtonStyle {
    var color: Color = YMColor.muted
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YMFont.headline)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 50)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
