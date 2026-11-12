import SwiftUI

/*
 К-57: строки итогов оформления по программе лояльности.
 «Скидка по программе» — УЖЕ входит в итог сервера (discount/total), здесь только
 показывается; CheckoutView вычитает её из строки «Скидка по акции», чтобы не было
 двойного показа. «Вернётся баллами ≈ N ₽» — по cashback_estimate > 0.
*/

extension PromoPreview {
    /// Скидка по программе (для строки итогов); nil/старый сервер -> 0.
    var loyaltyDiscountValue: Decimal {
        if let d = loyaltyDiscount, d > 0 { return d }
        return 0
    }
}

struct LoyaltySummaryRows: View {
    let promo: PromoPreview?

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).ymFont(13.5).foregroundStyle(YMColor.accent)
            Spacer()
            Text(value).ymFont(13.5, weight: .semibold)
                .foregroundStyle(YMColor.accent)
                .ymNumeric(value)
        }
    }

    var body: some View {
        if let p = promo {
            if p.loyaltyDiscountValue > 0 {
                row("Скидка по программе", "−" + Money.format(p.loyaltyDiscountValue))
            }
            if let c = p.cashbackEstimate, c > 0 {
                row("Вернётся баллами ≈", Money.format(c))
            }
        }
    }
}

/// Настройка «По умолчанию списывать баллы» (локальная): начальное значение
/// переключателя «Оплатить баллами» в оформлении.
enum LoyaltyPrefs {
    static let spendDefaultKey = "loyalty_spend_default"
    static var spendDefault: Bool { UserDefaults.standard.bool(forKey: spendDefaultKey) }
}

struct LoyaltySpendDefaultToggle: View {
    @AppStorage(LoyaltyPrefs.spendDefaultKey) private var on = false

    var body: some View {
        Toggle(isOn: $on) {
            VStack(alignment: .leading, spacing: 2) {
                Text("По умолчанию списывать баллы").ymFont(14).foregroundStyle(YMColor.text)
                Text("В оформлении заказа баллами будет оплачиваться часть суммы")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
        }
        .tint(YMColor.accent)
        .padding(YMSpace.lg)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
    }
}
