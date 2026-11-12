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
    /// П-72 п.3: «Общий заказ» из корзины.
    @State private var groupBusy = false
    @State private var groupError: String?
    @State private var groupChoice = false
    /// Редизайн, этап 9: новый вид корзины (Профиль -> «Новый вид корзины и оформления»).
    @AppStorage(YMFlags.newOrderLookKey) private var newOrderLook = true
    @State private var v2Sheet: CartV2Sheet?
    @State private var quickBusy: Int?

    private var serviceFee: Decimal { Fees.service(subtotal: cart.total, shop: feeShop) }
    private var cartGrand: Decimal { cart.total + serviceFee }

    private func loadFeeShop() async {
        guard let slug = cart.shopSlug, !slug.isEmpty else {
            await MainActor.run { feeShop = nil }
            return
        }
        let d: ShopDetail? = try? await API.shared.get("api/v1/shops/\(slug)", fresh: true)
        // Пока грузили, корзина могла перейти к другому заведению — чужой сбор не кладём.
        await MainActor.run { if cart.shopSlug == slug { feeShop = d } }
    }

    var body: some View {
        ZStack {
            (newOrderLook ? YMUi.screenBg : YMColor.bg).ignoresSafeArea()
            if cart.isEmpty {
                if newOrderLook { emptyStateV2 } else { emptyState }
            } else {
                if newOrderLook { contentV2 } else { content }
            }
        }
        .sheet(item: $v2Sheet) { sh in
            switch sh {
            case .product(let id):
                NavigationStack { ProductView(id: id) }
            }
        }
        .navigationBarHidden(true)
        .task(id: cart.shopSlug) { await loadFeeShop() }
        // AT-3: неотвеченное оформление старше суток — снимаем при открытии корзины.
        .onAppear { cart.expireStalePending() }
    }

    // MARK: - Общий заказ (П-72 п.3)

    private func startGroup() {
        groupError = nil
        guard Session.shared.isLoggedIn else {
            groupError = "Войдите в аккаунт (Профиль), чтобы создать общий заказ"
            return
        }
        if GroupCartMemory.lastCode != nil { groupChoice = true } else { createGroup() }
    }

    /// Создаёт общий заказ в заведении корзины и переносит в него позиции корзины.
    private func createGroup() {
        guard let sid = cart.shopId, !groupBusy else { return }
        let lines = GroupCartAPI.lines(fromCart: cart, shopId: sid)
        if let e = GroupCartAPI.limitError(lines) { groupError = e; return }
        groupBusy = true
        Task {
            do {
                let created = try await GroupCartAPI.create(shopId: sid)
                guard let code = created.code, !code.isEmpty else { throw APIError.decoding }
                try await GroupCartAPI.putItems(code, lines: lines)
                await MainActor.run {
                    groupBusy = false
                    GroupCartMemory.lastCode = code
                    NavCoordinator.shared.openGroup(code: code)
                }
            } catch {
                await MainActor.run { groupBusy = false; groupError = GroupCartText.message(error) }
            }
        }
    }

    // MARK: - Header «‹ Корзина»

    private var header: some View {
        HStack(spacing: YMSpace.md) {
            Button(action: { Haptics.light(); onClose() }) {
                Image(systemName: "chevron.left")
                    .accessibilityLabel("Назад")
                    .ymIcon(18, weight: .semibold)
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Text("Корзина")
                .ymFont(20, weight: .heavy)
                .foregroundStyle(YMColor.text)
            Spacer()
            if !cart.isEmpty {
                Button(action: { Haptics.light(); startGroup() }) {
                    Text(groupBusy ? "…" : "Общий заказ")
                        .ymFont(14, weight: .semibold)
                        .foregroundStyle(YMColor.accent)
                        .padding(.horizontal, 12).frame(height: 38)
                        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(groupBusy)
                .confirmationDialog("Общий заказ", isPresented: $groupChoice, titleVisibility: .visible) {
                    if let last = GroupCartMemory.lastCode {
                        Button("Открыть текущий общий заказ") { NavCoordinator.shared.openGroup(code: last) }
                    }
                    Button("Создать новый из корзины") { createGroup() }
                    Button("Не сейчас", role: .cancel) {}
                }
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.xs)
        .padding(.bottom, YMSpace.md)
    }

    // Плашки AT-3 (общие для старого и нового вида).
    @ViewBuilder private var pendingNotices: some View {
                    // AT-3: исход прошлого оформления неизвестен — корзина не меняется.
                    // Пока запрос ещё летит — без плашки (уйти с оформления в это время нельзя).
                    if cart.pendingOrder?.unknown == true {
                        Button(action: { Haptics.light(); onCheckout() }) {
                            VStack(alignment: .leading, spacing: YMSpace.xs) {
                                Text("Прошлое оформление не завершилось")
                                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                                Text("Ответ сервера не дошёл — заказ мог создаться. Откройте оформление: повторите отправку или проверьте «Мои заказы». Корзину можно менять после этого.")
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Открыть оформление")
                                    .ymFont(14, weight: .semibold).foregroundStyle(YMColor.accent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(YMSpace.lg)
                            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(YMColor.statusCancel.opacity(0.55), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, YMSpace.lg)
                    }
                    // AT-3: запись старше суток снята — человек должен об этом узнать.
                    if cart.pendingExpired {
                        Button(action: { cart.pendingExpired = false }) {
                            VStack(alignment: .leading, spacing: YMSpace.xs) {
                                Text("Прошлое оформление сутки назад не завершилось — проверьте «Мои заказы», не создался ли заказ.")
                                    .font(YMFont.caption).foregroundStyle(YMColor.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text("Понятно").ymFont(14, weight: .semibold).foregroundStyle(YMColor.accent)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(YMSpace.lg)
                            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, YMSpace.lg)
                    }
    }

    // MARK: - Filled content

    private var content: some View {
        VStack(spacing: 0) {
            header
            if let e = groupError {
                Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, YMSpace.xl).padding(.bottom, YMSpace.sm)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    storeBanner
                        .padding(.bottom, YMSpace.lg)

                    pendingNotices

                    SectionKicker("Ваш заказ")
                        .padding(.bottom, YMSpace.md)

                    VStack(spacing: YMSpace.md) {
                        ForEach(cart.lines) { line in
                            CartRow(line: line)
                        }
                    }

                    // Раньше это была плашка-подсказка без ввода: нажатие не давало
                    // написать комментарий. Теперь поле, текст уходит в оформление.
                    commentField()
                        .padding(.top, YMSpace.lg)

                    totalsCard
                        .padding(.top, YMSpace.lg)

                    Color.clear.frame(height: YMSpace.lg)
                }
                .ymReadableWidth()
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
                    .ymFont(17, weight: .heavy)
                    .foregroundStyle(YMColor.accent)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(cart.shopName ?? "Магазин")
                    .ymFont(14.5, weight: .bold)
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
                    .ymFont(12, weight: .bold)
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
    private func commentField(card: Bool = false) -> some View {
        HStack(spacing: YMSpace.sm) {
            Image(systemName: "square.and.pencil")
                .ymIcon(15)
                .foregroundStyle(YMColor.muted)
            TextField("Комментарий к заказу…", text: $comment, axis: .vertical)
                .focused($commentFocused)
                // AT-3: при неотвеченном оформлении комментарий не правится (уйдёт прежний).
                .disabled(cart.pendingOrder != nil)
                .ymFont(13.5)
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
        .background(card ? YMUi.card : YMColor.surface,
                    in: RoundedRectangle(cornerRadius: card ? YMForm.cardRadius : 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                .foregroundStyle(YMColor.hairline)
                .opacity(card ? 0 : 1)
        )
    }

    // Блок итогов (на корзине — Товары + Доставка «рассчитается при оформлении»).
    private var totalsCard: some View {
        VStack(spacing: 9) {
            totalRow("Товары (\(cart.count))", Money.format(cart.total), bold: true)
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
            Text(label).ymFont(13.5).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value)
                .font(.custom(YMFont.golosName(bold ? .heavy : .semibold), fixedSize: 13.5))
                .foregroundStyle(bold ? YMColor.text : YMColor.muted)
                .ymNumeric(value)
        }
    }

    private var keyboardDoneRow: some View {
        HStack {
            Spacer()
            Button("Готово") { commentFocused = false }
                .ymFont(15, weight: .semibold)
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
                    .ymFont(13.5)
                    .foregroundStyle(YMColor.muted)
                Spacer()
                // Итог со сбором — как на Android и как потом на оформлении.
                Text(Money.format(cartGrand))
                    .ymFont(22, weight: .heavy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(YMColor.text)
                    .ymNumeric(cartGrand)
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
                        .ymIcon(48, weight: .light)
                        .foregroundStyle(YMColor.accent)
                }
                VStack(spacing: YMSpace.sm) {
                    Text("Корзина пуста")
                        .ymFont(22, weight: .heavy)
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
    // MARK: - Новый вид (редизайн, этап 9, ТЗ 5.8). Разметка — CartV2.swift, логика — выше.

    private var lineLocked: Bool { cart.pendingOrder != nil }

    private var suggestionItems: [Product] {
        guard !lineLocked else { return [] }
        return CartV2Menu.suggestions(slug: cart.shopSlug, excluding: Set(cart.lines.map(\.productId)))
    }

    private var contentV2: some View {
        VStack(spacing: 0) {
            CartV2Header(showGroup: !cart.isEmpty, groupBusy: groupBusy,
                         onBack: { Haptics.light(); onClose() },
                         onGroup: { Haptics.light(); startGroup() })
                .confirmationDialog("Общий заказ", isPresented: $groupChoice, titleVisibility: .visible) {
                    if let last = GroupCartMemory.lastCode {
                        Button("Открыть текущий общий заказ") { NavCoordinator.shared.openGroup(code: last) }
                    }
                    Button("Создать новый из корзины") { createGroup() }
                    Button("Не сейчас", role: .cancel) {}
                }
            if let e = groupError {
                Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, YMForm.screenPadding).padding(.bottom, YMSpace.sm)
            }
            ScrollView(showsIndicators: false) {
                VStack(spacing: YMForm.cardGap) {
                    CartV2Shop(name: cart.shopName ?? "Магазин", count: cart.count,
                               onMenu: { Haptics.light(); if let m = onMenu { m() } else { onClose() } })
                    pendingNotices

                    VStack(spacing: 0) {
                        ForEach(Array(cart.lines.enumerated()), id: \.element.id) { idx, line in
                            CartV2Line(line: line,
                                       lineTotal: Wholesale.lineTotal(line, in: cart.lines),
                                       lines: cart.lines, locked: lineLocked,
                                       onDec: { cart.dec(line.key) },
                                       onInc: { cart.inc(line.key) })
                            if idx < cart.lines.count - 1 { Divider().padding(.leading, YMForm.cardPadding) }
                        }
                    }
                    .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))

                    commentField(card: true)

                    let sug = suggestionItems
                    if !sug.isEmpty {
                        CartV2Suggestions(items: sug, busyId: quickBusy,
                                          onOpen: { v2Sheet = .product($0.id) },
                                          onPlus: { addSuggestion($0) })
                            .padding(.horizontal, -YMForm.screenPadding)
                            .padding(.top, 6)
                    }

                    CartV2Totals(count: cart.count, total: cart.total, fee: serviceFee)
                    Color.clear.frame(height: YMSpace.lg)
                }
                .ymReadableWidth()
                .padding(.horizontal, YMForm.screenPadding)
            }
            .scrollDismissesKeyboard(.interactively)
            if commentFocused {
                keyboardDoneRow
            } else {
                CartV2PayBar(title: "К оплате · \(Money.format(cartGrand))",
                             action: { Haptics.medium(); onCheckout() })
            }
        }
    }

    private var emptyStateV2: some View {
        VStack(spacing: 0) {
            CartV2Header(showGroup: false, groupBusy: false,
                         onBack: { Haptics.light(); onClose() }, onGroup: {})
            Spacer()
            CartV2Empty(onClose: { Haptics.light(); onClose() })
            Spacer()
            Spacer()
        }
    }

    /// «+» в ленте «Добавьте к заказу»: тот же путь, что у плитки меню (QuickAdd -> Cart.add);
    /// с обязательным выбором или при неясности - карточка товара.
    private func addSuggestion(_ p: Product) {
        if quickBusy != nil { return }
        let open = feeShop?.isOpen != false && !ShopPause.isPaused(feeShop?.paused)
        guard feeShop != nil, open, !Cart.shared.checkLocked() else { v2Sheet = .product(p.id); return }
        quickBusy = p.id
        Task { @MainActor in
            let needs = await QuickAdd.needsCard(p)
            if needs == false, let d = await QuickAdd.detail(p.id), d.shopId == cart.shopId {
                let ok = Cart.shared.add(product: d, modifierIds: [], options: [],
                                         shopId: d.shopId ?? 0, shopName: d.shopName, qty: 1)
                if ok { Haptics.success() } else { Haptics.warning(); v2Sheet = .product(p.id) }
            } else {
                v2Sheet = .product(p.id)
            }
            quickBusy = nil
        }
    }
}

// MARK: - Строка товара со степпером −/N/+

private struct CartRow: View {
    let line: CartLine
    @ObservedObject private var cart = Cart.shared

    // Как Cart.total и сервер: строка округляется до копейки отдельно,
    // иначе строка могла разойтись с итогом на 1 копейку.
    // O1: цена единицы — по формуле опта (qtyTotal по всем строкам товара).
    private var lineTotal: Decimal { Wholesale.lineTotal(line, in: cart.lines) }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            PhotoPlaceholder(url: API.imageURL(line.photo), label: "ФОТО", radius: 14, tone: line.productId, fit: true)
                .frame(width: 56, height: 56)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(line.name)
                    .ymFont(14.5, weight: .bold)
                    .foregroundStyle(YMColor.text)
                    .lineLimit(2)
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
                WholesaleBadge(line: line, lines: cart.lines)
            }

            Spacer(minLength: YMSpace.sm)

            stepper

            Text(Money.format(lineTotal))
                .ymFont(14.5, weight: .heavy)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(YMColor.text)
                .fixedSize()
                .accessibilityLabel("Сумма \(Money.format(lineTotal))")
        }
    }

    // −/N/+ степпер: N — количество (дробное для весовых), минус удаляет при 0.
    private var stepper: some View {
        HStack(spacing: 8) {
            Button(action: { Haptics.light(); cart.dec(line.key) }) {
                Image(systemName: "minus")
                    .accessibilityLabel("Уменьшить количество, \(line.name)")
                    .ymIcon(14, weight: .semibold)
                    .foregroundStyle(YMColor.text)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Text(line.isFractional ? fmtQty(line.qty) : "\(Int(line.qty.rounded()))")
                .ymFont(14, weight: .heavy)
                .foregroundStyle(YMColor.text)
                .frame(minWidth: 20)
                .accessibilityLabel("Количество")
                .accessibilityValue(line.isFractional ? fmtQty(line.qty) : "\(Int(line.qty.rounded()))")

            Button(action: { Haptics.light(); cart.inc(line.key) }) {
                Image(systemName: "plus")
                    .accessibilityLabel("Увеличить количество, \(line.name)")
                    .ymIcon(14, weight: .semibold)
                    .foregroundStyle(YMColor.onAccent)
                    .frame(width: 26, height: 26)
                    .background(YMColor.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .frame(height: 34)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        // AT-3: пока исход прошлого оформления неизвестен, состав не меняется
        // (плашка над списком объясняет почему).
        .disabled(cart.pendingOrder != nil)
        .opacity(cart.pendingOrder != nil ? 0.45 : 1)
    }
}

// MARK: - Секционный кикер (UPPERCASE подпись раздела)

struct SectionKicker: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .ymFont(13, weight: .heavy)
            .tracking(0.5)
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
