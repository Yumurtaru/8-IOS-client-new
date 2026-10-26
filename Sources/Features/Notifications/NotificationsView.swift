//
//  NotificationsView.swift — Уведомления (premium-клиент)
//
//  Список уведомлений с непрочитанной точкой (золото), иконкой по типу,
//  заголовком/текстом и датой. При открытии непрочитанные помечаются
//  прочитанными на сервере. Токены YM, light+dark, Dynamic Type, Reduce Motion.
//
//  ТОЧКА ВХОДА (для навигации из ProfileView):
//    NotificationsView()   — самодостаточный экран (внутренний ScrollView),
//                            навешивается через .navigationDestination.
//
//  ПРИВЯЗКА К API (как в старом NotificationsView):
//    • GET  api/v1/notifications        → [AppNotification] (поле is_read → .read)
//    • POST api/v1/notifications/read   ← NotifReadBody(ids:[Int])  (пометить прочитанными)
//

import SwiftUI

struct NotificationsView: View {
    /// Строки ленты вместе с их data_json (куда вести по тапу).
    @State private var items: [NotifEntry] = []
    @State private var loading = true
    @State private var error: String?
    // Догрузка (волна А3): уведомлений по 20 на страницу, meta.has_more.
    @State private var page = 1
    @State private var hasMore = false
    @State private var moreFailed = false
    @State private var loadingMore = false
    /// Непрочитанные ЗА пределами уже открытых страниц (meta.unread минус
    /// отмеченные). Раньше при 20+ новых счётчик в профиле так и оставался
    /// ненулевым, пока человек не долистает до конца, — «Прочитать все».
    @State private var unreadLeft = 0
    @State private var markingAll = false

    var body: some View {
        ScrollView {
            // Lazy: подвал догрузки должен «появляться» при прокрутке, а не сразу.
            LazyVStack(alignment: .leading, spacing: YMSpace.md) {
                if loading {
                    ForEach(0..<5, id: \.self) { _ in SkeletonBox(radius: 18).frame(height: 74) }
                } else if let error {
                    NotifErrorState(message: error) { Task { await load() } }
                } else if items.isEmpty {
                    NotifEmptyState()
                } else {
                    // Строка ведёт туда же, куда push этого типа (заказ, чат,
                    // заведение, кошелёк, поездки, мои объявления). Раньше лента
                    // была только для чтения — открыть заказ из неё было нельзя.
                    ForEach(items) { n in
                        if n.target.opensSomething {
                            Button { Haptics.light(); n.target.open() } label: { NotifRow(item: n.base) }
                                .buttonStyle(.plain)
                        } else {
                            NotifRow(item: n.base)
                        }
                    }
                    if hasMore {
                        LoadMoreFooter(page: page, failed: moreFailed) { await loadMore() }
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Уведомления")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if unreadLeft > 0 {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Прочитать все") { Task { await markAllRead() } }
                        .disabled(markingAll)
                }
            }
        }
        // Только первый показ: возврат из кошелька/поддержки, открытых из
        // ленты, не должен сбрасывать список в скелетон и наверх.
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        loading = true
        error = nil
        page = 1; hasMore = false; moreFailed = false; loadingMore = false
        do {
            let first: Page<NotifEntry> = try await API.shared.page("api/v1/notifications")
            let list = first.items
            await MainActor.run { items = list; hasMore = first.hasMore; loading = false }
            // Отметить непрочитанные прочитанными (тихо, ошибки не показываем).
            let unread = list.filter { !$0.base.read }.map { $0.id }
            var left = first.meta?.unread ?? 0
            if !unread.isEmpty,
               (try? await API.shared.postVoid("api/v1/notifications/read", body: NotifReadBody(ids: unread))) != nil {
                left -= unread.count
            }
            let rest = max(0, left)
            await MainActor.run { unreadLeft = rest }
        } catch is CancellationError {
            // экран закрыли во время загрузки — игнор
        } catch {
            await MainActor.run {
                self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить уведомления"
                loading = false
            }
        }
    }
}

extension NotificationsView {
    /// Следующая страница. Зовёт подвал списка, когда он виден.
    fileprivate func loadMore() async {
        guard hasMore, !loadingMore, !loading else { return }
        loadingMore = true; moreFailed = false
        let next = page + 1
        do {
            let p: Page<NotifEntry> = try await API.shared.page("api/v1/notifications", query: ["page": String(next)])
            let known = Set(items.map(\.id))
            items += p.items.filter { !known.contains($0.id) }
            page = next
            hasMore = p.hasMore && !p.items.isEmpty
            // Догруженные непрочитанные — тоже прочитаны: человек до них долистал.
            let unread = p.items.filter { !$0.base.read }.map { $0.id }
            if !unread.isEmpty,
               (try? await API.shared.postVoid("api/v1/notifications/read", body: NotifReadBody(ids: unread))) != nil {
                unreadLeft = max(0, unreadLeft - unread.count)
            }
        } catch {
            if !(error is CancellationError) { moreFailed = true }
        }
        loadingMore = false
    }

