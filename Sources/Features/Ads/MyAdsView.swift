//
//  MyAdsView.swift — «Мои объявления»: продление, снятие, правка, удаление
//
//  Сумма продления приходит с сервера в renew_price: она нулевая, если
//  объявление снято владельцем, а оплаченный срок ещё идёт. Поэтому на кнопке
//  показываем именно её, а не цену категории.
//

import SwiftUI

private func adStatusLabel(_ s: String?) -> String {
    switch s {
    case "draft": return "Черновик"
    case "active": return "Активно"
    case "expired": return "Срок вышел"
    case "archived": return "Снято с публикации"
    case "blocked": return "Заблокировано"
    default: return s ?? "—"
    }
}

@MainActor
final class MyAdsViewModel: ObservableObject {
    @Published var items: [AdCard] = []
    @Published var active = 0
    @Published var maxActive = 0
    @Published var balance: Decimal = 0
    @Published var loading = true
    @Published var error: String?
    @Published var toast: String?
    @Published var shortage: String?

    func load() async {
        do {
            let r = try await API.shared.myAds()
            items = r.items ?? []
            active = r.active ?? 0
            maxActive = r.maxActive ?? 0
            balance = r.balance ?? 0
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить"
            // Список уже на экране (обновление жестом, после оплаты/снятия) —
            // экран ошибки не показывается, и сбой был незаметен: говорим тостом.
            // Итог только что выполненного действия («Опубликовано…») не затираем.
            if !items.isEmpty && toast == nil { toast = "Не удалось обновить: " + (self.error ?? "") }
        }
        loading = false
    }

    /// Идёт оплата/продление — второе нажатие игнорируем (сервер двойное
    /// списание и так не допустит, но человек видел бы два сообщения).
    /// Published: кнопки «Оплатить»/«Продлить» серые, пока идёт запрос и перечитывание.
    @Published private(set) var paying = false

    func publish(_ ad: AdCard) async {
        guard !paying else { return }
        paying = true
        defer { paying = false }
        do {
            // Сумма с кнопки: цена рубрики поменялась, пока экран был открыт, —
            // сервер откажет 409 price_changed, ничего не списав.
            let r = try await API.shared.adPublish(ad.stableId, expectedPrice: ad.renewPrice)
            let charged = r.charged ?? 0
            toast = charged > 0 ? "Опубликовано, списано \(Money.format(charged))" : "Опубликовано"
            await load()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось опубликовать"
            // 409 «не хватает денег» сервер отдаёт с суммами, но до экрана
            // доходит текст — показываем его и предлагаем пополнить кошелёк.
            if Self.isShortage(error, msg) { shortage = msg } else { await failNote(ad.stableId, error, msg) }
        }
    }

    /// Нехватка денег — по типу ошибки (409 с суммами), а не только по слову
    /// «хватает» в тексте: иной текст сервера уходил тостом без подсказки пополнить.
    private static func isShortage(_ error: Error, _ msg: String) -> Bool {
        if let e = error as? APIError, case .walletShortage = e { return true }
        return msg.contains("хватает")
    }

    func renew(_ ad: AdCard) async {
        guard !paying else { return }
        paying = true
        defer { paying = false }
        do {
            let r = try await API.shared.adRenew(ad.stableId, expectedPrice: ad.renewPrice)
            let charged = r.charged ?? 0
            toast = charged > 0 ? "Продлено, списано \(Money.format(charged))" : "Уже продлено"
            await load()
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось продлить"
            if Self.isShortage(error, msg) { shortage = msg } else { await failNote(ad.stableId, error, msg) }
        }
    }

    /// Отказ «Оплатить»/«Продлить»: сначала перечитываем список (409, неизвестный исход),
    /// потом текст. Цена изменилась — «нажмите ещё раз» только если кнопка осталась;
    /// исход неизвестен — совет проверить баланс перед повтором (как в форме и в Android).
    private func failNote(_ id: Int, _ error: Error, _ msg: String) async {
        await reloadOnConflict(error)
        if (error as? APIError)?.priceChangedTo != nil {
            let retry = items.first(where: { $0.stableId == id }).map { Self.hasPayButton($0) } ?? false
            toast = Self.priceChangedText(error, retry: retry) ?? msg
        } else if (error as? APIError)?.rejectStatus == nil {
            toast = msg + ". Проверьте баланс кошелька перед повтором"
        } else {
            toast = msg
        }
    }

