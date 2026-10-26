//
//  DesignSystem.swift
//  Yumurta — маркетплейс (iOS, SwiftUI)
//
//  Единый источник дизайн-токенов: цвета (светлая/тёмная тема),
//  типографика (SF Pro, Dynamic Type), сетка отступов, радиусы, тени,
//  семантические цвета статусов заказов и толерантный парсер денег (Decimal).
//
//  Все суммы — ТОЛЬКО Decimal. Никаких Double/Float для денег.
//

import SwiftUI

// MARK: - Color hex helper

extension Color {
    /// Инициализация из HEX: "#RRGGBB" или "#RRGGBBAA".
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgba: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgba)
        let hasAlpha = s.count == 8
        let r, g, b, a: Double
        if hasAlpha {
            r = Double((rgba & 0xFF00_0000) >> 24) / 255
            g = Double((rgba & 0x00FF_0000) >> 16) / 255
            b = Double((rgba & 0x0000_FF00) >> 8) / 255
            a = Double(rgba & 0x0000_00FF) / 255
        } else {
            r = Double((rgba & 0xFF0000) >> 16) / 255
            g = Double((rgba & 0x00FF00) >> 8) / 255
            b = Double(rgba & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Brand palette (raw)

enum YMPalette {
    // Фирменное золото
    static let gold        = Color(hex: "#E8B44A")   // primary action / accent (dark)
    static let goldOnLight = Color(hex: "#B58A2E")   // тот же акцент, читаемый на светлом
    static let goldBright  = Color(hex: "#F2CC5B")   // hover / highlight
    static let goldDeep    = Color(hex: "#D69528")   // pressed / gradient end
    static let goldInk     = Color(hex: "#1A1206")   // текст/иконки поверх золота

    // Графит / чёрный
    static let graphite900 = Color(hex: "#0E0E10")   // dark bg
    static let graphite800 = Color(hex: "#1A1A1D")   // dark surface
    static let graphite700 = Color(hex: "#242428")   // dark surface-2

    // Тёплый светлый
    static let cream50     = Color(hex: "#FAF7F1")   // light bg
    static let white       = Color(hex: "#FFFFFF")   // light surface
    static let cream100    = Color(hex: "#F1EDE4")   // light surface-2

    // Нейтральные тексты
    static let inkDark     = Color(hex: "#1A1710")
    static let inkLight    = Color(hex: "#F6F5F1")
    static let mutedDark   = Color(hex: "#9A99A0")   // muted on dark
    static let mutedLight  = Color(hex: "#7C776B")   // muted on light

    // Семантика статусов заказа
    static let statusPending  = Color(hex: "#6BA6F5") // Готовится (dark) / #2A6FDB (light)
    static let statusPendingL = Color(hex: "#2A6FDB")
    static let statusEnRoute  = gold                  // В пути — фирменное золото
    static let statusDone     = Color(hex: "#5FD3A0") // Доставлен (dark)
    static let statusDoneL    = Color(hex: "#1E8C5A") // Доставлен (light)
    static let statusCancel   = Color(hex: "#F07A6E") // Отменён (dark)
    static let statusCancelL  = Color(hex: "#D64B3C") // Отменён (light)
}

// MARK: - Semantic tokens (адаптивны к теме)

/// Использование: `YMColor.bg`, `YMColor.accent` и т.д. — сами подстраиваются под light/dark.
enum YMColor {
    static var bg: Color        { .init(light: YMPalette.cream50,  dark: YMPalette.graphite900) }
    static var surface: Color   { .init(light: YMPalette.white,    dark: YMPalette.graphite800) }
    static var surface2: Color  { .init(light: YMPalette.cream100, dark: YMPalette.graphite700) }
    static var text: Color      { .init(light: YMPalette.inkDark,  dark: YMPalette.inkLight) }
    static var muted: Color     { .init(light: YMPalette.mutedLight, dark: YMPalette.mutedDark) }
    static var accent: Color    { .init(light: YMPalette.goldOnLight, dark: YMPalette.gold) }
    static var onAccent: Color  { YMPalette.goldInk }
    static var hairline: Color  { .init(light: Color.black.opacity(0.07), dark: Color.white.opacity(0.08)) }

    // Статусы
    static var statusPending: Color { .init(light: YMPalette.statusPendingL, dark: YMPalette.statusPending) }
    static var statusEnRoute: Color { accent }
    static var statusDone: Color    { .init(light: YMPalette.statusDoneL,   dark: YMPalette.statusDone) }
    static var statusCancel: Color  { .init(light: YMPalette.statusCancelL, dark: YMPalette.statusCancel) }
}

extension Color {
    /// Пара значений для светлой/тёмной темы.
    init(light: Color, dark: Color) {
        #if canImport(UIKit)
        self = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        #else
        self = light
        #endif
    }
}

// MARK: - Typography (SF Pro + Dynamic Type)

enum YMFont {
    /// SF Pro Display для крупных заголовков, SF Pro Text для тела — системные шрифты iOS.
    static let largeTitle = Font.system(size: 34, weight: .heavy,    design: .default) // экраны-заголовки
    static let title      = Font.system(size: 28, weight: .bold,     design: .default)
    static let title2     = Font.system(size: 22, weight: .bold,     design: .default) // секции
    static let title3     = Font.system(size: 20, weight: .bold,     design: .default)
    static let headline   = Font.system(size: 17, weight: .semibold, design: .default) // карточки
    static let body       = Font.system(size: 15, weight: .regular,  design: .default)
    static let callout    = Font.system(size: 14, weight: .regular,  design: .default)
    static let subhead    = Font.system(size: 13, weight: .semibold, design: .default)
    static let caption    = Font.system(size: 12, weight: .regular,  design: .default)
    static let caption2   = Font.system(size: 11, weight: .semibold, design: .default) // kicker/бейджи

    /// Все стили используют .system → Dynamic Type масштабируется автоматически.
}

// MARK: - Spacing (сетка 4/8/12/16/24)

enum YMSpace {
    static let xs: CGFloat  = 4
    static let sm: CGFloat  = 8
    static let md: CGFloat  = 12
    static let lg: CGFloat  = 16
    static let xl: CGFloat  = 20   // горизонтальные поля экрана
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Corner radii

enum YMRadius {
    static let chip: CGFloat    = 11
    static let control: CGFloat = 14   // поля ввода, сегменты
    static let card: CGFloat    = 22   // Premium-карточки
    static let sheet: CGFloat   = 28   // нижние шторки / hero-sheet
    static let pill: CGFloat    = 100
}

// MARK: - Shadows / depth

enum YMShadow {
    /// Мягкая глубина карточки (Premium).
    static func card(_ dark: Bool) -> (Color, CGFloat, CGFloat, CGFloat) {
        dark ? (Color.black.opacity(0.55), 30, 0, 14)
             : (Color(hex: "#3C2D0A").opacity(0.20), 30, 0, 16)
    }
    /// Свечение золотой кнопки действия.
    static let goldGlow = (YMPalette.gold.opacity(0.5), CGFloat(30), CGFloat(0), CGFloat(8))
}

// MARK: - Motion (уважает Reduce Motion)

enum YMMotion {
    static let spring   = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let snappy   = Animation.spring(response: 0.28, dampingFraction: 0.85)
    static let pressScale: CGFloat = 0.96

    /// Возвращает анимацию с учётом системной настройки Reduce Motion.
    static func adaptive(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

// MARK: - Decimal money parsing (толерантно к строкам API)
//
// `Money` (парсинг и формат сумм) переехал в Core/MoneyFormat.swift: там
// только Foundation, поэтому тот же код прогоняется тестами на машине без
// SwiftUI. Поведение не изменилось — Money.parse / Money.dec / Money.format
// остались теми же.

// MARK: - Reusable view modifiers

/// Premium-карточка: поверхность + hairline + мягкая тень.
struct YMCard: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    var radius: CGFloat = YMRadius.card
    func body(content: Content) -> some View {
        let (col, blur, x, y) = YMShadow.card(scheme == .dark)
        content
            .background(YMColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(YMColor.hairline, lineWidth: 1)
            )
            .shadow(color: col, radius: blur, x: x, y: y)
    }
}

/// Золотая кнопка действия с лёгким scale при нажатии и haptic.
struct YMPrimaryButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(YMFont.headline)
            .foregroundStyle(YMColor.onAccent)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(YMColor.accent, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .shadow(color: YMPalette.gold.opacity(0.5), radius: 30, y: 8)
            .scaleEffect(configuration.isPressed && !reduceMotion ? YMMotion.pressScale : 1)
            .animation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    func ymCard(radius: CGFloat = YMRadius.card) -> some View { modifier(YMCard(radius: radius)) }

    /// Предел длины поля ввода (П-25 №6): лишнее отрезается сразу при вводе.
    /// Сервер длинное режет молча — человек должен видеть ровно то, что уйдёт.
    /// Через onChange, а не через Binding: так TextField гарантированно
    /// перерисовывается обрезанным текстом.
    func ymMaxLength(_ text: Binding<String>, _ limit: Int) -> some View {
        onChange(of: text.wrappedValue) { v in
            if v.count > limit { text.wrappedValue = String(v.prefix(limit)) }
        }
    }
}
