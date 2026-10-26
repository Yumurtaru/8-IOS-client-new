import SwiftUI

//
//  CartView.swift — экран корзины (screen: cart). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    CartView(onCheckout: () -> Void, onClose: () -> Void)
//      onCheckout — «Перейти к оформлению» (родитель пушит CheckoutView).
//      onClose    — «‹ Корзина» назад / «На главную» из пусто-состояния.
//
//  Данные — из Core/Cart.shared (single-store: одна корзина = один магазин).
//  Деньги — только Decimal через Money.format(Money.parse(...)). Токены — YM*.
//
//  API: экран заказ не создаёт (это делает CheckoutView) — читает Cart.shared.
//  «Комментарий к заказу…» — настоящее поле ввода. Текст хранится в
//  CheckoutDraft (привязан к заведению корзины) и подхватывается оформлением.
//

struct CartView: View {
    @ObservedObject private var cart = Cart.shared
    var onCheckout: () -> Void = {}
    var onClose: () -> Void = {}
    /// «Меню» у баннера заведения. nil — как раньше, закрыть корзину.
    var onMenu: (() -> Void)? = nil
    /// Комментарий к заказу — тот же черновик, что на оформлении (CheckoutDraft).
    @State private var comment = ""
    /// Комментарий в фокусе (клавиатура открыта) — см. bottomCTA ниже.
    @FocusState private var commentFocused: Bool
    /// Карточка заведения корзины — ради сервисного сбора (паритет с Android:
    /// там корзина показывает «Сервисный сбор» и «Итого» уже со сбором, а здесь
    /// итог был без него и на оформлении вдруг вырастал).
    @State private var feeShop: ShopDetail?

    private var serviceFee: Decimal { Money.parse(Fees.service(subtotal: cart.total, shop: feeShop)) }
    private var cartGrand: Decimal { Money.parse(cart.total) + serviceFee }