    /// Есть ли у карточки кнопка оплаты — те же условия, что в списке ниже.
    static func hasPayButton(_ ad: AdCard) -> Bool {
        switch ad.status {
        case "active": return inRenewWindow(ad.expiresAt) && ad.categoryOff != true && (ad.renewPrice ?? 0) > 0
        case "blocked": return false
        default: return ad.categoryOff != true
        }
    }

    /// 409 (цена изменилась, статус изменился) — список на экране устарел:
    /// перечитываем, чтобы на кнопке была новая сумма. Неизвестный исход (обрыв,
    /// таймаут, 5xx) — оплата могла пройти: тоже перечитываем, и до конца
    /// перечитывания кнопка занята (paying) — повтор позже 2 минут по старому списку
    /// списал бы второй раз. Паритет с Android (reloadOnConflict).
    private func reloadOnConflict(_ error: Error) async {
        let status = (error as? APIError)?.rejectStatus
        if status == 409 || status == nil { await load() }
    }

    /// 409 price_changed: понятный текст с новой ценой. nil — это другая ошибка.
    /// retry = false — кнопки после перечитывания нет, призыв нажать не пишем.
    static func priceChangedText(_ error: Error, retry: Bool = true) -> String? {
        guard let p = (error as? APIError)?.priceChangedTo else { return nil }
        return "Цена размещения изменилась — теперь " + (p > 0 ? Money.format(p) : "бесплатно")
            + ". Деньги не списаны" + (retry ? ", нажмите ещё раз, если согласны" : "")
    }

    /// Время сервера — московское и без смещения. Раньше разбиралось в поясе
    /// телефона: восточнее Москвы срок «выходил» на часы раньше, кнопка
    /// «Продлить» появлялась и пропадала не вовремя (как в Android — по Москве).
    /// Один форматтер на все строки списка, а не новый на каждую перерисовку.
    private static let serverTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// Срок уже прошёл. Снятое объявление с оплаченным сроком раньше
    /// подписывалось «срок вышел» с будущей датой.
    static func expired(_ s: String?) -> Bool {
        guard let s, s.count >= 19 else { return true }
        guard let d = serverTime.date(from: String(s.prefix(19))) else { return true }
        return d.timeIntervalSinceNow <= 0
    }

    /// Окно продления активного: до конца срока 3 дня или меньше — или срок уже вышел,
    /// а крон ещё не перевёл объявление в «истёкшие» (сервер такое перезапускает,
    /// Ads.php:392-396). Сервер пишет "Y-m-d H:i:s". Им же пользуется форма правки.
    static func inRenewWindow(_ s: String?) -> Bool {
        guard let s, s.count >= 19 else { return false }
        guard let d = serverTime.date(from: String(s.prefix(19))) else { return false }
        return d.timeIntervalSinceNow <= 3 * 86400
    }

    /// Объявления, по которым уже идёт «Снять»/«Удалить»: двойное нажатие слало
    /// второй запрос, и после удачного действия всплывало «Не удалось…».
    private var actingIds = Set<Int>()

    func archive(_ ad: AdCard) async {
        guard !actingIds.contains(ad.stableId) else { return }
        actingIds.insert(ad.stableId)
        defer { actingIds.remove(ad.stableId) }
        do { try await API.shared.adArchive(ad.stableId); toast = "Снято. Оплаченный срок сохранён"; await load() }
        // Причина словами (сессия кончилась, нет связи, отказ сервера), а не
        // одно «Не удалось» на всё.
        catch { toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось снять с публикации" }
    }

    func remove(_ ad: AdCard) async {
        guard !actingIds.contains(ad.stableId) else { return }
        actingIds.insert(ad.stableId)
        defer { actingIds.remove(ad.stableId) }
        do { try await API.shared.adDelete(ad.stableId); toast = "Удалено"; await load() }
        catch {
            toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось удалить"
            // 404 — уже удалено (с сайта, другим устройством): убираем из списка.
            if (error as? APIError)?.rejectStatus == 404 { await load() }
        }
    }
}

struct MyAdsView: View {
    @StateObject private var vm = MyAdsViewModel()
    @State private var editId: Int?
    @State private var showNew = false
    @State private var confirmDelete: AdCard?
    /// Открытое объявление. Свой переход, а не AdsRoute: экран открывают и из
    /// профиля, где AdsRoute не зарегистрирован, — «Открыть» там не работало.
    @State private var openAdId: Int?
    /// Паритет с Android: «Не хватает денег» ведёт прямо в кошелёк (раньше —
    /// только совет «пополните в профиле»).
    @State private var showWallet = false

