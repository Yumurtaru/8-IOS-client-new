import SwiftUI

//
//  CartV2.swift — новый вид корзины (редизайн, этап 9, ТЗ 5.8).
//  Только разметка: данные и действия приходят снаружи (CartView владеет логикой —
//  общий заказ, проверки, комментарий, итог). Включается флагом YMFlags.newOrderLookKey.
//

/// Лист поверх корзины: один `.sheet(item:)` (два `.sheet` на одной вью не работают).
enum CartV2Sheet: Identifiable {
    case product(Int)
    var id: String {
        switch self { case .product(let i): return "product-\(i)" }
    }
}

/// Меню заведения, уже загруженное экраном заведения (запоминается в памяти, новых запросов нет).
@MainActor
enum CartV2Menu {
    private static var bySlug: [String: [Product]] = [:]

    static func remember(slug: String, items: [Product]) {
        guard !slug.isEmpty, !items.isEmpty else { return }
        var cur = bySlug[slug] ?? []
        let known = Set(cur.map(\.id))
        cur += items.filter { !known.contains($0.id) }
        bySlug[slug] = cur
    }

    /// Недорогие товары заведения, которых нет в корзине (до 10 штук).
    static func suggestions(slug: String?, excluding inCart: Set<Int>) -> [Product] {
        guard let slug, let all = bySlug[slug] else { return [] }
        let ok = all.filter { !inCart.contains($0.id) && $0.stopped != true && Money.dec($0.price) > 0 }
        let sorted = ok.sorted { Money.dec($0.price) < Money.dec($1.price) }
        return Array(sorted.prefix(10))
    }
}

// MARK: - Шапка

struct CartV2Header: View {
    var showGroup: Bool
    var groupBusy: Bool
    var onBack: () -> Void
    var onGroup: () -> Void

    var body: some View {
        ZStack {
            Text("Корзина")
                .ymText(YMText.sectionTitle)
                .foregroundStyle(YMUi.text)
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .accessibilityLabel("Назад")
                        .ymIcon(16, weight: .semibold)
                        .foregroundStyle(YMUi.text)
                        .frame(width: YMForm.closeButton, height: YMForm.closeButton)
                        .background(YMUi.card, in: Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                if showGroup {
                    Button(action: onGroup) {
                        Text(groupBusy ? "…" : "Общий заказ")
                            .ymText(YMText.cardTitle)
                            .foregroundStyle(YMColor.accent)
                            .padding(.horizontal, 12).frame(height: YMForm.closeButton)
                            .background(YMUi.card, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(groupBusy)
                }
            }
        }
        .padding(.horizontal, YMForm.screenPadding)
        .padding(.top, 4)
        .padding(.bottom, YMForm.cardGap)
    }
}

// MARK: - Карточка заведения

struct CartV2Shop: View {
    let name: String
    let count: Int
    var onMenu: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(YMUi.photoBg)
                Text(String(name.prefix(1)).uppercased())
                    .ymText(YMText.sectionTitle)
                    .foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).ymText(YMText.cardTitle).foregroundStyle(YMUi.text).lineLimit(1)
                Text("В корзине \(count) \(ruItemsWord(count))")
                    .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            }
            Spacer()
            Button(action: onMenu) {
                Text("Меню").ymText(YMText.cardTitle).foregroundStyle(YMColor.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(YMForm.cardPadding)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }
}

// MARK: - Строка товара

struct CartV2Line: View {
    @Environment(\.colorScheme) private var scheme
    let line: CartLine
    let lineTotal: Decimal
    let lines: [CartLine]
    let locked: Bool
    var onDec: () -> Void
    var onInc: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 60, height: 60)
                .background(YMUi.photoBg)
                .overlay {
                    PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 0, tone: line.productId, fit: true)
                        .padding(4)
                        .blendMode(scheme == .dark ? .normal : .multiply)
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(line.name).ymText(YMText.cardTitle).foregroundStyle(YMUi.text).lineLimit(2)
                if !line.modsLabel.isEmpty {
                    Text(line.modsLabel).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary).lineLimit(2)
                } else if let u = line.unit, !u.isEmpty {
                    Text(fmtQty(line.qty, u)).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                }
                WholesaleBadge(line: line, lines: lines)
                Text(Money.format(lineTotal))
                    .ymText(YMText.cardPrice)
                    .foregroundStyle(YMUi.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .accessibilityLabel("Сумма \(Money.format(lineTotal))")
            }
            Spacer(minLength: 6)
            QtyStepper(qtyText: line.isFractional ? fmtQty(line.qty) : "\(Int(line.qty.rounded()))",
                       onMinus: onDec, onPlus: onInc)
                .fixedSize()
                .disabled(locked)
                .opacity(locked ? 0.45 : 1)
        }
        .padding(YMForm.cardPadding)
    }
}

