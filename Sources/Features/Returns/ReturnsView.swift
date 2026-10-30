//
//  ReturnsView.swift — Возвраты (премиум iOS-клиент Yumurta)
//
//  Экран «Возвраты»: список заявок + оформление возврата.
//  Точка входа: ReturnsView() (навигацию/пуш решает вызывающая сторона).
//
//  ПРИВЯЗКА К API (реальные пути, сверено по core/api_v1.php):
//    • GET  api/v1/returns                                → [ReturnItem]
//        поля: id, order_id, type, reason_code, status, refund_amount, created_at, shop
//    • POST api/v1/returns  ← ReturnCreateBody(order_id,type,reason_code,reason_text[,items])
//        А111: type=partial + items [{item_id, qty}] — если вернуть не всё (core/helpers.php returnBuild).
//    • GET  api/v1/orders/{id}                            → OrderDetail (позиции для «сколько вернуть»)
//    • GET  api/profile/returns/{id}  (сайт, {ok,data})    → ReturnDetail (order_number, items) — А111
//        сервер принимает возврат только для заказа со status='done';
//        reason_code валидируется по белому списку сервера (иначе → 'other').
//        ответ: {id}
//    • GET  api/v1/orders                                 → [Order]  (выбор заказа в форме)
//    • GET  api/v1/orders/{id}/return-eligibility         → ReturnEligibility {eligible, window_hours, reason}
//
//  Статусы возврата сервера: pending / approved / rejected / refunded / closed.
//  Деньги — Decimal через Money.format(Money.parse(refundAmount)) (канон нового клиента).
//  Токены YM.*, light+dark, Dynamic Type. Состояния: загрузка / пусто / ошибка+Повторить.
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Справочники статусов / причин
// ─────────────────────────────────────────────────────────────────────────────

enum ReturnStatus {
    /// Русская подпись статуса заявки на возврат.
    static func label(_ s: String?) -> String {
        switch (s ?? "").lowercased() {
        case "pending":  return "На рассмотрении"
        case "approved": return "Одобрен"
        case "rejected": return "Отклонён"
        case "refunded": return "Возвращено"
        // 'closed' — деньги покупателю фактически выплачены (наличными на кассе
        // или переводом; продавец подтвердил выплату). Раньше это слово
        // показывалось человеку как есть, латиницей.
        case "closed":   return "Деньги выплачены"
        default:         return (s?.isEmpty ?? true) ? "—" : (s ?? "—")
        }
    }
    /// Kind для StatusPill (цвет по семантике).
    static func pillKind(_ s: String?) -> StatusPill.Kind {
        switch (s ?? "").lowercased() {
        case "approved", "refunded", "closed": return .done
        case "rejected":             return .cancel
        default:                     return .pending
        }
    }
}

/// Причина возврата (reason_code) — коды строго из белого списка сервера
/// (core/api_v1.php: wrong_item / bad_quality / not_delivered / changed_mind / other).
struct ReturnReason: Identifiable, Hashable {
    let code: String
    let label: String
    var id: String { code }
}
private let returnReasons: [ReturnReason] = [
    .init(code: "bad_quality",   label: "Плохое качество"),
    .init(code: "wrong_item",    label: "Привезли не то"),
    .init(code: "not_delivered", label: "Не доставлено"),
    .init(code: "changed_mind",  label: "Передумал(а)"),
    .init(code: "other",         label: "Другое"),
]

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - ViewModel
// ─────────────────────────────────────────────────────────────────────────────

@MainActor
final class ReturnsViewModel: ObservableObject {
    @Published var items: [ReturnItem] = []
    @Published var loading = true
    @Published var loadFailed = false
    private var didLoad = false

    func firstLoad() async { guard !didLoad else { return }; didLoad = true; await load() }

