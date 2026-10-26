import SwiftUI

/// Типы организаций для чипов на Главной.
///
/// `lodging` — особый чип: он не фильтрует список организаций, а ОТКРЫВАЕТ
/// раздел «Жильё» (у него свой поиск по датам и гостям, витриной организаций
/// его не покажешь). Обработка — в HomeView: чип возвращается на место, а
/// поверх таба открывается раздел. Здесь он ради одного ряда чипов.
enum OrgKind: String, CaseIterable, Identifiable {
    case all = "Все"
    case restaurants = "Рестораны"
    case shops = "Магазины"
    case services = "Услуги"
    case lodging = "Жильё"
    var id: String { rawValue }
}

/// Ряд чипов-фильтров (Все/Рестораны/Магазины/Услуги). Активный — золото.
struct ChipRow: View {
    @Binding var selected: OrgKind
    var onChange: ((OrgKind) -> Void)? = nil

    /// Раньше ряд был горизонтальным ScrollView без индикатора прокрутки, и на
    /// обычном телефоне последний чип («Жильё») целиком уезжал за правый край.
    /// Подсказки, что ряд прокручивается, не было никакой — раздел просто не
    /// существовал для человека, который не догадался свайпнуть.
    ///
    /// ViewThatFits (iOS 16+) выбирает первый вариант, который помещается:
    /// одна строка → две строки → и только в совсем узком случае (огромный
    /// системный шрифт) прежняя прокрутка, чтобы ничего не обрезалось.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: YMSpace.sm) { chips(Array(OrgKind.allCases)) }
                .padding(.horizontal, YMSpace.xl)

            VStack(alignment: .leading, spacing: YMSpace.sm) {
                HStack(spacing: YMSpace.sm) {
                    chips(Array(OrgKind.allCases.prefix(3)))
                    Spacer(minLength: 0)
                }
                HStack(spacing: YMSpace.sm) {
                    chips(Array(OrgKind.allCases.dropFirst(3)))
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, YMSpace.xl)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMSpace.sm) { chips(Array(OrgKind.allCases)) }
                    .padding(.horizontal, YMSpace.xl)
            }
        }
    }

    @ViewBuilder
    private func chips(_ kinds: [OrgKind]) -> some View {
        ForEach(kinds) { kind in
            Chip(label: kind.rawValue, active: kind == selected) {
                Haptics.selection()
                withAnimation(YMMotion.snappy) { selected = kind }
                onChange?(kind)
            }
        }
    }
}

/// Одиночный чип.
struct Chip: View {
    let label: String
    let active: Bool
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(active ? YMColor.onAccent : YMColor.text)
                .padding(.horizontal, 15).padding(.vertical, 8)
                .background(active ? YMColor.accent : YMColor.surface,
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous)
                        .strokeBorder(active ? Color.clear : YMColor.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Сегмент-контрол (control radius 14, surface2). Способы получения и т.п.
struct YMSegmentedControl: View {
    let options: [String]
    @Binding var index: Int
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let active = i == index
                Button {
                    Haptics.selection()
                    withAnimation(YMMotion.snappy) { index = i }
                } label: {
                    Text(options[i])
                        .font(YMFont.subhead)
                        .foregroundStyle(active ? YMColor.text : YMColor.muted)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if active {
                                RoundedRectangle(cornerRadius: YMRadius.control - 3, style: .continuous)
                                    .fill(YMColor.surface)
                                    .matchedGeometryEffect(id: "seg", in: ns)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }
}
