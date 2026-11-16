import SwiftUI

//  ShoppingLists.swift
//  «Купить снова» и «Мои списки покупок» (ответ сайта на П-83, пп. 3 и 10). Только для вошедшего.
//
//   • BuyAgainShelf — полка «Купить снова» (главная — без shop_id; экран заведения — с shop_id).
//     «+» идёт тем же путём, что у плитки меню: товар без обязательного выбора — сразу в корзину
//     (QuickAdd.detail → Cart.add, при чужой корзине — общий диалог конфликта), иначе карточка товара.
//   • ShoppingListsView / ShoppingListView — список списков и состав списка.
//   • SaveCartAsListButton / SaveOrderAsListButton — «Сохранить как список» (корзина → POST,
//     выполненный заказ → from-order). Ключ повтора — механизм проекта (post(retryKey: true)).
//   Логика (шаг количества, тела запросов) — ListsLogic, зеркало Android ListsLogic.kt.

// MARK: - Логика

enum ListsLogic {
    static let maxQty: Double = 9999

    /// Полка: только доступное, с id/названием/заведением; повторы (заведение+товар) убираем.
    static func cleanBuyAgain(_ list: [BuyAgainItem]) -> [BuyAgainItem] {
        var seen = Set<String>()
        var out: [BuyAgainItem] = []
        for it in list {
            guard let pid = it.productId, pid > 0, let sid = it.shopId, sid > 0,
                  it.available != false,
                  !(it.name ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if seen.insert("\(sid)-\(pid)").inserted { out.append(it) }
        }
        return out
    }

    /// Ключ строки: товар + добавки (как у корзины).
    static func lineKey(_ i: ShoppingListItem) -> String {
        "\(i.productId ?? 0)-" + (i.modifierIds ?? []).sorted().map(String.init).joined(separator: ",")
    }

    /// Шаг количества: дробный — qty_step (нет — 0,1), штучный — 1.
    static func stepOf(_ i: ShoppingListItem) -> Double {
        if i.qtyFractional == true {
            if let s = i.qtyStep, s > 0, s.isFinite { return s }
            return 0.1
        }
        return 1
    }

    /// ± на шаг; не ниже одного шага и не выше 9999 (лимит сервера).
    static func changeQty(_ items: [ShoppingListItem], key: String, dir: Int) -> [ShoppingListItem] {
        var out: [ShoppingListItem] = []
        for it in items {
            if lineKey(it) == key {
                var c = it
                let step = stepOf(it)
                let next = (((it.qty ?? 1) + Double(dir) * step) * 1000).rounded() / 1000
                c.qty = min(max(next, step), maxQty)
                out.append(c)
            } else {
                out.append(it)
            }
        }
        return out
    }

    static func remove(_ items: [ShoppingListItem], key: String) -> [ShoppingListItem] {
        items.filter { lineKey($0) != key }
    }

    /// Тело PUT items — список целиком (замена).
    static func requestItems(_ items: [ShoppingListItem]) -> [ShoppingListItemBody] {
        var out: [ShoppingListItemBody] = []
        for it in items {
            guard let pid = it.productId, pid > 0, let q = it.qty, q > 0 else { continue }
            out.append(ShoppingListItemBody(productId: pid, qty: min(q, maxQty), modifierIds: it.modifierIds ?? []))
        }
        return out
    }

    /// Текущая корзина → тело POST /shopping-lists.
    static func requestFromCart(shopId: Int, name: String, lines: [CartLine]) -> ShoppingListCreateBody {
        var items: [ShoppingListItemBody] = []
        for l in lines where l.productId > 0 && l.qty > 0 {
            items.append(ShoppingListItemBody(productId: l.productId, qty: min(l.qty, maxQty), modifierIds: l.modifierIds))
        }
        return ShoppingListCreateBody(shopId: shopId, name: name, items: items)
    }

    /// Цена позиции на экране: с добавками (unitPrice), иначе price.
    static func displayPrice(_ i: ShoppingListItem) -> Decimal { i.unitPrice ?? i.price ?? 0 }

    /// Подпись добавок под названием (нет — nil).
    static func modsLabelOf(_ i: ShoppingListItem) -> String? {
        let t = (i.modifiersLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Позиции списка → строки корзины (как «Повторить»): цена — unitPrice (нет — price), подпись — modifiersLabel,
    /// id добавок — ТОЛЬКО из modifiers, если он прислан; иначе (старый сервер) — modifierIds.
    /// Ключ — «товар-добавки» (как у обычной строки корзины), чтобы повторное добавление суммировалось.
    static func cartLines(_ items: [ShoppingListItem]) -> [CartLine] {
        var out: [CartLine] = []
        for l in items {
            guard let pid = l.productId, pid > 0 else { continue }
            let mods: [Int]
            var label = modsLabelOf(l) ?? ""
            if let sent = l.modifiers {
                mods = sent.compactMap { $0.id }.filter { $0 > 0 }
                if label.isEmpty { label = sent.compactMap { $0.name }.joined(separator: ", ") }
            } else {
                mods = l.modifierIds ?? []
            }
            let key = "\(pid)-" + mods.sorted().map(String.init).joined(separator: ",")
            var line = CartLine(key: key, productId: pid,
                                name: (l.name ?? "").isEmpty ? "Товар" : (l.name ?? "Товар"),
                                unitPrice: displayPrice(l),
                                qty: (l.qty ?? 0) > 0 ? (l.qty ?? 1) : 1,
                                modifierIds: mods, modsLabel: label, photo: l.photo)
            line.unit = l.unit
            line.qtyFractional = l.qtyFractional
            if let st = l.qtyStep, st > 0 { line.qtyStep = st }
            out.append(line)
        }
        return out
    }

    /// «1 позиция», «2 позиции», «5 позиций».
    static func positionsLabel(_ n: Int) -> String {
        let m100 = n % 100, m10 = n % 10
        let w: String
        if (11...14).contains(m100) { w = "позиций" }
        else if m10 == 1 { w = "позиция" }
        else if (2...4).contains(m10) { w = "позиции" }
        else { w = "позиций" }
        return "\(n) \(w)"
    }

    /// 2 → «2», 0.5 → «0,5», с единицей: «0,5 кг».
    static func qtyText(_ q: Double?, unit: String?) -> String {
        let v = ((q ?? 1) * 1000).rounded() / 1000
        var s = v == v.rounded() ? String(Int(v)) : String(v).replacingOccurrences(of: ".", with: ",")
        if let u = unit, !u.isEmpty { s += " \(u)" }
        return s
    }

    static func message(_ error: Error, _ fallback: String) -> String {
        (error as? LocalizedError)?.errorDescription ?? fallback
    }
}

// MARK: - «Купить снова»

@MainActor
final class BuyAgainLoader: ObservableObject {
    @Published private(set) var items: [BuyAgainItem] = []

    /// Нет данных, гость или сбой — полки нет (она необязательная); прежний список при сбое не стираем.
    func load(shopId: Int?, loggedIn: Bool) async {
        guard loggedIn else { items = []; return }
        var q: [String: String] = [:]
        if let s = shopId { q["shop_id"] = String(s) }
        do {
            let p: ListPayload<BuyAgainItem> = try await API.shared.get("api/v1/buy-again", query: q, fresh: true)
            items = ListsLogic.cleanBuyAgain(p.items)
        } catch {
            // оставляем прежнее
        }
    }
}

/// Полка «Купить снова». shopId == nil — по всем заведениям (главная), иначе — одно (над меню).
struct BuyAgainShelf: View {
    var shopId: Int? = nil
    /// Заведение открыто и не на паузе — «+» кладёт сразу; иначе открывает карточку.
    var canQuickAdd: Bool = true
    let onOpen: (Int) -> Void

    @ObservedObject private var session = Session.shared
    @StateObject private var loader = BuyAgainLoader()
    @Environment(\.ymNestedPresentation) private var nested
    @State private var busyId: Int?

    var body: some View {
        Group {
            if session.isLoggedIn && !loader.items.isEmpty {
                VStack(spacing: 0) {
                    SectionHeader(title: "Купить снова", actionTitle: nil, action: nil)
                        .padding(.top, 18)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: YMSpace.md) {
                            ForEach(loader.items) { item in
                                card(item)
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, 4)
                    }
                }
            }
        }
        .task(id: "\(shopId ?? 0)-\(session.isLoggedIn)") {
            await loader.load(shopId: shopId, loggedIn: session.isLoggedIn)
        }
    }

    private func card(_ item: BuyAgainItem) -> some View {
        let pid = item.productId ?? 0
        return Button {
            Haptics.light(); onOpen(pid)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PhotoPlaceholder(url: API.imageURL(item.photo), label: "ФОТО", radius: YMForm.cardRadius, tone: pid, fit: true)
                    .frame(width: 146, height: 104)
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            Task { await quickAdd(item) }
                        } label: {
                            ZStack {
                                Circle().fill(YMColor.accent)
                                if busyId == pid {
                                    ProgressView().tint(YMColor.onAccent).scaleEffect(0.7)
                                } else {
                                    Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(YMColor.onAccent)
                                }
                            }
                            .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                        .disabled(busyId != nil)
                        .accessibilityLabel("Добавить в корзину: \(item.name ?? "товар")")
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "—")
                        .ymText(YMText.cardTitle).foregroundStyle(YMUi.text).lineLimit(1)
                    // На главной товары разных заведений — каждый со своим заведением.
                    if shopId == nil, let shop = item.shopName, !shop.isEmpty {
                        Text(shop).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary).lineLimit(1)
                    }
                    Text(Money.format(item.price ?? 0))
                        .ymText(YMText.cardPrice).foregroundStyle(YMUi.text).lineLimit(1)
                }
            }
            .frame(width: 146, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    /// Без обязательного выбора, не весовой и не набор — сразу в корзину; иначе карточка товара.
    private func isPlain(_ d: ProductDetail) -> Bool {
        d.stopped != true && d.outOfStock != true && d.categoryOff != true
            && !QuickAdd.isWeighed(detail: d)
            && (d.comboItems ?? []).isEmpty
            && !(d.modifierGroups ?? []).contains { $0.isRequired == true || ($0.minQty ?? 0) > 0 }
    }

    @MainActor
    private func quickAdd(_ item: BuyAgainItem) async {
        guard busyId == nil, let pid = item.productId else { return }
        guard canQuickAdd, !Cart.shared.checkLocked() else { onOpen(pid); return }
        busyId = pid
        defer { busyId = nil }
        guard let d = await QuickAdd.detail(pid), isPlain(d),
              let shopId = d.shopId ?? item.shopId, shopId > 0 else {
            onOpen(pid)   // выбор добавок/вес/стоп-лист/нет сети — решает карточка товара
            return
        }
        let cart = Cart.shared
        if let cur = cart.shopId, cur != shopId, !cart.isEmpty {
            // В шторке (профиль, «Жильё») общий диалог не виден — карточка товара спросит сама.
            if nested { onOpen(pid); return }
            NavCoordinator.shared.requestCartConflict(
                currentShop: cart.shopName, newShop: d.shopName ?? item.shopName,
                onConfirm: { commit(d, shopId: shopId, item: item) })
            return
        }
        commit(d, shopId: shopId, item: item)
    }

    private func commit(_ d: ProductDetail, shopId: Int, item: BuyAgainItem) {
        if Cart.shared.add(product: d, modifierIds: [], options: [], shopId: shopId, shopName: d.shopName ?? item.shopName) {
            Haptics.success()
        } else {
            Haptics.warning()
            onOpen(item.productId ?? d.id)
        }
    }
}

// MARK: - «Сохранить как список»

/// Окно с названием. save выполняет запрос (name — введённое, nil — пусто). Успех → onSaved и закрытие;
/// ошибка — текст сервера в окне.
struct SaveListSheet: View {
    let defaultName: String
    let nameRequired: Bool
    let save: (String?) async throws -> ShoppingListCard
    let onSaved: (ShoppingListCard) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var busy = false
    @State private var error: String?