    var body: some View {
        Group {
            if vm.loading {
                AdsSkeletonView()
            } else if let e = vm.error, vm.items.isEmpty {
                ErrorRetryView(message: e) { Task { vm.loading = true; await vm.load() } }
            } else if vm.items.isEmpty {
                // Кнопка прямо в пустом экране: «Подайте первое» раньше
                // оставляло искать маленький «+» в углу панели.
                AdsEmptyView(title: "Объявлений пока нет", subtitle: "Подайте первое — это займёт пару минут.",
                             actionTitle: "Подать объявление", action: { showNew = true })
            } else {
                list
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои объявления")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .task { await vm.load() }
        .navigationDestination(isPresented: Binding(
            get: { openAdId != nil || showWallet },
            set: { if !$0 { openAdId = nil; showWallet = false } }
        )) {
            if showWallet { WalletView() } else if let id = openAdId { AdDetailView(adId: id) }
        }
        // Черновик или правка, сохранённые без публикации, тоже должны
        // появиться в списке сразу, а не после обновления жестом.
        .sheet(isPresented: $showNew, onDismiss: { Task { await vm.load() } }) {
            AdFormView(editAdId: 0) { _ in showNew = false; Task { await vm.load() } }
        }
        .sheet(item: Binding(get: { editId.map { AdEditTarget(id: $0) } },
                             set: { editId = $0?.id }),
               onDismiss: { Task { await vm.load() } }) { target in
            // П-26.6: признак закрытой рубрики — в форму правки.
            AdFormView(editAdId: target.id,
                       categoryOff: vm.items.first(where: { $0.stableId == target.id })?.categoryOff == true) { _ in
                editId = nil; Task { await vm.load() }
            }
        }
        .alert("Удалить объявление?", isPresented: Binding(
            get: { confirmDelete != nil },
            set: { if !$0 { confirmDelete = nil } }
        )) {
            Button("Удалить", role: .destructive) {
                if let ad = confirmDelete { Task { await vm.remove(ad) } }
                confirmDelete = nil
            }
            Button("Отмена", role: .cancel) { confirmDelete = nil }
        } message: {
            Text("«\(confirmDelete?.title ?? "")» и его фотографии будут удалены безвозвратно.")
        }
        .alert("Не хватает денег", isPresented: Binding(
            get: { vm.shortage != nil },
            set: { if !$0 { vm.shortage = nil } }
        )) {
            Button("Пополнить кошелёк") { vm.shortage = nil; openAdId = nil; showWallet = true }
            Button("Позже", role: .cancel) { vm.shortage = nil }
        } message: {
            Text((vm.shortage ?? "") + "\n\nОбъявление сохранено и никуда не денется.")
        }
        .overlay(alignment: .bottom) {
            if let t = vm.toast {
                Text(t)
                    .font(YMFont.caption).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(YMColor.text.opacity(0.9), in: Capsule())
                    .padding(.bottom, YMSpace.lg)
                    // Свой таймер у каждого сообщения: таймер прежнего тоста гасил новый раньше срока.
                    .task(id: t) {
                        // Длинный текст (цена изменилась) — дольше.
                        try? await Task.sleep(nanoseconds: t.count > 60 ? 6_000_000_000 : 2_500_000_000)
                        if !Task.isCancelled { vm.toast = nil }
                    }
            }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                Text("Активных: \(vm.active) из \(vm.maxActive) · на кошельке \(Money.format(vm.balance))")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)

                ForEach(vm.items) { ad in
                    VStack(alignment: .leading, spacing: YMSpace.sm) {
                        HStack(alignment: .top, spacing: YMSpace.md) {
                            ZStack {
                                Rectangle().fill(YMColor.surface2)
                                if let u = API.imageURL(ad.photoURL) {
                                    CachedAsyncImage(url: u) { phase in
                                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                        else { Image(systemName: "photo").foregroundStyle(YMColor.muted) }
                                    }
                                } else {
                                    Image(systemName: "photo").foregroundStyle(YMColor.muted)
                                }
                            }
                            .frame(width: 84, height: 84)
                            .clipShape(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(adStatusLabel(ad.status))
                                    .font(YMFont.caption2)
                                    .foregroundStyle(ad.status == "active" ? YMColor.statusDone
                                                     : (ad.status == "blocked" ? YMColor.statusCancel : YMColor.muted))
                                Text(ad.title ?? "").font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(2)
                                Text(ad.priceText ?? "").font(YMFont.body).foregroundStyle(YMColor.text)
                                Text("Просмотров: \(ad.viewsCount ?? 0)" + expiryText(ad))
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                                if let br = ad.blockReason, !br.isEmpty {
                                    Text(br).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                                }
                                if ad.categoryOff == true {
                                    Text("Раздел «\(ad.categoryName ?? "")» временно закрыт — объявление не показывается в ленте")
                                        .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                                }
                            }
                            Spacer(minLength: 0)
                        }

                        HStack(spacing: YMSpace.md) {
                            if ad.status == "active" {
                                Button { openAdId = ad.stableId } label: {
                                    Text("Открыть").font(YMFont.callout).foregroundStyle(YMColor.accent)
                                }
                                Button("Снять") { Task { await vm.archive(ad) } }
                                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                                // Паритет с Android: в закрытом разделе продление сервер
                                // не примет (Ads::publish без тарифа) — кнопки нет; в бесплатной
                                // рубрике заранее не продлевает (Ads.php:386, price > 0).
                                if MyAdsViewModel.hasPayButton(ad) {
                                    Button { Task { await vm.renew(ad) } } label: {
                                        Text("Продлить").font(YMFont.callout).fontWeight(.semibold)
                                            .foregroundStyle(YMColor.accent)
                                    }
                                    .disabled(vm.paying)
                                }
                            } else if ad.status == "blocked" {
                                Text("Обратитесь в поддержку").font(YMFont.caption).foregroundStyle(YMColor.muted)
                            } else if ad.categoryOff == true {
                                // Паритет с Android: раздел закрыт — сервер отдаёт can_publish = false,
                                // а «Опубликовать» падало ошибкой «Категория недоступна».
                                Text("Публикация недоступна").font(YMFont.caption).foregroundStyle(YMColor.muted)
                            } else {
                                Button {
                                    Task { await vm.publish(ad) }
                                } label: {
                                    Text((ad.renewPrice ?? 0) > 0
                                         ? "Оплатить \(Money.format(ad.renewPrice ?? 0))"
                                         : "Опубликовать")
                                        .font(YMFont.callout).fontWeight(.semibold)
                                        .foregroundStyle(YMColor.accent)
                                }
                                .disabled(vm.paying)
                            }
                            Spacer()
                            // Заблокированное объявление сервер не даёт ни править, ни
                            // удалять (403, routes/ads.php): раньше человек заполнял
                            // форму зря и получал отказ только при сохранении.
                            if ad.status != "blocked" {
                                Button("Изменить") { editId = ad.stableId }
                                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                                Button("Удалить") { confirmDelete = ad }
                                    .font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                            }
                        }
                    }
                    .padding(YMSpace.md)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                            .strokeBorder(YMColor.hairline, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .refreshable { await vm.load() }
    }
}

extension MyAdsView {
    /// « · до 09.11.2026» / « · срок вышел 09.11.2026» — дата по-русски, а не ISO.
    fileprivate func expiryText(_ ad: AdCard) -> String {
        guard let e = ad.expiresAt, !e.isEmpty else { return "" }
        // Активное с уже вышедшим сроком (крон снимает раз в час) — тоже «срок вышел».
        let word = !MyAdsViewModel.expired(e) ? "до " : "срок вышел "
        return " · " + word + (DateFmt.day(e) ?? String(e.prefix(10)))
    }
}

/// Обёртка для .sheet(item:) — Int сам по себе не Identifiable.
struct AdEditTarget: Identifiable { let id: Int }
