//
//  ReturnsView.swift — Возвраты (премиум iOS-клиент Yumurta)
//
//  Экран «Возвраты»: список заявок + оформление возврата.
//  Точка входа: ReturnsView() (навигацию/пуш решает вызывающая сторона).
//
//  ПРИВЯЗКА К API (реальные пути, сверено по core/api_v1.php):
//    • GET  api/v1/returns                                → [ReturnItem]
//        поля: id, order_id, type, reason_code, status, refund_amount, created_at, shop
//    • POST api/v1/returns  ← ReturnCreateBody(order_id,type,reason_code,reason_text)
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

    private var title: String {
        // П-23.3: номер за день — тот, что клиент видит в заказах.
        // П-24 №1 (А62): номер за день повторяется каждый день — рядом дата
        // заказа (order_created_at). Нет поля (старый сервер) — как раньше.
        if let n = item.orderDailyNumber, n > 0 {
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
        }
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(ReturnStatus.label(item.status))\(refund.map { ", к возврату \($0)" } ?? "")")
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
    /// Только полный возврат: выбора позиций в форме нет (см. комментарий ниже).
    private let type = "full"
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
    private var canSubmit: Bool { selectedOrderId != nil && !sending && eligibility?.eligible != false }
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
                        Button("Отмена") { dismiss() }.tint(YMColor.accent)
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
        .interactiveDismissDisabled(sending || (!done && !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
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
                                ) { Haptics.light(); selectedOrderId = o.id; Task { await checkEligibility(o.id) } }
                            }
                        }
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

                // Тип возврата: только полный.
                //
                // Переключатель «Частичный» здесь был, а выбора позиций — нет:
                // тело запроса не несло ни items, ни суммы, и сервер заводил
                // заявку на 0 ₽. Человек видел «Заявка отправлена», в списке
                // появлялось «К возврату: 0 ₽», продавец одобрял ноль.
                // Вернуть переключатель можно вместе с выбором позиций заказа.

                // Причина
                section(title: "Причина") {
                    VStack(spacing: YMSpace.sm) {
                        ForEach(returnReasons) { r in
                            SelectableRow(title: r.label, subtitle: nil, selected: reasonCode == r.code) {
                                Haptics.light(); reasonCode = r.code
                            }
                        }
                    }
                }

                // Комментарий
                section(title: "Комментарий (необязательно)") {
                    TextField("Опишите проблему…", text: $comment, axis: .vertical)
                        .lineLimit(3...6)
                        // Причину сервер хранит до 500 символов и лишнее режет
                        // молча (POST api/v1/returns, reason_text в api_v1.php).
                        .ymMaxLength($comment, 500)
                        .font(YMFont.body)
                        .padding(YMSpace.md)
                        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                }

                if let error {
                    Text(error)
                        .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(action: send) {
                    HStack { if sending { ProgressView().tint(YMColor.onAccent) } else { Text("Отправить заявку") } }
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
        if let id = selectedOrderId { await checkEligibility(id) }
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
        guard let orderId = selectedOrderId, canSubmit else { return }
        sending = true; error = nil
        let body = ReturnCreateBody(orderId: orderId, type: type, reasonCode: reasonCode,
                                    reasonText: comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                        ? nil : comment.trimmingCharacters(in: .whitespacesAndNewlines))
        Task {
            do {
                // П-27.14: ключ повтора — после обрыва связи повтор получает ответ
                // первого запроса, а не «уже есть заявка».
                try await API.shared.postVoid("api/v1/returns", body: body, retryKey: true)
                await MainActor.run { Haptics.success(); sending = false; done = true }
            } catch {
                await MainActor.run { self.error = error.localizedDescription; sending = false }
            }
        }
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