    init(defaultName: String, nameRequired: Bool,
         save: @escaping (String?) async throws -> ShoppingListCard,
         onSaved: @escaping (ShoppingListCard) -> Void) {
        self.defaultName = defaultName
        self.nameRequired = nameRequired
        self.save = save
        self.onSaved = onSaved
        _name = State(initialValue: defaultName)
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Сохранить как список").ymText(YMText.sectionTitle).foregroundStyle(YMUi.text)
            TextField(nameRequired ? "Название списка" : "Название (необязательно)", text: $name)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.done)
                .onChange(of: name) { v in if v.count > 100 { name = String(v.prefix(100)) } }
            if let e = error {
                Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await run() }
            } label: {
                Text(busy ? "Сохраняем…" : "Сохранить")
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(busy || (nameRequired && trimmed.isEmpty))
            Button("Отмена") { dismiss() }
                .font(YMFont.headline).foregroundStyle(YMUi.text)
                .frame(maxWidth: .infinity)
                .disabled(busy)
            Spacer(minLength: 0)
        }
        .padding(YMSpace.xl)
        .presentationDetents([.medium])
        .interactiveDismissDisabled(busy)
    }

    @MainActor
    private func run() async {
        guard !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let card = try await save(trimmed.isEmpty ? nil : trimmed)
            Haptics.success()
            onSaved(card)
            dismiss()
        } catch is CancellationError {
        } catch {
            Haptics.warning()
            self.error = ListsLogic.message(error, "Не удалось сохранить список")
        }
    }
}

