import SwiftUI

/// Дженерик-сегмент-контрол (control radius 14, surface2; активный сегмент — золото).
/// В отличие от `YMSegmentedControl` (index-based, для строк) — работает по набору
/// произвольных Hashable-опций с кастомным заголовком. Пример: способы получения
/// (Доставка / Самовывоз / За столик), табы Активные/История и т.п.
///
/// Активный сегмент — золотая заливка (YMColor.accent), плавный перенос через
/// matchedGeometryEffect (уважает Reduce Motion).
struct YMSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    /// Заголовок для каждой опции.
    var title: (Option) -> String

    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { opt in
                let active = opt == selection
                Button {
                    Haptics.selection()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: YMDur.tabSwitch)) {
                        selection = opt
                    }
                } label: {
                    // Редизайн, этап 3 (ТЗ, раздел 4): серая подложка, выбранное — на белой плашке,
                    // плашка плавно переезжает (0,2 с). Подписи и выбор — прежние.
                    Text(title(opt))
                        .font(YMFont.styled(.subhead, active ? .semibold : .medium))
                        .foregroundStyle(YMUi.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if active {
                                Capsule()
                                    .fill(YMUi.segmentSelected)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "ymseg", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                        .accessibilityAddTraits(active ? .isSelected : [])
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(YMUi.segmentBg, in: Capsule())
    }
}
