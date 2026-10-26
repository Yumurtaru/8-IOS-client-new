//
//  LoyaltyView.swift — Программа лояльности (уровни + кэшбэк), премиум-клиент (iOS, SwiftUI)
//
//  Поток 1:1 со старым клиентом (3 IOS-client · Features/Profile/LoyaltyView.swift) и
//  Android-аналогом (9 Android-client-new · loyalty/LoyaltyScreen.kt):
//    • GET api/v1/loyalty → LoyaltyInfo(level, next, doneOrders, toNext, bonusBalance, levels)
//      LoyaltyLevel(key, name, icon, min, cashback) — модели из общих Models.swift.
//
//  Деньги — Money (Decimal). LoyaltyInfo.bonusBalance приходит @LenientDouble → в Decimal
//  через Money.dec перед форматированием. Токены YM.*, light+dark, Dynamic Type, Reduce Motion.
//  Состояния: загрузка (skeleton) / ошибка + «Повторить» / контент.
//

import SwiftUI

struct LoyaltyView: View {
    @State private var info: LoyaltyInfo?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Group {
            if loading {
                skeleton
            } else if let e = error {
                ErrorRetryView(message: e) { Task { await load() } }
            } else if let i = info {
                content(i)
            } else {
                ErrorRetryView(message: "Нет данных") { Task { await load() } }
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Программа лояльности")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Контент

    private func content(_ i: LoyaltyInfo) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                heroCard(i)
                if let levels = i.levels, !levels.isEmpty {
                    Text("Уровни")
                        .font(YMFont.title3)
                        .foregroundStyle(YMColor.text)
                    VStack(spacing: YMSpace.md) {
                        ForEach(levels) { lv in
                            LevelRow(level: lv, isCurrent: !lv.key.isEmpty && lv.key == i.level?.key)
                        }
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
    }

    /// Hero-карта текущего уровня: золотой градиент, баланс, прогресс до следующего.
    private func heroCard(_ i: LoyaltyInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: YMSpace.md) {
                Text(iconOr(i.level?.icon, "🌱")).font(.system(size: 40))
                VStack(alignment: .leading, spacing: 2) {
                    Text(nameOr(i.level?.name, "Новичок"))
                        .font(YMFont.title3)
                        .foregroundStyle(YMColor.onAccent)
                    Text("Кэшбэк \(i.level?.cashback ?? 0)%")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.onAccent.opacity(0.9))
                }
            }

            // Бонусный баланс, если пришёл.
            if let bal = i.bonusBalance {
                Text("Бонусный баланс: \(Money.format(Money.dec(bal)))")
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.onAccent)
                    .padding(.top, YMSpace.md)
            }

            // Прогресс до следующего уровня.
            if let next = i.next {
                let toNext = i.toNext ?? 0
                Text("Ещё \(toNext) \(orderWord(toNext)) до уровня «\(nameOr(next.name, "следующего"))»")
                    .font(YMFont.callout)
                    .foregroundStyle(YMColor.onAccent.opacity(0.95))
                    .padding(.top, YMSpace.lg)
                progressBar(value: progressValue(i))
                    .padding(.top, YMSpace.sm)
            } else {
                Text("Максимальный уровень достигнут 🎉")
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.onAccent)
                    .padding(.top, YMSpace.lg)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    /// Прогресс-бар поверх золота (белым по полупрозрачному белому).
    private func progressBar(value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(YMColor.onAccent.opacity(0.28))
                Capsule().fill(YMColor.onAccent)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: 8)
    }

    // MARK: Скелетон

    private var skeleton: some View {
        VStack(spacing: YMSpace.lg) {
            SkeletonBox(radius: YMRadius.card).frame(height: 160)
            ForEach(0..<3, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 68) }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Данные

    private func load() async {
        loading = true; error = nil
        do {
            info = try await API.shared.get("api/v1/loyalty")
        } catch is CancellationError {
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    // MARK: Помощники

    private func progressValue(_ i: LoyaltyInfo) -> Double {
        guard let cur = i.level?.min, let nextMin = i.next?.min, nextMin > cur else { return 0 }
        let done = Double(i.doneOrders ?? 0)
        return min(1, max(0, (done - Double(cur)) / Double(nextMin - cur)))
    }
    private func iconOr(_ s: String?, _ fallback: String) -> String {
        let v = (s ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? fallback : v
    }
    private func nameOr(_ s: String?, _ fallback: String) -> String {
        let v = (s ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? fallback : v
    }
    private func orderWord(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "заказ" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "заказа" }
        return "заказов"
    }
}

// MARK: - Строка уровня

private struct LevelRow: View {
    let level: LoyaltyLevel
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: YMSpace.md) {
            Text(icon)
                .font(YMFont.title3)
                .frame(width: 44, height: 44)
                .background(isCurrent ? YMColor.accent.opacity(0.16) : YMColor.surface2,
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(YMFont.headline)
                    .fontWeight(isCurrent ? .bold : .semibold)
                    .foregroundStyle(YMColor.text)
                // «от 1 заказов», «от 21 заказов», «от 0 заказов» — склоняем
                // (после «от» — родительный падеж: 1 заказа, 5 заказов).
                Text(minText)
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
            }
            Spacer(minLength: 8)
            Text("\(level.cashback ?? 0)%")
                .font(YMFont.headline)
                .foregroundStyle(isCurrent ? YMColor.accent : YMColor.text)
        }
        .padding(YMSpace.md)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(isCurrent ? YMColor.accent : YMColor.hairline, lineWidth: isCurrent ? 1.5 : 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), кэшбэк \(level.cashback ?? 0)%\(isCurrent ? ", текущий уровень" : "")")
    }

    private var minText: String {
        let n = max(0, level.min ?? 0)
        if n == 0 { return "Начальный уровень" }
        let word = (n % 10 == 1 && n % 100 != 11) ? "заказа" : "заказов"
        return "от \(n) \(word)"
    }

    private var icon: String {
        let v = level.icon.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "•" : v
    }
    private var name: String {
        let v = level.name.trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "Уровень" : v
    }
}
