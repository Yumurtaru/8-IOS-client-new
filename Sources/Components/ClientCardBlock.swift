import SwiftUI

/*
 Карточка «Карта клиента» в профиле (редизайн, этап 11, ТЗ 5.12): белая строка,
 тап открывает лист «Код для бонусов» (Components/BonusCodeSheet.swift).
 Одноразовый QR, штрихкод, EAN-13 в запасе, яркость экрана и «Обновить код карты» —
 теперь внутри листа; логика кода прежняя (Core/CardSecret.swift).
*/

struct ClientCardBlock: View {
    let code: String
    /// Баланс бонусов для плашки на листе (из профиля, если пришёл).
    var balance: Decimal? = nil

    @State private var showSheet = false

    var body: some View {
        Button { Haptics.light(); showSheet = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "qrcode")
                    .ymIcon(20, weight: .semibold)
                    .foregroundStyle(YMUi.text)
                    .frame(width: 36, height: 36)
                    .background(YMUi.screenBg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Карта клиента").ymText(YMText.body).foregroundStyle(YMUi.text)
                    Text("Код для бонусов на кассе").ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .ymIcon(13, weight: .semibold)
                    .foregroundStyle(YMUi.textSecondary)
            }
            .padding(YMForm.cardPadding)
            .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Карта клиента. Показать код для бонусов")
        .sheet(isPresented: $showSheet) {
            BonusCodeSheet(code: code, balance: balance)
        }
    }
}