/// «Сохранить как список» в корзине: текущая корзина → POST /shopping-lists (с ключом повтора).
struct SaveCartAsListButton: View {
    @ObservedObject private var session = Session.shared
    @ObservedObject private var cart = Cart.shared
    @State private var open = false
    @State private var note: String?

    var body: some View {
        if session.isLoggedIn && !cart.isEmpty && (cart.shopId ?? 0) > 0 {
            VStack(spacing: 4) {
                Button {
                    Haptics.light(); open = true
                } label: {
                    Label("Сохранить как список", systemImage: "list.bullet.rectangle")
                        .font(YMFont.headline).foregroundStyle(YMColor.accent)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                if let n = note {
                    Text(n).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .sheet(isPresented: $open) {
                SaveListSheet(
                    defaultName: (cart.shopName ?? "").isEmpty ? "Мой список" : (cart.shopName ?? ""),
                    nameRequired: true,
                    save: { name in
                        let body = ListsLogic.requestFromCart(
                            shopId: Cart.shared.shopId ?? 0, name: name ?? "Мой список", lines: Cart.shared.lines)
                        let card: ShoppingListCard = try await API.shared.post("api/v1/shopping-lists", body: body, retryKey: true)
                        return card
                    },
                    onSaved: { card in
                        note = "Список «\(card.name ?? "")» сохранён: Профиль → «Мои списки покупок»"
                    })
            }
        }
    }
}

/// «Сохранить как список» в карточке выполненного заказа: POST /shopping-lists/from-order/{id}.
struct SaveOrderAsListButton: View {
    let orderId: Int
    @ObservedObject private var session = Session.shared
    @State private var open = false
    @State private var saved = false

    var body: some View {
        if session.isLoggedIn {
            Button {
                Haptics.light(); open = true
            } label: {
                Label(saved ? "Список сохранён" : "Сохранить как список", systemImage: "list.bullet.rectangle")
                    .font(YMFont.headline).foregroundStyle(YMColor.accent)
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $open) {
                SaveListSheet(
                    defaultName: "",
                    nameRequired: false,
                    save: { name in
                        let card: ShoppingListCard = try await API.shared.post(
                            "api/v1/shopping-lists/from-order/\(orderId)",
                            body: ShoppingListFromOrderBody(name: name), retryKey: true)
                        return card
                    },
                    onSaved: { _ in saved = true })
            }
        }
    }
}

// MARK: - «Мои списки покупок»

@MainActor
final class ShoppingListsViewModel: ObservableObject {
    @Published var lists: [ShoppingListSummary]?
    @Published var error: String?

    func load() async {
        do {
            let p: ListPayload<ShoppingListSummary> = try await API.shared.get("api/v1/shopping-lists", fresh: true)
            var seen = Set<Int>()
            lists = p.items.filter { seen.insert($0.id).inserted }
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = ListsLogic.message(error, "Не удалось загрузить списки")
        }
    }
}

struct ShoppingListsView: View {
    /// Открыть список (push в стеке профиля).
    var onOpen: (Int) -> Void
    var onLogin: () -> Void = {}

    @ObservedObject private var session = Session.shared
    @StateObject private var vm = ShoppingListsViewModel()

    var body: some View {
        Group {
            if !session.isLoggedIn {
                message("Войдите, чтобы собирать списки покупок", action: ("Войти", onLogin))
            } else if let lists = vm.lists {
                if lists.isEmpty {
                    message("Списков пока нет. Нажмите «Сохранить как список» в корзине или в выполненном заказе — и собирайте привычную покупку в один тап.", action: nil)
                } else {
                    listBody(lists)
                }
            } else if let e = vm.error {
                message(e, action: ("Повторить", { Task { await vm.load() } }))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(YMUi.screenBg.ignoresSafeArea())
        .navigationTitle("Мои списки покупок")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.isLoggedIn) { if session.isLoggedIn { await vm.load() } }
    }

    private func listBody(_ lists: [ShoppingListSummary]) -> some View {
        ScrollView {
            VStack(spacing: YMSpace.md) {
                if let e = vm.error {
                    Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(lists) { l in
                    Button {
                        Haptics.light(); onOpen(l.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text((l.name ?? "").isEmpty ? "Список" : (l.name ?? ""))
                                .ymText(YMText.cardTitle).foregroundStyle(YMUi.text).lineLimit(2)
                            let shop = l.shop?.name ?? ""
                            let count = ListsLogic.positionsLabel(l.itemsCount ?? 0)
                            Text(shop.isEmpty ? count : "\(shop) · \(count)")
                                .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(YMForm.cardPadding)
                        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .refreshable { await vm.load() }
    }

    private func message(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: YMSpace.md) {
            Text(text).font(YMFont.body).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            if let a = action {
                Button(a.0, action: a.1).buttonStyle(YMPrimaryButtonStyle())
            }
        }
        .padding(YMSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Один список

@MainActor
final class ShoppingListViewModel: ObservableObject {
    let id: Int
    @Published var card: ShoppingListCard?
    @Published var items: [ShoppingListItem] = []
    @Published var error: String?
    @Published var toast: String?
    @Published var busy = false
    /// Счётчик правок: ответ на устаревшую правку состав не перезаписывает.
    private var gen = 0
    private var saveTask: Task<Void, Never>?

    init(id: Int) { self.id = id }

    func load() async {
        do {
            let c: ShoppingListCard = try await API.shared.get("api/v1/shopping-lists/\(id)", fresh: true)
            card = c
            items = c.items ?? []
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = ListsLogic.message(error, "Не удалось загрузить список")
        }
    }

    /// PUT items целиком, с короткой паузой: быстрые «+»/«−» уходят одним запросом.
    func push(_ next: [ShoppingListItem]) {
        items = next
        gen += 1
        let my = gen
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled, let vm = self else { return }
            do {
                let body = ShoppingListUpdateBody(name: nil, items: ListsLogic.requestItems(next))
                let r: ShoppingListCard = try await API.shared.put("api/v1/shopping-lists/\(vm.id)", body: body)
                if my == vm.gen {
                    vm.card = r
                    if let it = r.items { vm.items = it }
                }
            } catch is CancellationError {
            } catch {
                if my == vm.gen {
                    vm.toast = ListsLogic.message(error, "Не удалось сохранить изменения")
                    await vm.load()
                }
            }
        }
    }

    /// nil — переименовано, иначе текст ошибки сервера.
    func rename(_ name: String) async -> String? {
        do {
            let r: ShoppingListCard = try await API.shared.put(
                "api/v1/shopping-lists/\(id)", body: ShoppingListUpdateBody(name: name, items: nil))
            card = r
            return nil
        } catch {
            return ListsLogic.message(error, "Не удалось переименовать")
        }
    }

    /// nil — удалено, иначе текст ошибки.
    func delete() async -> String? {
        do {
            try await API.shared.deleteVoid("api/v1/shopping-lists/\(id)")
            return nil
        } catch {
            return ListsLogic.message(error, "Не удалось удалить список")
        }
    }
}

private struct ListProductRef: Identifiable { let id: Int }

struct ShoppingListView: View {
    let id: Int
    /// Список удалён — вернуться назад.
    var onDeleted: () -> Void = {}

    @StateObject private var vm: ShoppingListViewModel
    @ObservedObject private var cart = Cart.shared
    @State private var askRename = false
    @State private var askDelete = false
    @State private var draftName = ""
    @State private var conflict = false
    @State private var productSheet: ListProductRef?

    init(id: Int, onDeleted: @escaping () -> Void = {}) {
        self.id = id
        self.onDeleted = onDeleted
        _vm = StateObject(wrappedValue: ShoppingListViewModel(id: id))
    }

    var body: some View {
        VStack(spacing: 0) {
            content
            if vm.card != nil && !vm.items.isEmpty {
                Button {
                    Haptics.medium(); addAll(force: false)
                } label: {
                    Text("Добавить всё в корзину")
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.horizontal, YMSpace.xl)
                .padding(.vertical, YMSpace.md)
            }
        }
        .background(YMUi.screenBg.ignoresSafeArea())
        .navigationTitle((vm.card?.name ?? "").isEmpty ? "Список" : (vm.card?.name ?? "Список"))
        .navigationBarTitleDisplayMode(.inline)
        .errorToast($vm.toast, bottom: 90)
        .task { await vm.load() }
        .cartConflictDialog(
            isPresented: $conflict,
            currentShop: cart.shopName,
            newShop: vm.card?.shop?.name,
            onConfirm: { addAll(force: true) }
        )
        .sheet(item: $productSheet) { ref in
            NavigationStack { ProductView(id: ref.id) }
        }
        .alert("Название списка", isPresented: $askRename) {
            TextField("Название", text: $draftName)
            Button("Сохранить") {
                let n = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !n.isEmpty else { return }
                Task { if let e = await vm.rename(String(n.prefix(100))) { vm.toast = e } }
            }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить список?", isPresented: $askDelete, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                Task {
                    if let e = await vm.delete() { vm.toast = e } else { Haptics.success(); onDeleted() }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Список «\(vm.card?.name ?? "")» будет удалён.")
        }
    }

    @ViewBuilder private var content: some View {
        if vm.card == nil {
            if let e = vm.error {
                VStack(spacing: YMSpace.md) {
                    Text(e).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                    Button("Повторить") { Task { await vm.load() } }.buttonStyle(YMPrimaryButtonStyle())
                }
                .padding(YMSpace.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView {
                VStack(spacing: YMSpace.md) {
                    HStack {
                        Text(vm.card?.shop?.name ?? "")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted).lineLimit(1)
                        Spacer()
                        Button("Переименовать") { draftName = vm.card?.name ?? ""; askRename = true }
                            .font(YMFont.callout).foregroundStyle(YMUi.text)
                        Button("Удалить") { askDelete = true }
                            .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                    }
                    if vm.items.isEmpty {
                        Text("В списке нет позиций").font(YMFont.body).foregroundStyle(YMColor.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(vm.items, id: \.self) { it in
                        row(it)
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, YMSpace.lg)
            }
            .refreshable { await vm.load() }
        }
    }

    private func row(_ it: ShoppingListItem) -> some View {
        let key = ListsLogic.lineKey(it)
        let pid = it.productId ?? 0
        return HStack(spacing: 12) {
            Button {
                if pid > 0 { productSheet = ListProductRef(id: pid) }
            } label: {
                PhotoPlaceholder(url: API.imageURL(it.photo), label: "ФОТО", radius: 12, tone: pid, fit: true)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text((it.name ?? "").isEmpty ? "Товар" : (it.name ?? "Товар"))
                    .ymText(YMText.cardTitle).foregroundStyle(YMUi.text).lineLimit(2)
                if let lbl = ListsLogic.modsLabelOf(it) {
                    Text(lbl).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary).lineLimit(2)
                }
                if it.available == false {
                    Text("Нет в наличии").ymText(YMText.caption).foregroundStyle(YMColor.statusCancel)
                } else {
                    Text(Money.format(ListsLogic.displayPrice(it))).ymText(YMText.cardPrice).foregroundStyle(YMUi.text)
                }
                HStack(spacing: 10) {
                    stepButton("minus", label: "Меньше") { vm.push(ListsLogic.changeQty(vm.items, key: key, dir: -1)) }
                    Text(ListsLogic.qtyText(it.qty, unit: it.unit))
                        .ymText(YMText.cardTitle).foregroundStyle(YMUi.text)
                        .frame(minWidth: 44)
                    stepButton("plus", label: "Больше") { vm.push(ListsLogic.changeQty(vm.items, key: key, dir: +1)) }
                }
            }
            Spacer(minLength: 0)
            Button {
                Haptics.light(); vm.push(ListsLogic.remove(vm.items, key: key))
            } label: {
                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(YMUi.textSecondary)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Убрать из списка")
        }
        .padding(YMForm.cardPadding)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }

    private func stepButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.light(); action()
        } label: {
            Image(systemName: icon).font(.system(size: 13, weight: .bold))
                .foregroundStyle(YMUi.text)
                .frame(width: 30, height: 30)
                .background(YMUi.segmentBg, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// Добавить доступное в корзину (как /reorder: одна корзина = один магазин, при чужой — диалог).
    private func addAll(force: Bool) {
        guard let shop = vm.card?.shop, let sid = shop.id, sid > 0 else { return }
        let avail = vm.items.filter { $0.available != false && ($0.productId ?? 0) > 0 }
        guard !avail.isEmpty else { vm.toast = "Сейчас ничего из списка нет в наличии"; return }
        let c = Cart.shared
        if c.checkLocked() { vm.toast = OrderDetailViewModel.lockedText; return }
        let other = c.shopId != nil && c.shopId != sid && !c.isEmpty
        if other && !force { conflict = true; return }
        var merged: [CartLine] = other ? [] : c.lines
        for nl in ListsLogic.cartLines(avail) {
            if let i = merged.firstIndex(where: { $0.key == nl.key }) {
                merged[i].qty = ((merged[i].qty + nl.qty) * 1000).rounded() / 1000
                merged[i].unitPrice = nl.unitPrice
                merged[i].serverWholesale = nil
            } else {
                merged.append(nl)
            }
        }
        guard c.setLines(merged, shopId: sid, shopName: shop.name, shopSlug: shop.slug) else {
            Haptics.warning(); vm.toast = OrderDetailViewModel.lockedText; return
        }
        Haptics.success()
        if avail.count < vm.items.count {
            vm.toast = "Добавлено \(avail.count) из \(vm.items.count) — остальных сейчас нет в наличии"
        } else {
            // Профиль — шторка поверх главной: закрываем её и открываем корзину.
            NavCoordinator.shared.revealForPush(closeAll: false) { NavCoordinator.shared.openCart() }
        }
    }
}
