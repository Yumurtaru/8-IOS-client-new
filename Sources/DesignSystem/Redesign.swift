//
//  Redesign.swift
//  Yumurta — файл оформления редизайна (ТЗ «Обновление дизайна приложения Yumurta», 12.11.2026, раздел 3).
//
//  Этап 1: значения собраны в одном месте, экраны их ещё НЕ используют — внешний вид прежний.
//  Экраны переходят на эти токены по одному (этапы 3–14); старые YMFont/YMRadius/YMSpace
//  удаляются только в конце, когда ими больше никто не пользуется.
//  Зеркало для Android — 9 Android-client-new/.../ui/theme/Redesign.kt (значения 1:1).
//
//  Шрифты вшиты (Sources/DesignSystem/Fonts, UIAppFonts в project.yml), лицензия SIL OFL 1.1.
//  Имена — PostScript-имена из файлов (проверены): GolosText-Regular/Medium/SemiBold/Bold,
//  Unbounded-SemiBold/Bold. Если шрифт не нашёлся, SwiftUI тихо берёт системный — ничего не падает.
//

import SwiftUI

// MARK: - Шрифты и шкала текста

/// Стиль текста редизайна: шрифт, базовый размер, к какому системному стилю привязан рост
/// (Dynamic Type) и нужны ли цифры одной ширины (цены).
struct YMTextStyle {
    let fontName: String
    let size: CGFloat
    let relativeTo: Font.TextStyle
    var monospacedDigits: Bool = false
}

enum YMText {
    // Акцентный шрифт — Unbounded; основной — Golos Text.
    /// Заголовок экрана: акцентный 24, жирный.
    static let screenTitle  = YMTextStyle(fontName: "Unbounded-Bold", size: 24, relativeTo: .title2)
    /// Заголовок товара в карточке: акцентный 22, жирный.
    static let productTitle = YMTextStyle(fontName: "Unbounded-Bold", size: 22, relativeTo: .title2)
    /// Заголовок раздела («Горячий кофе»): основной 18, полужирный.
    static let sectionTitle = YMTextStyle(fontName: "GolosText-SemiBold", size: 18, relativeTo: .headline)
    /// Название в плитке: основной 13, средний.
    static let cardTitle    = YMTextStyle(fontName: "GolosText-Medium", size: 13, relativeTo: .footnote)
    /// Цена в плитке: основной 15, жирный, цифры одной ширины.
    static let cardPrice    = YMTextStyle(fontName: "GolosText-Bold", size: 15, relativeTo: .subheadline, monospacedDigits: true)
    /// Описание: основной 14.
    static let description  = YMTextStyle(fontName: "GolosText-Regular", size: 14, relativeTo: .subheadline)
    /// Подписи, вес, объём: основной 12 (цвет — вторичный, задаётся на месте).
    static let caption      = YMTextStyle(fontName: "GolosText-Regular", size: 12, relativeTo: .caption)
    /// Текст на кнопке: основной 15, полужирный; суммы на кнопке — цифры одной ширины.
    static let button       = YMTextStyle(fontName: "GolosText-SemiBold", size: 15, relativeTo: .subheadline, monospacedDigits: true)
    /// Обычный текст строк (адрес, способ оплаты, пункты профиля): основной 15.
    static let body         = YMTextStyle(fontName: "GolosText-Regular", size: 15, relativeTo: .subheadline)
    /// Метки-наклейки («Хит», «Новинка»): основной 11, полужирный.
    static let badge        = YMTextStyle(fontName: "GolosText-SemiBold", size: 11, relativeTo: .caption2)
}

/// Растёт с «Размером текста» iPhone, но не больше чем в 1,35 раза — как существующий
/// YMScaledFont: кнопки, цены и плашки не ломаются, крупный текст читаем.
struct YMTextModifier: ViewModifier {
    @ScaledMetric private var scaled: CGFloat
    private let style: YMTextStyle

