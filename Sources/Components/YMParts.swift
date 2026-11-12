import SwiftUI

/*
 Общие детали редизайна (ТЗ 12.11.2026, раздел 4), этап 3. Делаются один раз и подключаются к экранам
 на следующих этапах (плитка товара, карточка товара, корзина). Только вид: что делают «+»/«−» —
 решает экран, как и раньше (те же вызовы корзины). Зеркало Android — ui/components/YMParts.kt.
*/

/// Счётчик количества «− 1 +» в серой круглой рамке. `qtyText` — уже отформатированное количество.
/// `onMinus` при количестве 1 — удаление из корзины (так ведёт себя существующая корзина; логики тут нет).
/// `height` — 34 в плитке, 48 в нижней полосе карточки товара.
struct QtyStepper: View {
    let qtyText: String
    var height: CGFloat = 34
    var plusEnabled: Bool = true
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            key("minus", label: "Убрать одну штуку", enabled: true) { Haptics.selection(); onMinus() }
            Text(qtyText)
                .ymText(YMText.cardPrice)
                .foregroundStyle(YMUi.text)
                .lineLimit(1)
                .frame(minWidth: 18)
            key("plus", label: "Добавить ещё одну", enabled: plusEnabled) { Haptics.selection(); onPlus() }
        }
        .frame(height: height)
        .background(YMUi.stepperBg, in: Capsule())
    }

    private func key(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .ymIcon(14, weight: .semibold)
                .foregroundStyle(enabled ? YMUi.text : YMUi.disabledText)
                .frame(width: height, height: height)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Вид метки-наклейки на фото товара.
enum StickerKind { case hit, new, property }

/// Метка-наклейка («Хит», «Новинка», «Без сахара»): маленькая плашка, слегка повёрнута (3°), как наклейка.
/// Цвета по ТЗ: «Хит» — красный, «Новинка» — зелёный, свойство — светло-голубой с синим текстом.
struct StickerBadge: View {
    let text: String
    let kind: StickerKind
    var tilt: Bool = true

    var body: some View {
        let colors: (Color, Color) = {
            switch kind {
            case .hit: return (YMUi.badgeHitBg, YMUi.badgeHitText)
            case .new: return (YMUi.badgeNewBg, YMUi.badgeNewText)
            case .property: return (YMUi.badgePropBg, YMUi.badgePropText)
            }
        }()
        Text(text)
            .ymText(YMText.badge)
            .foregroundStyle(colors.1)
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(colors.0, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .rotationEffect(.degrees(tilt ? -YMForm.badgeTiltDegrees : 0))
    }
}

/// Колонка меток в левом нижнем углу фото: не больше трёх, наклон чередуется — «пачка наклеек».
struct StickerStack: View {
    let items: [(String, StickerKind)]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.prefix(YMForm.maxBadges).enumerated()), id: \.offset) { i, it in
                StickerBadge(text: it.0, kind: it.1, tilt: i % 2 == 0)
            }
        }
    }
}