    private func loadFeeShop() async {
        guard let slug = cart.shopSlug, !slug.isEmpty else {
            await MainActor.run { feeShop = nil }
            return
        }
        let d: ShopDetail? = try? await API.shared.get("api/v1/shops/\(slug)")
        // Пока грузили, корзина могла перейти к другому заведению — чужой сбор не кладём.
        await MainActor.run { if cart.shopSlug == slug { feeShop = d } }
    }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            if cart.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .navigationBarHidden(true)
        .task(id: cart.shopSlug) { await loadFeeShop() }
    }

    // MARK: - Header «‹ Корзина»

    private var header: some View {
        HStack(spacing: YMSpace.md) {
            Button(action: { Haptics.light(); onClose() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("Корзина")
                .font(.system(size: 20, weight: .heavy))
                .foregroundStyle(YMColor.text)
            Spacer()
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.xs)
        .padding(.bottom, YMSpace.md)
    }

    // MARK: - Filled content

    private var content: some View {
        VStack(spacing: 0) {
            header
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    storeBanner
                        .padding(.bottom, YMSpace.lg)

                    SectionKicker("Ваш заказ")
                        .padding(.bottom, YMSpace.md)

                    VStack(spacing: YMSpace.md) {
                        ForEach(cart.lines) { line in
                            CartRow(line: line)
                        }
                    }

                    // Раньше это была плашка-подсказка без ввода: нажатие не давало
                    // написать комментарий. Теперь поле, текст уходит в оформление.
                    commentField
                        .padding(.top, YMSpace.lg)

                    totalsCard
                        .padding(.top, YMSpace.lg)

                    Color.clear.frame(height: YMSpace.lg)
                }
                .padding(.horizontal, YMSpace.xl)
            }
            // Клавиатура комментария убирается жестом прокрутки.
            .scrollDismissesKeyboard(.interactively)
            // Пока открыта клавиатура — вместо высокой панели «Итого / Перейти
            // к оформлению» узкая полоса «Готово»: панель поднималась над
            // клавиатурой и закрывала поле комментария, а у многострочного
            // поля нет клавиши, которая убирает клавиатуру.
            if commentFocused {
                keyboardDoneRow
            } else {
                bottomCTA
            }
        }
    }

    // Баннер магазина: лого (или монограмма) + название из Cart.shopName.
    private var storeBanner: some View {
        HStack(spacing: YMSpace.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(YMColor.surface2)
                Text(monogram)
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(cart.shopName ?? "Магазин")
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(YMColor.text)
                // Слово — «товар/товара/товаров», как на плашке корзины: «3 блюда»
                // у магазина или аптеки читалось как ошибка.
                Text("В корзине \(cart.count) \(ruItemsWord(cart.count))")
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
            }
            Spacer()
            Button(action: { Haptics.light(); if let m = onMenu { m() } else { onClose() } }) {
                Text("Меню")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(YMColor.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private var monogram: String {
        let s = (cart.shopName ?? "").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "•" : String(s.prefix(1)).uppercased()
    }

    // Поле «Комментарий к заказу…» (dashed, как в макете и на оформлении).
    private var commentField: some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 15))
                .foregroundStyle(YMColor.muted)
            TextField("Комментарий к заказу…", text: $comment, axis: .vertical)
                .focused($commentFocused)
                .font(.system(size: 13.5))
                .foregroundStyle(YMColor.text)
                .tint(YMColor.accent)
                .lineLimit(1...4)
                .onChange(of: comment) { v in
                    CheckoutDraft.shopId = cart.shopId
                    CheckoutDraft.comment = v
                }
                // П-25 №6: comment заказа сервер молча режет до 490 знаков.
                .ymMaxLength($comment, 490)
        }
        .onAppear {
            if CheckoutDraft.shopId != nil, CheckoutDraft.shopId == cart.shopId, comment.isEmpty {
                comment = CheckoutDraft.comment
            }
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(YMColor.hairline)
        )
    }

    // Блок итогов (на корзине — Товары + Доставка «рассчитается при оформлении»).
    private var totalsCard: some View {
        VStack(spacing: 9) {
            totalRow("Товары (\(cart.count))", Money.format(Money.parse(cart.total)), bold: true)
            totalRow("Доставка", "рассчитается при оформлении")
            if serviceFee > 0 {
                totalRow("Сервисный сбор", Money.format(serviceFee))
            }
        }
        .padding(YMSpace.lg)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    private func totalRow(_ label: String, _ value: String, bold: Bool = false) -> some View {
        HStack {
            Text(label).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value)
                .font(.system(size: 13.5, weight: bold ? .heavy : .semibold))
                .foregroundStyle(bold ? YMColor.text : YMColor.muted)
        }
    }

    private var keyboardDoneRow: some View {
        HStack {
            Spacer()
            Button("Готово") { commentFocused = false }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(YMColor.accent)
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.sm)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { YMColor.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // Нижний CTA: «Перейти к оформлению» + сумма.
    private var bottomCTA: some View {
        VStack(spacing: YMSpace.md) {
            HStack {
                Text("Итого")
                    .font(.system(size: 13.5))
                    .foregroundStyle(YMColor.muted)
                Spacer()
                // Итог со сбором — как на Android и как потом на оформлении.
                Text(Money.format(cartGrand))
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(YMColor.text)
            }
            Button(action: { Haptics.medium(); onCheckout() }) {
                Text("Перейти к оформлению")
            }
            .buttonStyle(YMPrimaryButtonStyle())
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.top, YMSpace.lg)
        .padding(.bottom, YMSpace.xxl)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(alignment: .top) { YMColor.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Empty state (дизайнерское)

    private var emptyState: some View {
        VStack(spacing: 0) {
            header
            Spacer()
            VStack(spacing: YMSpace.lg) {
                ZStack {
                    Circle()
                        .fill(YMColor.accent.opacity(0.12))
                        .frame(width: 120, height: 120)
                    Image(systemName: "bag")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(YMColor.accent)
                }
                VStack(spacing: YMSpace.sm) {
                    Text("Корзина пуста")
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    Text("Загляните в каталог — выберите\nблюда любимого заведения")
                        .font(YMFont.body)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: { Haptics.light(); onClose() }) {
                    Text("На главную")
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .frame(maxWidth: 240)
                .padding(.top, YMSpace.sm)
            }
            .padding(.horizontal, YMSpace.xxxl)
            Spacer()
            Spacer()
        }
    }
}

// MARK: - Строка товара со степпером −/N/+

private struct CartRow: View {
    let line: CartLine
    @ObservedObject private var cart = Cart.shared

    // Как Cart.total и сервер: строка округляется до копейки отдельно,
    // иначе строка могла разойтись с итогом на 1 копейку.
    private var lineTotal: Decimal {
        var v = Money.parse(line.unitPrice) * (Decimal(string: String(line.qty)) ?? 0)
        var r = Decimal(); NSDecimalRound(&r, &v, 2, .plain); return r
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 14, tone: line.productId)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .font(.system(size: 14.5, weight: .bold))
                    .foregroundStyle(YMColor.text)
                    .lineLimit(1)
                if !line.modsLabel.isEmpty {
                    Text(line.modsLabel)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                        .lineLimit(1)
                } else if let u = line.unit, !u.isEmpty {
                    Text(fmtQty(line.qty, u))
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }
            }

            Spacer(minLength: YMSpace.sm)

            stepper

            Text(Money.format(lineTotal))
                .font(.system(size: 14.5, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .fixedSize()
        }
    }

    // −/N/+ степпер: N — количество (дробное для весовых), минус удаляет при 0.
    private var stepper: some View {
        HStack(spacing: 8) {
            Button(action: { Haptics.light(); cart.dec(line.key) }) {
                Image(systemName: "minus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(line.isFractional ? fmtQty(line.qty) : "\(Int(line.qty.rounded()))")
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(YMColor.text)
                .frame(minWidth: 20)

            Button(action: { Haptics.light(); cart.inc(line.key) }) {
                Image(systemName: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMColor.onAccent)
                    .frame(width: 26, height: 26)
                    .background(YMColor.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - Секционный кикер (UPPERCASE подпись раздела)

struct SectionKicker: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 13, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