    init(_ style: YMTextStyle) {
        self.style = style
        _scaled = ScaledMetric(wrappedValue: style.size, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        let font = Font.custom(style.fontName, fixedSize: min(scaled, style.size * 1.35))
        return content.font(style.monospacedDigits ? font.monospacedDigit() : font)
    }
}

extension View {
    /// Текст в стиле редизайна: `.ymText(YMText.cardPrice)`.
    func ymText(_ style: YMTextStyle) -> some View { modifier(YMTextModifier(style)) }
}

// MARK: - Цвета

/// Цвета редизайна. Акцент — фирменное золото Yumurta (решение владельца 12.11.2026):
/// `YMColor.accent` / `YMColor.onAccent` (на золоте — тёмный текст). Тёмная тема сохранена.
enum YMUi {
    static var screenBg: Color        { .init(light: Color(hex: "#F2F2F4"), dark: Color(hex: "#0E0E10")) }
    static var card: Color            { .init(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#1A1A1D")) }
    /// Шапка и профиль — чёрные в обеих темах.
    static var header: Color          { Color(hex: "#000000") }
    static var onHeader: Color        { Color(hex: "#FFFFFF") }
    static var text: Color            { .init(light: Color(hex: "#111111"), dark: Color(hex: "#F6F5F1")) }
    static var textSecondary: Color   { Color(hex: "#8E8E93") }
    static var disabledBg: Color      { .init(light: Color(hex: "#E5E5EA"), dark: Color(hex: "#2C2C2E")) }
    static var disabledText: Color    { .init(light: Color(hex: "#8E8E93"), dark: Color(hex: "#6C6C70")) }
    /// Серая подложка переключателя и вкладок; выбранное — на белой плашке.
    static var segmentBg: Color       { .init(light: Color(hex: "#E9E9EE"), dark: Color(hex: "#242428")) }
    static var segmentSelected: Color { .init(light: Color(hex: "#FFFFFF"), dark: Color(hex: "#3A3A3F")) }
    /// Серая круглая рамка счётчика «− 1 +».
    static var stepperBg: Color       { .init(light: Color(hex: "#F2F2F4"), dark: Color(hex: "#242428")) }
    /// Светло-серая плитка под фото товара.
    static var photoBg: Color         { .init(light: Color(hex: "#F2F2F4"), dark: Color(hex: "#242428")) }
    static var scrim: Color           { .init(light: Color.black.opacity(0.40), dark: Color.black.opacity(0.60)) }

    static var badgeHitBg: Color      { Color(hex: "#E5484D") }
    static var badgeHitText: Color    { Color(hex: "#FFFFFF") }
    static var badgeNewBg: Color      { Color(hex: "#1E9E55") }
    static var badgeNewText: Color    { Color(hex: "#FFFFFF") }
    static var badgePropBg: Color     { .init(light: Color(hex: "#E3F1FD"), dark: Color(hex: "#1B2A3A")) }
    static var badgePropText: Color   { .init(light: Color(hex: "#1F6FD1"), dark: Color(hex: "#7DB5F5")) }
}

// MARK: - Формы и отступы

enum YMForm {
    static let cardRadius: CGFloat = 20
    static let sheetRadius: CGFloat = 38       // скругление листа сверху (36–40)
    static let buttonHeight: CGFloat = 48
    static let screenPadding: CGFloat = 16     // поля экрана слева и справа
    static let cardGap: CGFloat = 10           // между карточками (8–12)
    static let cardPadding: CGFloat = 14       // внутри карточки (12–16)
    static let closeButton: CGFloat = 36       // круглая кнопка-крестик листа
    static let sheetHandle = CGSize(width: 36, height: 5)
    static let badgeTiltDegrees: Double = 3    // метки-наклейки повёрнуты на 2–4°
    static let maxBadges = 3                   // меток на одном товаре не больше трёх
}

// MARK: - Длительности анимаций (ТЗ, раздел 6), секунды. Каждая ≤ 0,5 с и не задерживает действие.

enum YMDur {
    static let press: Double = 0.10
    static let sheet: Double = 0.32
    static let photoFade: Double = 0.30
    static let priceRoll: Double = 0.30
    static let sizeSwitch: Double = 0.20
    static let addToCart: Double = 0.40
    static let floatingCart: Double = 0.30
    static let plusToStepper: Double = 0.20
    static let tabSwitch: Double = 0.20
    static let bonusToggle: Double = 0.25
    static let requiredHint: Double = 0.20
    static let splashFade: Double = 0.45
}
