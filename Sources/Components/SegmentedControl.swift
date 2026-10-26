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
                    withAnimation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion)) {
                        selection = opt
                    }
                } label: {
                    Text(title(opt))
                        .font(YMFont.subhead)
                        .foregroundStyle(active ? YMColor.onAccent : YMColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: YMRadius.control - 3, style: .continuous)
                                    .fill(YMColor.accent)
                                    .matchedGeometryEffect(id: "ymseg", in: ns)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }
}
