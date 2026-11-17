import SwiftUI
import UIKit

//
//  PurchaseDetailView.swift — карточка покупки (П-84): GET api/v1/profile/purchases/{id}.
//  Позиции, скидки, баллы, оплаты, кассовый чек (реквизиты, QR, «Открыть чек», «Проверить чек в ФНС»),
//  возвраты, «Повторить» (тот же поток, что у заказа) и «Оценить» (форма отзыва в карточке заказа).
//  Чужая покупка — 404 «Покупка не найдена». Паритет с Android: PurchaseDetailScreen.kt.
//

struct PurchaseDetailView: View {
    let id: Int

    @State private var p: Purchase?
    @State private var error: String?
    @State private var gen = 0
    @State private var toast: String?

    private static let fnsURL = "https://check.nalog.ru/"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMForm.cardGap) {
                if let p = p {
                    headerCard(p)
                    itemsCard(p)
                    totalsCard(p)
                    receiptCard(p)
                    returnsBlock(p)
                    actionsBlock(p)
                } else if let e = error {
                    VStack(spacing: YMSpace.md) {
                        Text(e).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                        Button { Task { await load() } } label: { Text("Повторить") }
                            .buttonStyle(YMSecondaryButtonStyle())
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, YMSpace.xl)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, YMSpace.xxl)
                }
                if let t = toast {
                    Text(t).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                }
            }
            .padding(.horizontal, YMForm.screenPadding)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMUi.screenBg.ignoresSafeArea())
        .navigationTitle("Покупка")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    // MARK: Блоки

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(YMForm.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }

    private func headerCard(_ p: Purchase) -> some View {
        let name = (p.shop?.name ?? "").isEmpty ? "Заведение" : (p.shop?.name ?? "")
        return card {
            shopRow(p, name: name)
            if let n = p.number, n > 0 {
                Text("Покупка №\(n)").font(YMFont.body).foregroundStyle(YMColor.text)
            }
            Text(PurchasesLogic.whenLabel(p.createdAt)).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            if let s = p.statusTitle, !s.isEmpty {
                Text(s).ymFont(12, weight: .bold).foregroundStyle(YMColor.statusDone)
            }
        }
    }

    @ViewBuilder private func shopRow(_ p: Purchase, name: String) -> some View {
        let slug = p.shop?.slug ?? ""
        let row = HStack(spacing: YMSpace.md) {
            LogoBadge(url: API.imageURL(p.shop?.logo), letter: name.prefix(1).uppercased(), size: 44)
            Text(name).font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(2)
            Spacer(minLength: 0)
        }
        if slug.isEmpty {
            row
        } else {
            NavigationLink(destination: OrgView(shopSlug: slug)) { row }.buttonStyle(.plain)
        }
    }

    @ViewBuilder private func itemsCard(_ p: Purchase) -> some View {
        let items = p.items ?? []
        if !items.isEmpty {
            card {
                Text("Состав").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in itemRow(it) }
            }
        }
    }

    private func itemRow(_ it: PurchaseItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 8) {
                Text(it.name ?? "Товар").font(YMFont.body).foregroundStyle(YMColor.text)
                Spacer(minLength: 8)
                Text(Money.format(it.total ?? 0)).font(YMFont.body).foregroundStyle(YMColor.text)
            }
            if let m = it.modifiersLabel, !m.isEmpty {
                Text(m).ymFont(11, weight: .regular).foregroundStyle(YMUi.textSecondary)
            }
            Text(itemLine(it)).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            if let r = it.returnQty, r > 0 {
                Text("Возвращено: \(PurchasesLogic.qtyLabel(r, unit: it.unit))")
                    .ymText(YMText.caption).foregroundStyle(YMColor.statusCancel)
            }
        }
        .padding(.vertical, 2)
    }

    private func itemLine(_ it: PurchaseItem) -> String {
        let q = PurchasesLogic.qtyLabel(it.qty, unit: it.unit)
        let price = Money.format(it.price ?? 0)
        return q.isEmpty ? price : "\(q) × \(price)"
    }

    private func totalsCard(_ p: Purchase) -> some View {
        card {
            if let s = p.subtotal { amountRow("Сумма", Money.format(s), color: YMColor.text) }
            ForEach(Array((p.discounts ?? []).enumerated()), id: \.offset) { _, d in
                amountRow((d.name ?? "").isEmpty ? "Скидка" : (d.name ?? ""),
                          "−" + Money.format(d.amount ?? 0), color: YMColor.statusDone)
            }
            if let dt = p.discountTotal, dt > 0 { amountRow("Скидки всего", "−" + Money.format(dt), color: YMColor.statusDone) }
            bonusRows(p)
            ForEach(Array((p.payments ?? []).enumerated()), id: \.offset) { _, pay in
                amountRow((pay.title ?? "").isEmpty ? "Оплата" : (pay.title ?? ""),
                          Money.format(pay.amount ?? 0), color: YMColor.text)
            }
            HStack {
                Text("Итого").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                Spacer(minLength: 8)
                Text(Money.format(p.total ?? 0)).ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder private func bonusRows(_ p: Purchase) -> some View {
        if let b = p.bonus {
            if let e = b.earned, e > 0 { amountRow("Начислено баллов", "+" + PurchasesLogic.points(e), color: YMColor.statusDone) }
            if let s = b.spent, s > 0 { amountRow("Списано баллов", "−" + PurchasesLogic.points(s), color: YMColor.statusCancel) }
            if let c = b.clawed, c > 0 { amountRow("Списано за возврат", "−" + PurchasesLogic.points(c), color: YMColor.statusCancel) }
        }
    }

    private func amountRow(_ title: String, _ value: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(YMFont.body).foregroundStyle(YMUi.textSecondary)
            Spacer(minLength: 8)
            Text(value).font(YMFont.body).foregroundStyle(color)
        }
    }

    // MARK: Кассовый чек

    @ViewBuilder private func receiptCard(_ p: Purchase) -> some View {
        if let f = p.fiscal {
            card {
                Text("Кассовый чек").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                fiscalLines(f)
                receiptQrBlock(p.receiptQr)
                receiptButtons(p)
            }
        } else {
            card {
                Text("Кассовый чек появится, когда касса передаст данные")
                    .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            }
        }
    }

    @ViewBuilder private func fiscalLines(_ f: PurchaseFiscal) -> some View {
        if let v = f.fn, !v.isEmpty { amountRow("ФН", v, color: YMColor.text) }
        if let v = f.fd { amountRow("ФД", "\(v)", color: YMColor.text) }
        if let v = f.fpd, !v.isEmpty { amountRow("ФПД", v, color: YMColor.text) }
        if let v = f.kktRn, !v.isEmpty { amountRow("РН ККТ", v, color: YMColor.text) }
        let when = PurchasesLogic.whenLabel(f.datetime)
        if !when.isEmpty { amountRow("Дата фискализации", when, color: YMColor.text) }
    }

    @ViewBuilder private func receiptQrBlock(_ qr: String?) -> some View {
        if let s = qr, !s.isEmpty, let img = CardBarcode.qr(s) {
            Image(uiImage: img)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(8)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("QR-код кассового чека")
        }
    }

    @ViewBuilder private func receiptButtons(_ p: Purchase) -> some View {
        if let u = PurchasesLogic.httpsURL(p.ofdUrl) {
            Button { openLink(u) } label: { Text("Открыть чек") }
                .buttonStyle(YMPrimaryButtonStyle())
        }
        if let u = URL(string: Self.fnsURL) {
            Button { openLink(u) } label: { Text("Проверить чек в ФНС") }
                .buttonStyle(YMSecondaryButtonStyle())
        }
        if let s = p.receiptQr, !s.isEmpty {
            Button { copy(s) } label: { Text("Скопировать данные чека") }
                .buttonStyle(YMSecondaryButtonStyle())
        }
    }

    // MARK: Возвраты

    @ViewBuilder private func returnsBlock(_ p: Purchase) -> some View {
        let list = p.returns ?? []
        if !list.isEmpty {
            card {
                Text("Возвраты").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                ForEach(Array(list.enumerated()), id: \.offset) { _, r in returnRow(r) }
            }
        }
    }

    private func returnRow(_ r: PurchaseReturn) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(PurchasesLogic.whenLabel(r.createdAt)).font(YMFont.body).foregroundStyle(YMUi.textSecondary)
                Spacer(minLength: 8)
                Text("−" + Money.format(r.amount ?? 0)).font(YMFont.body).foregroundStyle(YMColor.statusCancel)
            }
            if let s = r.status, !s.isEmpty {
                Text(s).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            }
            receiptQrBlock(r.receiptQr)
        }
        .padding(.vertical, 2)
    }

    // MARK: Действия

    @ViewBuilder private func actionsBlock(_ p: Purchase) -> some View {
        if p.canRepeat == true {
            Button { repeatPurchase() } label: { Text("Повторить") }
                .buttonStyle(YMPrimaryButtonStyle())
        }
        if p.canReview == true && p.hasReview != true {
            Button { reviewPurchase() } label: { Text("Оценить") }
                .buttonStyle(YMSecondaryButtonStyle())
        }
        if p.hasReview == true {
            Text("Ваш отзыв").ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
        }
    }

    /// Тот же поток, что «Повторить» у заказа: деталь заказа заберёт просьбу и сделает
    /// GET orders/{id}/reorder (корзина одного магазина, диалог конфликта).
    private func repeatPurchase() {
        Haptics.light()
        OrderRepeatIntent.open(id, repeatOrder: true)
    }

    /// Форма отзыва живёт в карточке заказа — открываем её.
    private func reviewPurchase() {
        Haptics.light()
        OrderRepeatIntent.open(id, repeatOrder: false)
    }

    private func openLink(_ url: URL) {
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        Haptics.success()
        toast = "Данные чека скопированы"
    }

    // MARK: Загрузка

    private func load() async {
        gen += 1
        let my = gen
        do {
            let r: Purchase = try await API.shared.get("api/v1/profile/purchases/\(id)")
            if my != gen || Task.isCancelled { return }
            p = r
            error = nil
        } catch {
            if my != gen || Task.isCancelled { return }
            if p != nil { return }   // сбой обновления не стирает показанное
            if let api = error as? APIError, api.rejectStatus == 404 {
                self.error = "Покупка не найдена"
            } else {
                self.error = error.userMessage ?? "Не удалось загрузить покупку"
            }
        }
    }
}
