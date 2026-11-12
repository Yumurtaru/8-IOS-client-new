import SwiftUI

//
//  GroupCartView.swift — экран «Общий заказ» (П-72 п.3).
//
//  Одна корзина на компанию: владелец создаёт заказ в заведении, шлёт ссылку, каждый
//  участник собирает свои позиции, платит владелец. Single-store сохраняется: общий
//  заказ привязан к одному заведению.
//
//  Выбор по правке своих позиций (простой и надёжный): «Изменить мои позиции» берёт
//  ТЕКУЩУЮ корзину приложения (если она из этого заведения) и целиком отправляет
//  PUT items — так же работает перенос при создании. Пустая корзина = убрать свои позиции.
//  Свою корзину человек наполняет обычным способом (меню заведения), отдельного
//  редактора позиций внутри экрана нет — меньше расхождений с ценами и добавками.
//
//  «Оформить» (владелец): состав всех участников кладётся в корзину приложения, дальше —
//  обычный CheckoutView с groupCode: тело заказа собирается им же (адрес, оплата, баллы,
//  промокод), уходит на api/v1/group-carts/{code}/checkout.
//
//  Обновление: pull-to-refresh, авто каждые ~10 с пока экран виден, по push group_cart.
//

extension Notification.Name {
    /// Push type=group_cart: object — [code, event].
    static let ymGroupCartPushed = Notification.Name("ym.groupCartPushed")
}

/// Последний открытый общий заказ — чтобы вернуться к нему из корзины.
enum GroupCartMemory {
    private static let key = "groupCartLastCode"
    static var lastCode: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Какой общий заказ оформляет неотвеченный заказ с этим ключом повтора: повтор после
/// обрыва связи должен уйти на тот же адрес (group-carts/{code}/checkout), а не в /orders.
enum GroupCheckoutMemo {
    private static let prefix = "groupCheckout."
    static func code(for key: String) -> String? { UserDefaults.standard.string(forKey: prefix + key) }
    static func set(_ code: String, for key: String) { UserDefaults.standard.set(code, forKey: prefix + key) }
    static func clear(_ key: String) { UserDefaults.standard.removeObject(forKey: prefix + key) }
}

extension GroupCartText {
    /// Текст по `event` push (joined | locked | ordered | cancelled).
    static func eventText(_ event: String?) -> String? {
        switch event {
        case "joined":    return "К общему заказу присоединился участник"
        case "locked":    return "Общий заказ закрыт для правок"
        case "ordered":   return "Общий заказ оформлен"
        case "cancelled": return "Общий заказ отменён"
        default:          return nil
        }
    }
}

@MainActor
final class GroupCartViewModel: ObservableObject {
    let code: String
    @Published var group: GroupCart?
    @Published var loading = true
    @Published var loadError: String?
    @Published var busy = false
    @Published var actionError: String?
    @Published var toast: String?
    private var triedJoin = false

    init(code: String) { self.code = code }

    /// Гость: грузить нечего, показываем «Войти».
    func markGuest() { loading = false }

    func load(silent: Bool = false) async {
        if !silent { loading = true }
        defer { loading = false }
        do {
            var g = try await GroupCartAPI.get(code)
            // Открыли по ссылке и ещё не участник — присоединяемся (идемпотентно).
            if !g.joined, g.isOpen, !triedJoin {
                triedJoin = true
                try await GroupCartAPI.join(code)
                g = try await GroupCartAPI.get(code)
            }
            group = g
            loadError = nil
            GroupCartMemory.lastCode = code
        } catch is CancellationError {
        } catch {
            let notFound = (error as? APIError)?.errorCode == "not_found"
            if group == nil || !silent || notFound { loadError = GroupCartText.message(error) }
            if notFound { group = nil }
        }
    }

    /// Действие над заказом: busy, ошибка текстом, затем перечитывание.
    @discardableResult
    func run(_ work: () async throws -> Void) async -> Bool {
        busy = true; actionError = nil
        defer { busy = false }
        do {
            try await work()
            await load(silent: true)
            return true
        } catch is CancellationError {
            return false
        } catch {
            actionError = GroupCartText.message(error)
            await load(silent: true)
            return false
        }
    }
}

struct GroupCartView: View {
    let code: String
    var onClose: () -> Void

