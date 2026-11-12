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

    // Редизайн, этап 2 (ТЗ 12.11.2026, раздел 3): нейтральный светлый вместо тёплого крема.
    static let screenGray  = Color(hex: "#F2F2F4")   // фон экрана
    static let segmentGray = Color(hex: "#E9E9EE")   // вторичная поверхность: подложки, поля, чипы
    static let ink111      = Color(hex: "#111111")   // основной текст
    static let gray8E      = Color(hex: "#8E8E93")   // вторичный текст (обе темы)

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
    static var bg: Color        { .init(light: YMPalette.screenGray,  dark: YMPalette.graphite900) }
    static var surface: Color   { .init(light: YMPalette.white,       dark: YMPalette.graphite800) }
    static var surface2: Color  { .init(light: YMPalette.segmentGray, dark: YMPalette.graphite700) }
    static var text: Color      { .init(light: YMPalette.ink111,      dark: YMPalette.inkLight) }
    static var muted: Color     { YMPalette.gray8E }
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
    // Редизайн, этап 2 (ТЗ 12.11.2026): Golos Text — основной, Unbounded — акцентный (только largeTitle:
    // заголовки экранов и крупные суммы; на title Unbounded слишком широк — придёт с размерами ТЗ на этапах 5–6). Размеры прежние (34/28/22/20/17/15/13/12/11), рост с
    // «Размером текста» iPhone — как раньше (relativeTo:).
    // Начертание задаётся ЯВНО по имени: модификаторы .weight()/.fontWeight()/.bold() со вшитыми
    // статичными шрифтами срабатывают ненадёжно. Нужен другой вес — `YMFont.styled(.body, .semibold)`.
    static let largeTitle = display(34, .heavy,  relativeTo: .largeTitle)   // экраны-заголовки
    static let title      = golos(28, .bold,     relativeTo: .title)
    static let title2     = golos(22, .bold,     relativeTo: .title2)       // секции
    static let title3     = golos(20, .bold,     relativeTo: .title3)
    static let headline   = golos(17, .semibold, relativeTo: .headline)     // карточки
    static let body       = golos(15, .regular,  relativeTo: .subheadline)  // 15
    static let callout    = golos(15, .regular,  relativeTo: .subheadline)  // было 14
    static let subhead    = golos(13, .semibold, relativeTo: .footnote)     // 13
    static let caption    = golos(12, .regular,  relativeTo: .caption)      // 12
    static let caption2   = golos(11, .semibold, relativeTo: .caption2)     // kicker/бейджи

    /// Стиль из шкалы для `styled(_:_:)`.
    enum Role { case largeTitle, title, title2, title3, headline, body, callout, subhead, caption, caption2 }

    /// Тот же стиль другим весом — вместо `YMFont.body.weight(.semibold)`: `YMFont.styled(.body, .semibold)`.
    static func styled(_ role: Role, _ w: Font.Weight) -> Font {
        switch role {
        case .largeTitle: return display(34, w, relativeTo: .largeTitle)
        case .title:      return golos(28, w, relativeTo: .title)
        case .title2:     return golos(22, w, relativeTo: .title2)
        case .title3:     return golos(20, w, relativeTo: .title3)
        case .headline:   return golos(17, w, relativeTo: .headline)
        case .body:       return golos(15, w, relativeTo: .subheadline)
        case .callout:    return golos(15, w, relativeTo: .subheadline)
        case .subhead:    return golos(13, w, relativeTo: .footnote)
        case .caption:    return golos(12, w, relativeTo: .caption)
        case .caption2:   return golos(11, w, relativeTo: .caption2)
        }
    }

    /// PostScript-имя начертания Golos Text для веса (есть 400/500/600/700; тоньше — 400, жирнее — 700).
    static func golosName(_ w: Font.Weight) -> String {
        switch w {
        case .medium: return "GolosText-Medium"
        case .semibold: return "GolosText-SemiBold"
        case .bold, .heavy, .black: return "GolosText-Bold"
        default: return "GolosText-Regular"
        }
    }

    /// PostScript-имя начертания Unbounded для веса (есть 600 и 700).
    static func displayName(_ w: Font.Weight) -> String {
        switch w {
        case .bold, .heavy, .black: return "Unbounded-Bold"
        default: return "Unbounded-SemiBold"
        }
    }

    /// Основной шрифт заданного размера и веса, растёт с Dynamic Type относительно `relativeTo`.
    static func golos(_ size: CGFloat, _ w: Font.Weight = .regular, relativeTo style: Font.TextStyle = .body) -> Font {
        .custom(golosName(w), size: size, relativeTo: style)
    }

    /// Акцентный шрифт (крупные заголовки экранов, суммы).
    static func display(_ size: CGFloat, _ w: Font.Weight = .bold, relativeTo style: Font.TextStyle = .title) -> Font {
        .custom(displayName(w), size: size, relativeTo: style)
    }

    /// Для произвольного размера есть `.ymFont(size, weight:, design:)` — тоже масштабируется.
}

/// Шрифт заданного размера, который растёт вместе с Dynamic Type, но не больше
/// чем в 1,35 раза: фиксированные плашки, бейджи и кнопки не ломаются, а крупный
/// текст при этом читаем. Для цен и кнопок дополнительно ставят lineLimit/minimumScaleFactor.
struct YMScaledSymbolFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let base: CGFloat
    private let weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: .body)
        base = size
        self.weight = weight
    }

    func body(content: Content) -> some View {
        content.font(.system(size: min(scaled, base * 1.35), weight: weight, design: .default))
    }
}

struct YMScaledFont: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let base: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: .body)
        base = size
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        let size = min(scaled, base * 1.35)
        // Редизайн, этап 2: обычный дизайн — Golos Text нужным начертанием; .rounded/.monospaced/.serif
        // оставлены системными (осознанные исключения: коды, цифры таймеров и т. п.).
        if design == .default {
            content.font(.custom(YMFont.golosName(weight), fixedSize: size))
        } else {
            content.font(.system(size: size, weight: weight, design: design))
        }
    }
}

/// Фон плавающей панели поверх контента. iOS 26+ (сборка Xcode 26) — «жидкое стекло»
/// с тонировкой; iOS 16–18 и старые SDK — прежняя сплошная заливка.
struct YMFloatingSurface<S: Shape>: ViewModifier {
    let shape: S
    let fill: Color

    func body(content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.tint(fill).interactive(), in: shape)   // под #available(iOS 26.0, *) выше
        } else {
            content.background(fill, in: shape)
        }
        #else
        content.background(fill, in: shape)
        #endif
    }
}

extension View {
    /// Контент экрана не шире 700 pt и по центру: на телефоне ничего не меняется,
    /// на широком экране (iPad, альбомный режим) нет растянутого телефонного вида.
    func ymReadableWidth() -> some View {
        frame(maxWidth: 700).frame(maxWidth: .infinity)
    }

    func ymFloatingSurface<S: Shape>(_ shape: S, fill: Color) -> some View {
        modifier(YMFloatingSurface(shape: shape, fill: fill))
    }

    func ymFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> some View {
        modifier(YMScaledFont(size: size, weight: weight, design: design))
    }

    /// Для SF Symbols: масштабирование как у `ymFont`, но шрифт системный (значки не переводим на Golos).
    func ymIcon(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(YMScaledSymbolFont(size: size, weight: weight))
    }
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
            .lineLimit(2)
            .minimumScaleFactor(0.8)
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