// MARK: - Итоги

struct CartV2Totals: View {
    let count: Int
    let total: Decimal
    let fee: Decimal

    var body: some View {
        VStack(spacing: 9) {
            row("Товары (\(count))", Money.format(total), strong: true)
            row("Доставка", "рассчитается при оформлении", strong: false)
            if fee > 0 { row("Сервисный сбор", Money.format(fee), strong: false) }
        }
        .padding(YMForm.cardPadding)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }

    private func row(_ label: String, _ value: String, strong: Bool) -> some View {
        HStack {
            Text(label).ymText(YMText.description).foregroundStyle(YMUi.textSecondary)
            Spacer()
            Text(value).ymText(YMText.cardPrice)
                .foregroundStyle(strong ? YMUi.text : YMUi.textSecondary)
                .ymNumeric(value)
        }
    }
}

// MARK: - «Добавьте к заказу»

struct CartV2Suggestions: View {
    let items: [Product]
    let busyId: Int?
    var onOpen: (Product) -> Void
    var onPlus: (Product) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Добавьте к заказу")
                .ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
                .padding(.horizontal, YMForm.screenPadding)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMForm.cardGap) {
                    ForEach(items) { p in
                        CartV2SuggestTile(product: p, busy: busyId == p.id,
                                          onOpen: { onOpen(p) }, onPlus: { onPlus(p) })
                    }
                }
                .padding(.horizontal, YMForm.screenPadding)
            }
        }
    }
}

private struct CartV2SuggestTile: View {
    @Environment(\.colorScheme) private var scheme
    let product: Product
    let busy: Bool
    var onOpen: () -> Void
    var onPlus: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear
                        .aspectRatio(1, contentMode: .fit)
                        .background(YMUi.photoBg)
                        .overlay {
                            PhotoPlaceholder(url: API.imageURL(product.photo), label: "ФОТО",
                                             radius: 0, tone: product.id, fit: true)
                                .padding(8)
                                .blendMode(scheme == .dark ? .normal : .multiply)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Text(product.name ?? "—")
                        .ymText(YMText.cardTitle).foregroundStyle(YMUi.text)
                        .lineLimit(2).multilineTextAlignment(.leading)
                        .padding(.horizontal, 4).padding(.top, 8)
                    Spacer(minLength: 6)
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text(Money.format(Money.dec(product.price)))
                    .ymText(YMText.cardPrice).foregroundStyle(YMUi.text)
                    .lineLimit(1).minimumScaleFactor(0.75)
                Spacer(minLength: 0)
                Button(action: onPlus) {
                    Group {
                        if busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: "plus").ymIcon(14, weight: .semibold) }
                    }
                    .foregroundStyle(YMColor.onAccent)
                    .frame(width: 32, height: 32)
                    .background(YMUi.accentFill, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Добавить в корзину, \(product.name ?? "товар")")
            }
            .padding(.horizontal, 4).padding(.top, 4)
        }
        .padding(8)
        .frame(width: 140, height: 220, alignment: .topLeading)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }
}

// MARK: - Нижняя панель и пустая корзина

struct CartV2PayBar: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(YMPrimaryButtonStyle())
            .padding(.horizontal, YMForm.screenPadding)
            .padding(.vertical, 10)
            .background(
                YMUi.screenBg
                    .overlay(alignment: .top) { YMUi.disabledBg.frame(height: 1) }
                    .ignoresSafeArea(edges: .bottom)
            )
    }
}

struct CartV2Empty: View {
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "bag").ymIcon(48, weight: .light).foregroundStyle(YMColor.accent)
            Text("Корзина пуста").ymText(YMText.screenTitle).foregroundStyle(YMUi.text)
                .multilineTextAlignment(.center)
            Text("Загляните в каталог — выберите\nблюда любимого заведения")
                .ymText(YMText.body).foregroundStyle(YMUi.textSecondary)
                .multilineTextAlignment(.center)
            Button(action: onClose) { Text("На главную") }
                .buttonStyle(YMPrimaryButtonStyle())
                .frame(maxWidth: 240)
                .padding(.top, 6)
        }
        .padding(.horizontal, 32)
    }
}