    /// «Прочитать все»: пустой ids — сервер гасит всю ленту (как на сайте).
    fileprivate func markAllRead() async {
        guard !markingAll else { return }
        markingAll = true
        if (try? await API.shared.postVoid("api/v1/notifications/read", body: NotifReadBody(ids: []))) != nil {
            unreadLeft = 0
        }
        markingAll = false
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Куда ведёт строка (data_json)
// ─────────────────────────────────────────────────────────────────────────────

/// Строка ленты + цель перехода. AppNotification (Net/Models.swift) поле
/// data_json не читает — разбираем его здесь из той же строки ответа.
private struct NotifEntry: Decodable, Identifiable {
    let base: AppNotification
    let target: NotifTarget
    var id: Int { base.id }

    private enum Keys: String, CodingKey { case dataJson }

    init(from decoder: Decoder) throws {
        // Сама строка — тем же декодером (как раньше Page<AppNotification>).
        base = try decoder.singleValueContainer().decode(AppNotification.self)
        var raw: String?
        if let c = try? decoder.container(keyedBy: Keys.self) {
            raw = (try? c.decodeIfPresent(String.self, forKey: .dataJson)) ?? nil
        }
        target = NotifTarget(json: raw, feedType: base.type)
    }
}

/// Те же ключи и тот же порядок разбора, что у тапа по push (AppDelegate.handleNotification).
private struct NotifTarget {
    enum Kind {
        case org(String), chat(Int), order(Int), product(Int), ad(Int)
        case wallet, support, bonuses, cart, trips, nothing
        /// А79: посылка (pool_parcel, call_id) — карточка тут же, в профиле.
        case parcel(Int)
        /// А102: ответ поддержки (type=support, ticket_id) — переписка обращения, в профиле.
        case ticket(Int)
    }
    let kind: Kind

    init(json: String?, feedType: String?) {
        var d: [String: Any] = [:]
        if let s = json, let data = s.data(using: .utf8),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            d = obj
        }
        kind = Self.resolve(d, feedType: feedType ?? "")
    }

    var opensSomething: Bool {
        if case .nothing = kind { return false }
        return true
    }

    /// id из data: сервер кладёт и числом (order_status), и строкой.
    private static func positiveInt(_ v: Any?) -> Int? {
        if let i = v as? Int { return i > 0 ? i : nil }
        if let s = v as? String, let i = Int(s) { return i > 0 ? i : nil }
        return nil
    }

    /// События ПРОДАВЦА (ОТВЕТЫ-САЙТА П-21): владелец, вошедший тем же
    /// аккаунтом, видит их в ленте, но order_id там — не его покупка.
    private static let sellerTypes: Set<String> = [
        "new_order", "order_cancelled", "new_return", "order_returned",
        "pos_failed", "pos_rejected", "pos_dropped",
        "audit", "org_document", "product_hidden", "shop_published", "shop_publish_returned"
    ]

    /// Тот же признак, что AppDelegate.isSellerSide: тип продавца, чат/бронь
    /// с shop_id, крупная операция кассы (kind=approval), брони объекта.
    private static func isSellerSide(_ type: String, _ d: [String: Any]) -> Bool {
        if sellerTypes.contains(type) { return true }
        if (d["kind"] as? String) == "approval" || (d["screen"] as? String) == "lodging_bookings" { return true }
        return (type == "order_chat" || type == "reservation") && d["shop_id"] != nil
    }

    private static func resolve(_ d: [String: Any], feedType: String) -> Kind {
        let type = (d["type"] as? String) ?? ""
        let slug = (d["slug"] as? String) ?? ""
        let screen = (d["screen"] as? String) ?? ""
        if type == "new_shop" || type == "shop_reopened", !slug.isEmpty { return .org(slug) }
        if isSellerSide(type, d) { return .nothing }
        if type == "pool_parcel", let id = positiveInt(d["call_id"]) { return .parcel(id) }
        if type == "order_chat", let id = positiveInt(d["order_id"]) { return .chat(id) }
        if let id = positiveInt(d["order_id"]) { return .order(id) }
        if type.isEmpty, let pid = positiveInt(d["product_id"]) { return .product(pid) }
        // wallet_topup без data — строки ленты до появления screen=wallet.
        if screen == "wallet" || feedType == "wallet_topup" { return .wallet }
        if type == "support", let id = positiveInt(d["ticket_id"]) { return .ticket(id) }
        if type == "support" { return .support }
        if type == "bonus_expiring" { return .bonuses }
        if type == "abandoned_cart" { return .cart }
        if screen == "trips" { return .trips }
        if let a = positiveInt(d["ad_id"]) { return .ad(a) }
        return .nothing
    }

    /// Переход. Лента открыта в шторке профиля: заказ, чат, заведение и
    /// вкладки показываются под ней, поэтому сначала её закрываем
    /// (revealForPush / openOrg). Кошелёк и поддержка — тут же, в профиле.
    func open() {
        let coord = NavCoordinator.shared
        switch kind {
        case .org(let slug):
            coord.openOrg(slug: slug)
        case .chat(let id):
            coord.revealForPush(closeAll: false) { coord.openChat(orderId: id) }
        case .order(let id):
            coord.revealForPush(closeAll: true) { coord.pendingOrderDetail = id }
        case .product(let pid):
            coord.revealForPush(closeAll: true) {
                DeepLinkRouter.shared.requestedTab = 0
                coord.pendingProductId = pid
            }
        case .ad:
            coord.revealForPush(closeAll: true) {
                DeepLinkRouter.shared.requestedTab = 4
                AdsPushIntent.openMyAds()
            }
        case .wallet:
            ProfilePushIntent.open(.wallet)
        case .support:
            ProfilePushIntent.open(.support)
        case .bonuses:
            ProfilePushIntent.open(.bonuses)
        case .parcel(let id):
            ProfilePushIntent.open(.parcel(id))
        case .ticket(let id):
            ProfilePushIntent.open(.ticket(id))
        case .cart:
            coord.revealForPush(closeAll: true) { DeepLinkRouter.shared.requestedTab = 2 }
        case .trips:
            coord.revealForPush(closeAll: true) {
                LodgingPushIntent.openTrips()
                coord.openLodging()
            }
        case .nothing:
            break
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Строка уведомления
// ─────────────────────────────────────────────────────────────────────────────

private struct NotifRow: View {
    let item: AppNotification

    /// Эмодзи-иконка по типу уведомления (аддитивно; неизвестный тип → 🔔).
    private var icon: String {
        switch (item.type ?? "").lowercased() {
        case let t where t.contains("order"):    return "🧾"
        case let t where t.contains("delivery"): return "🚚"
        case let t where t.contains("promo"), let t where t.contains("discount"): return "🎁"
        case let t where t.contains("bonus"), let t where t.contains("point"):    return "💎"
        case let t where t.contains("chat"), let t where t.contains("message"):   return "💬"
        default: return "🔔"
        }
    }

    /// А104: выигрыш в розыгрыше — тип шаблона giveaway_win (core/Giveaway.php, Notify::user)
    /// или data_json.type = giveaway (тот же data, что у push). Текст — как пришёл.
    private var isGiveaway: Bool {
        if (item.type ?? "").trimmingCharacters(in: .whitespaces) == "giveaway_win" { return true }
        return (item.notifPayload["type"] as? String) == "giveaway"
    }

    var body: some View {
        let giveaway = isGiveaway
        HStack(alignment: .top, spacing: 12) {
            if giveaway {
                Image(systemName: "gift.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(YMColor.onAccent)
                    .frame(width: 40, height: 40)
                    .background(YMColor.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)
            } else {
                Text(icon)
                    .font(.system(size: 17))
                    .frame(width: 40, height: 40)
                    .background(item.read ? YMColor.surface2 : YMColor.accent.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.title ?? "Уведомление")
                        .font(.system(size: 15, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if !item.read {
                        Circle().fill(YMColor.accent).frame(width: 8, height: 8).padding(.top, 5)
                    }
                }
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 13))
                        .foregroundStyle(giveaway ? YMColor.text : YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(DateFmt.short(item.createdAt))
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
                    .padding(.top, 1)
            }
        }
        .padding(14)
        // А104: розыгрыш — акцентный (золотой) фон поверх карточки и золотая рамка. Этот
        // фон — ближе к содержимому, т.е. над непрозрачным surface ниже.
        .background(giveaway ? YMColor.accent.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(giveaway ? YMColor.accent.opacity(0.6)
                              : (item.read ? YMColor.hairline : YMColor.accent.opacity(0.35)),
                              lineWidth: item.read && !giveaway ? 1 : 1.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(giveaway ? "Розыгрыш, " : "")\(item.read ? "" : "Новое, ")\(item.title ?? "Уведомление"). \(item.body ?? "")")
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Пусто / ошибка (локальные, уникальные имена)
// ─────────────────────────────────────────────────────────────────────────────

private struct NotifEmptyState: View {
    var body: some View {
        VStack(spacing: YMSpace.sm) {
            Text("🔔").font(.system(size: 44))
            Text("Уведомлений пока нет")
                .font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Здесь появятся статусы заказов, акции и важные события.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 60)
    }
}

private struct NotifErrorState: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: YMSpace.md) {
            Text("😕").font(.system(size: 44))
            Text(message)
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button("Повторить") { Haptics.light(); onRetry() }
                .buttonStyle(YMPrimaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 60)
    }
}