    @StateObject private var vm: GroupCartViewModel
    @ObservedObject private var session = Session.shared
    @ObservedObject private var cart = Cart.shared
    @EnvironmentObject private var coord: NavCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private enum Step: Hashable { case checkout, success }
    @State private var path: [Step] = []
    @State private var result: OrderCreateResult?
    @State private var showAuth = false
    @State private var confirm: Confirm?
    @State private var pushBanner: String?
    /// Прежняя корзина владельца: на время оформления группы её заменяют позиции участников.
    /// Не оформили заказ — возвращаем (иначе в корзине остались бы чужие позиции).
    @State private var backup: CartBackup?

    private struct CartBackup {
        let lines: [CartLine]; let shopId: Int?; let shopName: String?; let shopSlug: String?
    }

    /// Одно подтверждение на экран (confirmationDialog — не sheet, но так проще).
    private enum Confirm: Identifiable {
        case replaceMine, cancelGroup, leave, replaceCart
        var id: Int { hashValue }
    }

    init(code: String, onClose: @escaping () -> Void) {
        self.code = code
        self.onClose = onClose
        _vm = StateObject(wrappedValue: GroupCartViewModel(code: code))
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(YMColor.bg.ignoresSafeArea())
                .navigationTitle("Общий заказ")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { onClose() } }
                }
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .checkout:
                        CheckoutView(
                            onSuccess: { r in result = r; backup = nil; path.append(.success) },
                            onBack: { if !path.isEmpty { path.removeLast() } },
                            onOpenOrders: {
                                path.removeAll()
                                NavCoordinator.shared.revealForPush(closeAll: true) {
                                    DeepLinkRouter.shared.requestedTab = 3
                                }
                            },
                            groupCode: code
                        )
                    case .success:
                        successScreen.navigationBarBackButtonHidden(true)
                    }
                }
        }
        .task(id: session.isLoggedIn) {
            guard session.isLoggedIn else { await vm.markGuest(); return }
            await vm.load()
            // Авто-обновление ~10 с, пока экран виден (task отменяется при закрытии).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                if Task.isCancelled { break }
                if scenePhase == .active, path.isEmpty { await vm.load(silent: true) }
            }
        }
        .onChange(of: path) { p in
            if !p.contains(.checkout) { restoreCartIfNeeded() }
        }
        .onDisappear { restoreCartIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .ymGroupCartPushed)) { n in
            guard let a = n.object as? [String], a.first == code else { return }
            if a.count > 1, let t = GroupCartText.eventText(a[1]) { pushBanner = t }
            Task { await vm.load(silent: true) }
        }
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false })
            }
            .environmentObject(Session.shared)
        }
    }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            guestBox
        } else if vm.loading && vm.group == nil {
            VStack(spacing: YMSpace.md) { SkeletonBox().frame(height: 120); SkeletonBox().frame(height: 200) }
                .padding(YMSpace.xl)
        } else if let g = vm.group {
            ScrollView {
                VStack(spacing: YMSpace.lg) {
                    if let b = pushBanner { banner(b) }
                    headerCard(g)
                    ForEach(g.memberList) { m in memberCard(m, g) }
                    totalCard(g)
                    if let e = vm.actionError {
                        Text(e).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    actions(g)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.lg)
            }
            .refreshable { await vm.load(silent: true) }
            .confirmationDialog(confirmTitle(g), isPresented: Binding(
                get: { confirm != nil }, set: { if !$0 { confirm = nil } }
            ), titleVisibility: .visible) {
                confirmButtons(g)
            }
        } else {
            VStack(spacing: YMSpace.md) {
                ErrorRetryView(message: vm.loadError ?? "Не удалось загрузить общий заказ") {
                    Task { await vm.load() }
                }
            }
            .padding(.top, 60)
        }
    }

    private var guestBox: some View {
        VStack(spacing: YMSpace.lg) {
            Text("Войдите, чтобы присоединиться к общему заказу")
                .font(YMFont.headline).foregroundStyle(YMColor.text).multilineTextAlignment(.center)
            Button("Войти") { showAuth = true }.buttonStyle(YMPrimaryButtonStyle())
        }
        .padding(YMSpace.xl)
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(YMFont.callout).foregroundStyle(YMColor.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.md)
            .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func headerCard(_ g: GroupCart) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text(g.shop?.name ?? "Заведение").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(statusText(g)).font(YMFont.callout).foregroundStyle(YMColor.accent)
            if let o = g.owner?.name, !o.isEmpty {
                Text(g.isOwner ? "Владелец: вы" : "Владелец: \(o)").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            if let d = g.deadlineAt, !d.isEmpty, !g.isFinished {
                Text("Действует до \(DateFmt.short(d))").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func statusText(_ g: GroupCart) -> String {
        switch g.status {
        case "open":      return "Открыт — участники добавляют позиции"
        case "locked":    return "Закрыт для правок"
        case "ordered":   return "Оформлен"
        case "cancelled": return "Отменён"
        default:          return ""
        }
    }

    private func memberCard(_ m: GroupCartMember, _ g: GroupCart) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            HStack {
                Text((m.isMe ?? false) ? "Вы" : (m.name ?? "Участник"))
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                Spacer()
                if let s = m.subtotal { Text(Money.format(s)).font(YMFont.headline).foregroundStyle(YMColor.text) }
            }
            if m.itemList.isEmpty {
                Text("Пока ничего не выбрано").font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            ForEach(m.itemList) { it in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: YMSpace.sm) {
                        Text("× " + qtyText(it.qty)).font(.custom(YMFont.golosName(.heavy), fixedSize: 14)).foregroundStyle(YMColor.accent)
                        Text(it.name ?? "—").font(YMFont.body).foregroundStyle(YMColor.text)
                        Spacer(minLength: 8)
                        Text(Money.format(it.sum)).font(YMFont.body).foregroundStyle(YMColor.muted)
                    }
                    let mods = (it.modifiers ?? []).compactMap { $0.name }.joined(separator: ", ")
                    if !mods.isEmpty { Text(mods).font(YMFont.caption).foregroundStyle(YMColor.muted) }
                    if !it.isAvailable {
                        Text("Нет в наличии").font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func totalCard(_ g: GroupCart) -> some View {
        HStack {
            Text("Итого").font(YMFont.headline).foregroundStyle(YMColor.text)
            Spacer()
            Text(Money.format(g.total ?? g.memberList.reduce(Decimal(0)) { $0 + ($1.subtotal ?? 0) }))
                .font(.custom(YMFont.golosName(.heavy), fixedSize: 17)).foregroundStyle(YMColor.text)
        }
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    private func qtyText(_ q: Decimal?) -> String {
        "\(q ?? 0)".replacingOccurrences(of: ".", with: ",")
    }

    // MARK: Действия

    private var shareURL: URL? {
        let s = vm.group?.shareUrl ?? "https://yumurta.ru/g/\(code)"
        return URL(string: s)
    }

    @ViewBuilder private func actions(_ g: GroupCart) -> some View {
        VStack(spacing: YMSpace.sm) {
            if !g.isFinished, let url = shareURL {
                ShareLink(item: url, message: Text("Присоединяйтесь к общему заказу")) {
                    Text("Пригласить")
                }.buttonStyle(YMPrimaryButtonStyle())
            }
            if g.isOpen, g.joined {
                Button("Изменить мои позиции") { startReplaceMine(g) }
                    .buttonStyle(YMSecondaryButtonStyle()).disabled(vm.busy)
                Text("Добавьте блюда в корзину этого заведения и нажмите «Изменить мои позиции» — они попадут в общий заказ.")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let slug = g.shop?.slug, !slug.isEmpty {
                    Button("Открыть меню") {
                        NavCoordinator.shared.openOrg(slug: slug)
                    }.buttonStyle(YMGhostButtonStyle(color: YMColor.accent))
                }
            }
            if g.isOwner, !g.isFinished {
                Button(g.isLocked ? "Открыть" : "Закрыть для правок") {
                    let unlock = g.isLocked
                    Task {
                        await vm.run {
                            if unlock { try await GroupCartAPI.unlock(code) } else { try await GroupCartAPI.lock(code) }
                        }
                    }
                }.buttonStyle(YMSecondaryButtonStyle()).disabled(vm.busy)

                Button("Оформить") { startCheckout(g) }
                    .buttonStyle(YMPrimaryButtonStyle()).disabled(vm.busy || !canCheckout(g))
                if g.memberList.flatMap({ $0.itemList }).contains(where: { !$0.isAvailable }) {
                    Text("Есть позиции, которых нет в наличии, — попросите участников их убрать.")
                        .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("Отменить общий заказ") { confirm = .cancelGroup }
                    .buttonStyle(YMGhostButtonStyle(color: YMColor.statusCancel)).disabled(vm.busy)
            } else if !g.isOwner, g.joined, !g.isFinished {
                Button("Выйти") { confirm = .leave }
                    .buttonStyle(YMGhostButtonStyle(color: YMColor.statusCancel)).disabled(vm.busy)
            }
            if g.status == "ordered", g.isOwner, let oid = g.orderId, oid > 0 {
                Button("Следить за заказом") {
                    NavCoordinator.shared.revealForPush(closeAll: true) { coord.pendingOrderDetail = oid }
                }.buttonStyle(YMPrimaryButtonStyle())
            }
        }
    }

    private func canCheckout(_ g: GroupCart) -> Bool {
        let items = g.memberList.flatMap { $0.itemList }
        return !items.isEmpty && items.allSatisfy { $0.isAvailable }
    }

    // MARK: Свои позиции

    private func startReplaceMine(_ g: GroupCart) {
        guard let sid = g.shop?.id else { return }
        // В корзине другое заведение — по ошибке не затираем свои позиции пустотой.
        if !cart.isEmpty, cart.shopId != sid {
            vm.actionError = "В корзине другое заведение. Откройте меню «\(g.shop?.name ?? "заведения")» и добавьте блюда."
            return
        }
        confirm = .replaceMine
    }

    private func sendMine(_ g: GroupCart) {
        guard let sid = g.shop?.id else { return }
        let lines = GroupCartAPI.lines(fromCart: cart, shopId: sid)
        if let e = GroupCartAPI.limitError(lines) { vm.actionError = e; return }
        Task { await vm.run { try await GroupCartAPI.putItems(code, lines: lines) } }
    }

    // MARK: Оформление (владелец)

    private func startCheckout(_ g: GroupCart) {
        guard canCheckout(g) else { return }
        if !cart.isEmpty { confirm = .replaceCart; return }
        proceedCheckout(g)
    }

    /// Состав всех участников — в корзину приложения, дальше обычное оформление.
    private func proceedCheckout(_ g: GroupCart) {
        guard let sid = g.shop?.id else { return }
        var merged: [CartLine] = []
        for it in g.memberList.flatMap({ $0.itemList }) {
            let q = it.qtyDouble
            guard let pid = it.productId, q > 0 else { continue }
            if let i = merged.firstIndex(where: { $0.key == it.key }) {
                merged[i].qty = ((merged[i].qty + q) * 1000).rounded() / 1000
                continue
            }
            var unit = it.price ?? 0
            if it.price == nil, let lt = it.lineTotal, let qq = it.qty, qq > 0 { unit = (lt / qq).rounded(2) }
            let mods = (it.modifiers ?? []).compactMap { $0.name }.joined(separator: ", ")
            merged.append(CartLine(key: it.key, productId: pid, name: it.name ?? "", unitPrice: unit, qty: q,
                                   modifierIds: it.modifierIds, modsLabel: mods, photo: nil))
        }
        guard !merged.isEmpty else { return }
        let prev = CartBackup(lines: cart.lines, shopId: cart.shopId, shopName: cart.shopName, shopSlug: cart.shopSlug)
        guard cart.setLines(merged, shopId: sid, shopName: g.shop?.name, shopSlug: g.shop?.slug) else {
            vm.actionError = "Сначала завершите прошлое оформление в корзине"
            return
        }
        backup = prev
        path.append(.checkout)
    }

    /// Заказ не создан — возвращаем прежнюю корзину владельца. Неотвеченное оформление
    /// (исход неизвестен) не трогаем: корзина тогда заблокирована до разбора.
    private func restoreCartIfNeeded() {
        guard let b = backup, result == nil, cart.pendingOrder == nil else { return }
        backup = nil
        if let sid = b.shopId, !b.lines.isEmpty {
            cart.setLines(b.lines, shopId: sid, shopName: b.shopName, shopSlug: b.shopSlug)
        } else {
            cart.clear()
        }
    }

    // MARK: Подтверждения

    private func confirmTitle(_ g: GroupCart) -> String {
        switch confirm {
        case .replaceMine:
            return cart.isEmpty ? "Корзина пуста — ваши позиции будут убраны из общего заказа"
                                : "Ваши позиции в общем заказе будут заменены содержимым корзины"
        case .cancelGroup: return "Отменить общий заказ для всех участников?"
        case .leave:       return "Выйти из общего заказа? Ваши позиции будут убраны"
        case .replaceCart: return "Позиции всех участников заменят текущую корзину. Продолжить?"
        case .none:        return ""
        }
    }

    @ViewBuilder private func confirmButtons(_ g: GroupCart) -> some View {
        switch confirm {
        case .replaceMine:
            Button("Изменить мои позиции") { sendMine(g) }
        case .cancelGroup:
            Button("Отменить общий заказ", role: .destructive) {
                Task { if await vm.run({ try await GroupCartAPI.leaveOrCancel(code) }) { onClose() } }
            }
        case .leave:
            Button("Выйти", role: .destructive) {
                Task { if await vm.run({ try await GroupCartAPI.leaveOrCancel(code) }) { onClose() } }
            }
        case .replaceCart:
            Button("Продолжить") { proceedCheckout(g) }
        case .none:
            EmptyView()
        }
        Button("Не сейчас", role: .cancel) {}
    }

    @ViewBuilder private var successScreen: some View {
        if let r = result {
            SuccessView(
                order: r,
                onTrack: {
                    let id = r.resolvedId ?? 0
                    path.removeAll(); result = nil
                    NavCoordinator.shared.revealForPush(closeAll: true) {
                        if id > 0 { coord.pendingOrderDetail = id } else { DeepLinkRouter.shared.requestedTab = 3 }
                    }
                },
                onHome: { path.removeAll(); result = nil; onClose() }
            )
        } else {
            Color.clear.onAppear { onClose() }
        }
    }
}

/// Показ экрана общего заказа поверх вкладок по NavCoordinator.pendingGroupCode
/// (ссылка /g/{code}, yumurta://g/{code}, push group_cart, кнопка в корзине).
/// Отдельный фоновый view: у корня уже висят другие fullScreenCover/sheet, а
/// несколько презентаций на одной вью SwiftUI показывает ненадёжно.
struct GroupCartPresenter: View {
    @ObservedObject var coord: NavCoordinator

    var body: some View {
        Color.clear
            .fullScreenCover(isPresented: Binding(
                get: { coord.pendingGroupCode != nil },
                set: { if !$0 { coord.pendingGroupCode = nil } }
            )) {
                Group {
                    if let c = coord.pendingGroupCode {
                        GroupCartView(code: c, onClose: { coord.pendingGroupCode = nil }).id(c)
                    } else {
                        EmptyView()
                    }
                }
                .tint(YMColor.accent)
                .environmentObject(Cart.shared)
                .environmentObject(DeepLinkRouter.shared)
                .environmentObject(coord)
                .environmentObject(Session.shared)
            }
    }
}