    func load() async {
        loading = true; loadFailed = false
        do {
            items = try await API.shared.list("api/v1/returns")
        } catch is CancellationError {
            // Отмену обновления жестом не показываем как ошибку (см. OrdersView).
        } catch {
            loadFailed = true
        }
        loading = false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Экран
// ─────────────────────────────────────────────────────────────────────────────

struct ReturnsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = ReturnsViewModel()
    @State private var showForm = false

    var body: some View {
        ZStack(alignment: .bottom) {
            content
            // Кнопка «Оформить возврат» — закреплена снизу (доступна всегда, кроме гостя).
            if session.isLoggedIn {
                bottomBar
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Возвраты")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showForm, onDismiss: { Task { await vm.load() } }) {
            ReturnCreateView()
        }
        .task { if session.isLoggedIn { await vm.firstLoad() } }
    }

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            emptyState(icon: "person.crop.circle.badge.questionmark",
                       title: "Войдите в аккаунт",
                       hint: "Чтобы оформлять возвраты и следить за их статусом.")
        } else if vm.loading && vm.items.isEmpty {
            ScrollView {
                VStack(spacing: YMSpace.md) {
                    ForEach(0..<3, id: \.self) { _ in
                        SkeletonBox(radius: YMRadius.card).frame(height: 96)
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.sm)
            }
        } else if vm.loadFailed && vm.items.isEmpty {
            errorState
        } else if vm.items.isEmpty {
            emptyState(icon: "arrow.uturn.backward.circle",
                       title: "Заявок на возврат нет",
                       hint: "Оформить возврат можно по выполненному заказу — нажмите «Оформить возврат».")
        } else {
            ScrollView {
                LazyVStack(spacing: YMSpace.md) {
                    // Перечитать не удалось (после новой заявки, жестом), а список
                    // уже есть: раньше сбой был не виден — новой заявки «не было»,
                    // и её подавали повторно.
                    if vm.loadFailed && !vm.loading {
                        Text("Не удалось обновить список. Потяните вниз, чтобы повторить.")
                            .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(vm.items) { r in ReturnCard(item: r) }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, 96) // место под закреплённую кнопку
            }
            .refreshable { await vm.load() }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.light(); showForm = true
            } label: {
                Text("Оформить возврат")
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.md)
            .padding(.bottom, YMSpace.sm)
        }
        .background(
            YMColor.bg.opacity(0.96)
                .overlay(alignment: .top) { Rectangle().fill(YMColor.hairline).frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private var errorState: some View {
        VStack(spacing: YMSpace.lg) {
            Text("⚠️").font(.system(size: 44))
            Text("Не удалось загрузить возвраты")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Проверьте соединение и попробуйте ещё раз.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button { Task { await vm.load() } } label: {
                Text("Повторить").font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xxl).padding(.vertical, 12)
                    .background(YMColor.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
        .padding(.top, 72)
    }

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: YMSpace.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(YMColor.surface2).frame(width: 96, height: 96)
                Image(systemName: icon)
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
            }
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(hint)
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, YMSpace.xxxl)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 64)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Карточка возврата
// ─────────────────────────────────────────────────────────────────────────────

/// Карточка заявки: № заказа, статус-pill, магазин, сумма к возврату, дата.
private struct ReturnCard: View {
    let item: ReturnItem
    /// А111: по нажатию — что возвращают (GET api/profile/returns/{id}: items, order_number).
    @State private var open = false
    @State private var detail: ReturnDetail?
    @State private var detailLoading = false
    @State private var detailFailed = false

    private var title: String {
        // П-23.3: номер за день — тот, что клиент видит в заказах.
        // П-24 №1 (А62): номер за день повторяется каждый день — рядом дата
        // заказа (order_created_at). Нет поля (старый сервер) — как раньше.
        // А111: order_number карточки заявки — тот же номер, если список его не дал.
        if let n = item.orderDailyNumber ?? detail?.orderNumber, n > 0 {
            guard let d = DateFmt.day(item.orderCreatedAt) else { return "Заказ №\(n)" }
            return "Заказ №\(n) от \(d)"
        }
        if let oid = item.orderId, oid > 0 { return "Заказ №\(oid)" }
        return "Возврат №\(item.id)"
    }
    private var refund: String? {
        guard let a = item.refundAmount else { return nil }
        return Money.format(Money.parse(a))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(1)
                Spacer(minLength: 8)
                StatusPill(text: ReturnStatus.label(item.status),
                           kind: ReturnStatus.pillKind(item.status),
                           solid: false)
            }
            if let shop = item.shop, !shop.isEmpty {
                Text(shop).font(YMFont.caption).foregroundStyle(YMColor.muted).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                if let refund {
                    Text("К возврату: \(refund)")
                        .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                }
                Spacer(minLength: 8)
                Text(DateFmt.short(item.createdAt))
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            if open { detailBlock }
            Text(open ? "Скрыть состав" : "Что возвращаете")
                .font(YMFont.caption.weight(.semibold)).foregroundStyle(YMColor.accent)
        }
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.light()
            open.toggle()
            if open && detail == nil && !detailLoading { Task { await loadDetail() } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(ReturnStatus.label(item.status))\(refund.map { ", к возврату \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(open ? "Скрыть состав заявки" : "Показать, что возвращаете")
    }

    /// Строки «что возвращаете»: без названия и с нулевым количеством не показываем.
    private var detailLines: [ReturnDetailLine] {
        (detail?.items ?? []).filter { !($0.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty && ($0.qty ?? 0) > 0.0005 }
    }

    @ViewBuilder private var detailBlock: some View {
        if detailLoading {
            Text("Загружаем состав…").font(YMFont.caption).foregroundStyle(YMColor.muted)
        } else if detailFailed {
            Button { Task { await loadDetail() } } label: {
                Text("Не удалось загрузить состав — нажмите, чтобы повторить")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.plain)
        } else if !detailLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Что возвращаете").font(YMFont.caption).foregroundStyle(YMColor.muted)
                ForEach(Array(detailLines.enumerated()), id: \.offset) { _, l in
                    HStack(alignment: .firstTextBaseline, spacing: YMSpace.sm) {
                        Text((l.name ?? "") + " × " + fmtQty(l.qty ?? 0))
                            .font(YMFont.callout).foregroundStyle(YMColor.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let p = l.price {
                            Text(Money.format(p)).font(YMFont.callout).foregroundStyle(YMColor.muted)
                        }
                    }
                }
            }
        } else if detail != nil {
            // Старый сервер (полей нет) или состав не записан.
            Text(item.type == "partial" ? "Состав заявки не указан" : "Возврат всего заказа")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
    }

    private func loadDetail() async {
        detailLoading = true; detailFailed = false
        do {
            let d: ReturnDetail = try await API.shared.get("api/profile/returns/\(item.id)")
            detail = d
        } catch is CancellationError {
        } catch {
            detailFailed = true
        }
        detailLoading = false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Оформление возврата (форма)
// ─────────────────────────────────────────────────────────────────────────────

/// Форма: выбор выполненного заказа + тип + причина + комментарий → POST api/v1/returns.
/// Заказы берём из GET api/v1/orders и оставляем только выполненные (done/delivered/completed) —
/// сервер всё равно примет только status='done', так пользователь не бьётся об 422.
struct ReturnCreateView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var orders: [Order] = []
    @State private var loadingOrders = true
    @State private var ordersError: String?
    @State private var selectedOrderId: Int?
    /// А111: позиции выбранного заказа (GET api/v1/orders/{id}) и «сколько вернуть»
    /// у каждой (ключ — order_items.id). По умолчанию — всё: возврат всего заказа,
    /// как раньше. Состав не загрузился — тоже возврат всего заказа.
    @State private var orderLines: [OrderItem] = []
    @State private var backQty: [Int: Double] = [:]
    @State private var linesLoading = false
    /// Состав не загрузился — «Повторить»; отправка тогда — возврат всего заказа.
    @State private var linesFailed = false
    /// Номер последней загрузки состава: поздний ответ прежней (A→B→A) не
    /// сбрасывает выставленные количества.
    @State private var linesToken = 0
    /// Последняя отправка точно не ушла (нет связи) — текст «Нет связи», а не «Ответ не дошёл».
    @State private var notSent = false
    /// Тело последней отправки: при «Закрыть» с неизвестным исходом забываем его ключ повтора.
    @State private var lastBody: ReturnCreateBody?
    /// Одна из прошлых отправок могла дойти до сервера (ответа не было, но запрос ушёл).
    @State private var mayHaveSent = false
    /// Ответ на отправку не дошёл (сеть, таймаут, 5xx): повтор — тем же ключом и
    /// тем же телом, поэтому заказ, позиции, причину и комментарий не меняем.
    @State private var outcomeUnknown = false
    @State private var reasonCode = returnReasons.first!.code
    @State private var comment = ""
    @State private var sending = false
    @State private var done = false
    @State private var error: String?
    /// Можно ли вернуть выбранный заказ (GET orders/{id}/return-eligibility):
    /// срок, активная заявка, всё ли уже возвращено. nil — ещё проверяем/не знаем.
    @State private var eligibility: ReturnEligibility?

    private var eligibleOrders: [Order] {
        // Записи на услуги и брони — не возвращаются как товар.
        orders.filter { OrderFlow.isDone($0.status) && $0.isAppointment != true }
    }
    private var locked: Bool { sending || outcomeUnknown }
    /// А115: сервер прислал returnable_qty (сколько ещё можно вернуть). Нет поля
    /// (старый сервер) — максимум в форме всё купленное, как раньше.
    private var serverKnowsReturned: Bool { orderLines.contains { $0.returnableQty != nil } }
    /// Хотя бы у одной позиции выбрано меньше её максимума — частичный возврат.
    /// По каждой позиции выбран максимум (returnable_qty, без поля — купленное) —
    /// «весь заказ» (type=full), как «Весь заказ» на сайте (cabinet.js): сервер
    /// вернёт остаток заказа, включая доставку (returnBuild в core/helpers.php).
    private var isPartial: Bool {
        orderLines.contains { l in (backQty[l.lineId ?? 0] ?? returnMax(l)) < returnMax(l) - 0.0005 }
    }
    /// Что уходит при частичном возврате: позиции с ненулевым количеством.
    private var pickedLines: [ReturnLineBody] {
        orderLines.compactMap { l in
            guard let id = l.lineId else { return nil }
            let q = (min(backQty[id] ?? returnMax(l), returnMax(l)) * 1000).rounded() / 1000
            return q > 0.0005 ? ReturnLineBody(itemId: id, qty: q) : nil
        }
    }
    /// А115: всё уже возвращено или ждёт решения магазина — вернуть нечего.
    private var nothingReturnable: Bool {
        serverKnowsReturned && !orderLines.isEmpty && orderLines.allSatisfy { returnMax($0) <= 0.0005 }
    }
    private var nothingPicked: Bool { isPartial && pickedLines.isEmpty }
    private var canSubmit: Bool {
        // Исход неизвестен — повтор сохранённым телом, поля формы не важны.
        if outcomeUnknown { return !sending && lastBody != nil }
        // Пока состав грузится — не отправляем: ушёл бы «весь заказ» вместо выбранного.
        return selectedOrderId != nil && !sending && !linesLoading && eligibility?.eligible != false && !nothingPicked
            && !nothingReturnable
    }
    private var ineligibleText: String {
        let r = (eligibility?.reason ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return r.isEmpty ? "Этот заказ вернуть нельзя" : r
    }
    /// «1 234 ₽ · 12 окт, 14:05» — дата заказа вместо статуса: здесь все заказы
    /// выполнены («Выполнен» у каждого), а номер за день повторяется, и без
    /// даты два «Заказа №3» было не различить.
    private func orderSubtitle(_ o: Order) -> String {
        let money = Money.format(Money.parse(o.total))
        guard let raw = o.createdAt, !raw.isEmpty else {
            return money + " · " + OrderStatus.label(o.status, shopType: o.shopType)
        }
        // Как в карточке заказа — в поясе телефона и со временем.
        return money + " · " + DateFmt.short(raw)
    }

    var body: some View {
        NavigationStack {
            Group {
                if done { successState } else { form }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(done ? "" : "Оформить возврат")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !done {
                    ToolbarItem(placement: .cancellationAction) {
                        // Пока запрос идёт — закрыть нельзя. Исход неизвестен, а запрос
                        // не идёт — «Закрыть»: иначе без сети окно не закрылось бы
                        // никогда. Дубля сервер не допустит (одна активная заявка на
                        // заказ, returnBuild → 409), ключ этого тела забываем.
                        Button(outcomeUnknown ? "Закрыть" : "Отмена") { closeForm() }.tint(YMColor.accent)
                            .disabled(sending)
                    }
                }
            }
        }
        .tint(YMColor.accent)
        // Пока заявка уходит, окно не закрывается: закрытое смахиванием прятало
        // итог (успех или отказ), а список перечитывался раньше ответа — новой
        // заявки в нём не было, и человек подавал её повторно.
        // Набранную причину возврата смахивание шторки тоже не выбрасывает:
        // закрыть форму с текстом можно только кнопкой «Отмена».
        .interactiveDismissDisabled(sending || outcomeUnknown || (!done && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
        .task { await loadOrders() }
    }

    // ── Форма ──
    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.xl) {
                // Заказ
                section(title: "Заказ") {
                    if loadingOrders {
                        HStack(spacing: 8) { ProgressView().tint(YMColor.accent); Text("Загружаем заказы…").font(YMFont.callout).foregroundStyle(YMColor.muted) }
                    } else if eligibleOrders.isEmpty, let e = ordersError {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Не удалось загрузить заказы: \(e)")
                                .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                            Button("Повторить") { Task { await loadOrders() } }
                                .font(YMFont.callout.weight(.semibold)).foregroundStyle(YMColor.accent)
                        }
                    } else if eligibleOrders.isEmpty {
                        Text("Нет выполненных заказов, доступных для возврата.")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    } else {
                        VStack(spacing: YMSpace.sm) {
                            ForEach(eligibleOrders) { o in
                                SelectableRow(
                                    title: "Заказ №\(o.dailyNumber ?? o.id)" + (o.shopName.map { " · \($0)" } ?? ""),
                                    subtitle: orderSubtitle(o),
                                    selected: selectedOrderId == o.id
                                ) {
                                    guard selectedOrderId != o.id else { return }
                                    Haptics.light(); selectedOrderId = o.id
                                    Task { await checkEligibility(o.id) }
                                    Task { await loadLines(o.id) }
                                }
                            }
                        }
                        .disabled(locked)
                        // Раньше о сроке/активной заявке человек узнавал только
                        // после отправки формы. Причину показываем сразу.
                        if eligibility?.eligible == false {
                            // reason по контракту — всегда строка: пустая давала
                            // красную пустую строку вместо объяснения.
                            Text(ineligibleText)
                                .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // А111: что возвращаете — «сколько вернуть» у каждой позиции.
                // Всё на максимуме — возврат всего заказа (type=full, как раньше);
                // меньше хотя бы у одной — type=partial с items [{item_id, qty}].
                // Раньше «Частичный» уходил без позиций, и сервер заводил заявку на 0 ₽.
                if linesLoading {
                    section(title: "Что возвращаете") {
                        HStack(spacing: 8) { ProgressView().tint(YMColor.accent); Text("Загружаем состав заказа…").font(YMFont.callout).foregroundStyle(YMColor.muted) }
                    }
                } else if linesFailed {
                    section(title: "Что возвращаете") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Не удалось загрузить состав — заявка уйдёт на весь заказ")
                                .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Повторить") { if let id = selectedOrderId { Task { await loadLines(id) } } }
                                .font(YMFont.callout.weight(.semibold)).foregroundStyle(YMColor.accent)
                                .disabled(locked)
                        }
                    }
                } else if !orderLines.isEmpty {
                    section(title: "Что возвращаете") {
                        VStack(alignment: .leading, spacing: YMSpace.sm) {
                            ForEach(orderLines) { l in
                                ReturnQtyRow(line: l, maxQty: returnMax(l),
                                             qty: backQty[l.lineId ?? 0] ?? returnMax(l)) { q in
                                    if let id = l.lineId { backQty[id] = q }
                                }
                            }
                            .disabled(locked)
                            if nothingReturnable {
                                // А115: у всех позиций returnable_qty = 0 — отправлять нечего.
                                Text("Вернуть нечего: всё уже возвращено или ждёт решения магазина")
                                    .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                // Про «уже возвращённую часть» — только старому серверу: новый
                                // сам прислал остаток, и максимум в форме уже он.
                                Text(serverKnowsReturned
                                     ? "Уменьшите количество, если возвращаете не всё. Сумму к возврату рассчитает магазин."
                                     : "Уменьшите количество, если возвращаете не всё. Если часть уже возвращена, вернуть можно только остаток. Сумму к возврату рассчитает магазин.")
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if nothingPicked && !nothingReturnable {
                                Text("Укажите, что возвращаете")
                                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            }
                        }
                    }
                }

                // Причина
                section(title: "Причина") {
                    VStack(spacing: YMSpace.sm) {
                        ForEach(returnReasons) { r in
                            SelectableRow(title: r.label, subtitle: nil, selected: reasonCode == r.code) {
                                Haptics.light(); reasonCode = r.code
                            }
                        }
                    }
                    .disabled(locked)
                }

                // Комментарий
                section(title: "Комментарий (необязательно)") {
                    TextField("Опишите проблему…", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                        // Причину сервер хранит до 500 символов и лишнее режет
                        // молча (POST api/v1/returns, reason_text в api_v1.php).
                        .ymMaxLength($comment, 500)
                        .disabled(locked)
                        .font(YMFont.body)
                        .padding(YMSpace.md)
                        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                }

                if let error {
                    Text(error)
                        .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if outcomeUnknown && !sending {
                    Text(notSent
                         ? (mayHaveSent
                            ? "Нет связи — повторите, когда появится интернет. Заявка могла уйти — проверьте список заявок."
                            : "Нет связи — проверьте интернет и повторите. Пока заявка не отправлена, изменить её нельзя.")
                         : "Ответ не дошёл — нажмите «Повторить отправку»: заявка не задвоится. Заявка могла уйти — если закроете окно, проверьте список заявок.")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(action: send) {
                    HStack { if sending { ProgressView().tint(YMColor.onAccent) } else { Text(outcomeUnknown ? "Повторить отправку" : "Отправить заявку") } }
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(!canSubmit)
                .opacity(canSubmit ? 1 : 0.5)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.vertical, YMSpace.lg)
        }
        // Комментарий многострочный: «Ввод» — новая строка, клавиатуру было не
        // убрать, и она закрывала «Отправить заявку». Теперь жестом прокрутки.
        .scrollDismissesKeyboard(.interactively)
    }

    // ── Успех ──
    private var successState: some View {
        VStack(spacing: YMSpace.lg) {
            ZStack {
                Circle().fill(YMColor.statusDone.opacity(0.16)).frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 40, weight: .heavy)).foregroundStyle(YMColor.statusDone)
            }
            Text("Заявка отправлена").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Продавец рассмотрит возврат. Статус появится в списке возвратов.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center).padding(.horizontal, YMSpace.xxxl)
            Button { dismiss() } label: { Text("Готово") }
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.horizontal, YMSpace.xl).padding(.top, YMSpace.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func section<C: View>(title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text(title).font(YMFont.subhead).foregroundStyle(YMColor.muted)
            content()
        }
    }

    private func loadOrders() async {
        loadingOrders = true; ordersError = nil
        // Раньше бралась только первая страница заказов: у постоянного
        // покупателя более старый, но ещё возвращаемый заказ был недоступен.
        // А сбой сети выглядел как «нет выполненных заказов» без повтора.
        var all: [Order] = []
        do {
            var page = 1
            while page <= 5 {
                let p: Page<Order> = try await API.shared.page("api/v1/orders", query: ["page": String(page)])
                all += p.items
                if !p.hasMore || p.items.isEmpty { break }
                page += 1
            }
        } catch is CancellationError {
            return
        } catch {
            if all.isEmpty { ordersError = error.localizedDescription }
        }
        var seen = Set<Int>()
        orders = all.filter { seen.insert($0.id).inserted }
        if selectedOrderId == nil { selectedOrderId = eligibleOrders.first?.id }
        loadingOrders = false
        if let id = selectedOrderId {
            async let lines: Void = loadLines(id)
            await checkEligibility(id)
            await lines
        }
    }

    /// А111: позиции заказа для «сколько вернуть». Подарки (цена 0) не показываем;
    /// строки без order_items.id (старый сервер) — тоже: вернуть их частично нельзя.
    /// Не загрузилось — позиций нет, возврат всего заказа, как раньше.
    private func loadLines(_ id: Int) async {
        // Исход отправки неизвестен — состав не перечитываем: повтор идёт сохранённым телом.
        guard !outcomeUnknown, !sending else { return }
        linesToken += 1
        let token = linesToken
        orderLines = []; backQty = [:]
        linesLoading = true; linesFailed = false
        let d: OrderDetail?
        do { d = try await API.shared.get("api/v1/orders/\(id)") }
        catch {
            // Отмена (ушли с экрана) — тоже «не загрузилось», а не «состав пуст»:
            // иначе заявка молча ушла бы на весь заказ. «Повторить» перечитает.
            guard token == linesToken else { return }
            linesFailed = true; linesLoading = false
            return
        }
        // Пока ждали ответ, человек выбрал другой заказ (или тот же заново) — не перетираем.
        guard token == linesToken, selectedOrderId == id else { return }
        let ls = (d?.items ?? []).filter { ($0.lineId ?? 0) > 0 && ($0.qty ?? 0) > 0.0005 && ($0.price ?? 0) > 0.0049 }
        var q: [Int: Double] = [:]
        // По умолчанию — всё, что ещё можно вернуть (А115: returnable_qty).
        for l in ls { if let lid = l.lineId { q[lid] = returnMax(l) } }
        backQty = q
        orderLines = ls
        linesLoading = false
    }

    /// А115: максимум «сколько вернуть» по позиции — returnable_qty сервера
    /// (0…купленное); нет поля (старый сервер) — всё купленное, как раньше.
    private func returnMax(_ l: OrderItem) -> Double {
        let bought = l.qty ?? 0
        guard let r = l.returnableQty else { return bought }
        return min(bought, max(0, (r * 1000).rounded() / 1000))
    }

    /// «Отмена» / «Закрыть». После неизвестного исхода ключ этого тела забываем:
    /// следующая заявка — новое действие. Список заявок перечитает onDismiss листа.
    private func closeForm() {
        guard !sending else { return }
        if outcomeUnknown, let b = lastBody { API.shared.forgetRetryKey("api/v1/returns", body: b) }
        dismiss()
    }

    private func checkEligibility(_ id: Int) async {
        eligibility = nil
        let r: ReturnEligibility? = try? await API.shared.get("api/v1/orders/\(id)/return-eligibility")
        // Пока ждали ответ, человек мог выбрать другой заказ — не перетираем.
        if selectedOrderId == id { eligibility = r }
    }

    private func send() {
        // Двойное нажатие до перерисовки создавало две заявки на возврат
        // (вторая отказом «уже есть активная заявка» затирала успех).
        guard canSubmit else { return }
        let body: ReturnCreateBody
        if outcomeUnknown, let saved = lastBody {
            // Повтор неотвеченной отправки — ровно то же тело (тот же ключ повтора).
            body = saved
        } else {
            guard let orderId = selectedOrderId else { return }
            let partial = isPartial
            body = ReturnCreateBody(orderId: orderId, type: partial ? "partial" : "full", reasonCode: reasonCode,
                                    reasonText: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? nil : comment.trimmingCharacters(in: .whitespacesAndNewlines),
                                    items: partial ? pickedLines : nil)
            mayHaveSent = false
        }
        sending = true; error = nil
        lastBody = body
        Task {
            do {
                // П-27.14: ключ повтора — после обрыва связи повтор получает ответ
                // первого запроса, а не «уже есть заявка».
                try await API.shared.postVoid("api/v1/returns", body: body, retryKey: true)
                await MainActor.run { Haptics.success(); sending = false; outcomeUnknown = false; done = true }
            } catch is CancellationError {
                await MainActor.run { sending = false; outcomeUnknown = true; notSent = false; mayHaveSent = true }
            } catch {
                // Ключ повтора держится, пока ответа нет (RetryKeys.keepAfter) — до тех пор
                // форма не правится, иначе другое тело ушло бы с новым ключом.
                let unknown = RetryKeys.keepAfter(error)
                var offline = false
                if case .notConnected? = error as? APIError { offline = true }
                let wasNotSent = offline
                await MainActor.run {
                    self.error = error.localizedDescription; sending = false
                    outcomeUnknown = unknown; notSent = wasNotSent
                    if unknown && !wasNotSent { mayHaveSent = true }
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - А111: позиция заказа и «сколько вернуть»
// ─────────────────────────────────────────────────────────────────────────────

/// «Сколько вернуть» (0…купленное). Шаг — 1 шт., у весовых (дробное количество,
/// кг, л) — 0,1; последний шаг вверх упирается в купленное. Как Android (ReturnQtyRow).
/// А115: maxQty — сколько ещё можно вернуть (returnable_qty); 0 — строка серая,
/// без кнопок: «уже возвращено» / «ждёт решения магазина».
private struct ReturnQtyRow: View {
    let line: OrderItem
    let maxQty: Double
    let qty: Double
    let onQty: (Double) -> Void

    private var bought: Double { line.qty ?? 0 }
    private var exhausted: Bool { maxQty <= 0.0005 }
    /// Подпись под «Куплено»: что уже вернули или что ждёт решения (только новый сервер).
    private var returnedNote: String? {
        guard line.returnableQty != nil else { return nil }
        let done = line.returnQty ?? 0
        let wait = line.returnPendingQty ?? 0
        if exhausted {
            if wait > 0.0005 && done > 0.0005 { return "Часть возвращена, остальное ждёт решения магазина" }
            if wait > 0.0005 { return "Ждёт решения магазина" }
            return "Уже возвращено"
        }
        guard maxQty < bought - 0.0005 else { return nil }
        return "Можно вернуть: " + fmtQty(maxQty, unitLabel)
    }
    private var unitLabel: String {
        let u = (line.unit ?? "").trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? "шт" : u
    }
    private var step: Double {
        let u = (line.unit ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        // Дробный максимум (куплено 2, вернули 0,5 → можно 1,5) — тоже шаг 0,1, как Android.
        let fractional = abs(bought - bought.rounded()) > 0.0005 || abs(maxQty - maxQty.rounded()) > 0.0005
            || u == "кг" || u == "л"
        return fractional ? 0.1 : 1
    }
    private func snap(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }

    var body: some View {
        let canMinus = qty > 0.0005
        let canPlus = qty < maxQty - 0.0005
        HStack(spacing: YMSpace.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text((line.name ?? "").isEmpty ? "Позиция" : (line.name ?? ""))
                    .font(YMFont.callout).foregroundStyle(exhausted ? YMColor.muted : YMColor.text).lineLimit(2)
                Text("Куплено: " + fmtQty(bought, unitLabel))
                    .font(YMFont.caption2).foregroundStyle(YMColor.muted)
                if let note = returnedNote {
                    Text(note)
                        .font(YMFont.caption2).foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if !exhausted { stepper(canMinus: canMinus, canPlus: canPlus) }
        }
        .padding(.horizontal, YMSpace.md).padding(.vertical, YMSpace.sm)
        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
        .opacity(exhausted ? 0.6 : 1)
    }

    @ViewBuilder private func stepper(canMinus: Bool, canPlus: Bool) -> some View {
        Button { Haptics.light(); onQty(snap(max(0, qty - step))) } label: {
            Image(systemName: "minus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(canMinus ? YMColor.accent : YMColor.muted)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!canMinus)
        .accessibilityLabel("Вернуть меньше")
        Text(fmtQty(qty, unitLabel))
            .font(YMFont.callout.weight(.semibold)).foregroundStyle(YMColor.text)
            .frame(minWidth: 52)
        Button { Haptics.light(); onQty(snap(min(maxQty, qty + step))) } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(canPlus ? YMColor.accent : YMColor.muted)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(!canPlus)
        .accessibilityLabel("Вернуть больше")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Выбираемая строка (заказ / причина)
// ─────────────────────────────────────────────────────────────────────────────

/// Строка с золотой рамкой + галочка при выборе (стиль ProfileDetail SelectableRow).
private struct SelectableRow: View {
    let title: String
    var subtitle: String?
    let selected: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: YMSpace.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(YMFont.callout).foregroundStyle(YMColor.text).lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(YMFont.caption2).foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if selected {
                    ZStack {
                        Circle().fill(YMColor.accent).frame(width: 22, height: 22)
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .heavy)).foregroundStyle(YMColor.onAccent)
                    }
                }
            }
            .padding(YMSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? YMColor.accent.opacity(0.12) : YMColor.surface2,
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
