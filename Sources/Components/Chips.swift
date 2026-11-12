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
    /// Чип-действие в конце ряда («Отправить посылку»): не фильтр, никогда не
    /// становится активным — только вызывает action. nil — чипа нет.
    var extra: (label: String, action: () -> Void)? = nil
    var onChange: ((OrgKind) -> Void)? = nil
    /// Белая плашка активного чипа переезжает между чипами (этап 12).
    @Namespace private var plateNS

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
            HStack(spacing: YMSpace.sm) { chips(Array(OrgKind.allCases)); extraChip }
                .padding(.horizontal, YMSpace.xl)

            VStack(alignment: .leading, spacing: YMSpace.sm) {
                HStack(spacing: YMSpace.sm) {
                    chips(Array(OrgKind.allCases.prefix(3)))
                    Spacer(minLength: 0)
                }
                HStack(spacing: YMSpace.sm) {
                    chips(Array(OrgKind.allCases.dropFirst(3)))
                    extraChip
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, YMSpace.xl)

            // Узкий экран: чип-действие — отдельной третьей строкой, а не прокруткой.
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                HStack(spacing: YMSpace.sm) {
                    chips(Array(OrgKind.allCases.prefix(3)))
                    Spacer(minLength: 0)
                }
                HStack(spacing: YMSpace.sm) {
                    chips(Array(OrgKind.allCases.dropFirst(3)))
                    Spacer(minLength: 0)
                }
                if extra != nil {
                    HStack(spacing: YMSpace.sm) {
                        extraChip
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMSpace.sm) { chips(Array(OrgKind.allCases)); extraChip }
                    .padding(.horizontal, YMSpace.xl)
            }
        }
    }

    @ViewBuilder
    private var extraChip: some View {
        if let extra {
            Chip(label: extra.label, active: false) {
                Haptics.selection()
                extra.action()
            }
        }
    }

    /// Серая подложка вокруг группы чипов.
    private func plate<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 2) { content() }
            .padding(4)
            .background(YMUi.segmentBg, in: Capsule())
    }

    @ViewBuilder
    private func chips(_ kinds: [OrgKind]) -> some View {
        plate { chipItems(kinds) }
    }

    @ViewBuilder
    private func chipItems(_ kinds: [OrgKind]) -> some View {
        ForEach(kinds) { kind in
            SegChip(label: kind.rawValue, active: kind == selected, ns: plateNS) {
                Haptics.selection()
                withAnimation(YMMotion.snappy) { selected = kind }
                onChange?(kind)
            }
        }
    }
}

/// Чип ряда категорий (этап 12): на серой подложке, активный — белая плашка (matchedGeometryEffect).
struct SegChip: View {
    let label: String
    let active: Bool
    let ns: Namespace.ID
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Text(label)
                .ymText(YMText.button)
                .foregroundStyle(active ? YMUi.text : YMUi.textSecondary)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background {
                    if active {
                        Capsule().fill(YMUi.segmentSelected)
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .matchedGeometryEffect(id: "chipPlate", in: ns)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
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
                .ymFont(13.5, weight: .semibold)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let active = i == index
                Button {
                    Haptics.selection()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: YMDur.tabSwitch)) { index = i }
                } label: {
                    // Редизайн, этап 3: серая подложка, выбранное — на белой плашке (как YMSegmented).
                    Text(options[i])
                        .font(YMFont.styled(.subhead, active ? .semibold : .medium))
                        .foregroundStyle(YMUi.text)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if active {
                                Capsule()
                                    .fill(YMUi.segmentSelected)
                                    .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "seg", in: ns)
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
