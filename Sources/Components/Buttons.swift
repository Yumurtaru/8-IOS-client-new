import SwiftUI

// Primary кнопка — YMPrimaryButtonStyle уже в DesignSystem.swift.
// Здесь — secondary (обводка) и ghost (текст) в едином стиле токенов.

/// Вторичная кнопка (редизайн, этап 3): светло-серая, тёмный текст, круглые края, высота 48.
/// В паре стоит слева от главной.
struct YMSecondaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YMFont.golos(15, .semibold, relativeTo: .subheadline).monospacedDigit())
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .foregroundStyle(isEnabled ? YMUi.text : YMUi.disabledText)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: YMForm.buttonHeight)
            .background(isEnabled ? YMUi.segmentBg : YMUi.disabledBg, in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: YMDur.press), value: configuration.isPressed)
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
