//
//  WalletView.swift — «Кошелёк» клиента (баланс, пополнение через ЮKassa, история)
//
//  Контракт (routes/wallet.php), 1:1 с Android (9 Android-client-new · ui/screens/wallet/WalletScreen.kt):
//    • GET  api/v1/wallet              → WalletInfo(balance, enabled, minTopup, maxTopup, transactions)
//    • POST api/v1/wallet/topup        → WalletTopupCreated(topupId, amount, confirmationUrl)
//    • GET  api/v1/wallet/topup/{id}   → WalletTopupStatus(status, amount, balance)
//
//  Важное про деньги: баланс поднимает ТОЛЬКО сервер и только после того, как
//  ЮKassa подтвердила платёж. Экран открывает страницу оплаты в SFSafariViewController
//  и опрашивает статус — сам он ничего не зачисляет.
//
//  Деньги — Decimal через @LenientDecimal и Money.format, никогда не Double.
//  Токены YM.*, light+dark, Dynamic Type. Состояния: скелетон / ошибка + «Повторить» / контент.
//

import SwiftUI

@MainActor
final class WalletViewModel: ObservableObject {
    @Published var info: WalletInfo?
    @Published var loading = true
    @Published var error: String?
    @Published var notice: String?
    @Published var payLink: PayLink?
    /// Ждём подтверждения оплаты по этому пополнению (nil — не ждём).
    @Published var awaitingTopupId: Int?

    /// Опрос статуса. Держит self слабо, поэтому при уходе экрана прекращается сам.
    private var watchTask: Task<Void, Never>?

    var minTopup: Decimal { info?.minTopup ?? 100 }
    var maxTopup: Decimal { info?.maxTopup ?? 300_000 }

    /// П-27.11 (А72): история постранично — meta {page, per_page: 20, has_more}.
    /// Старый сервер meta не шлёт — hasMore false, всё как раньше (одна выдача).
    @Published var hasMore = false
    @Published var loadingMore = false
    @Published var moreFailed = false
    private var page = 1

    func load() async {
        do {
            let r: WalletPage = try await API.shared.get("api/v1/wallet")
            info = r.info
            page = 1
            hasMore = r.hasMore && !(r.info.transactions ?? []).isEmpty
            moreFailed = false
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    /// Следующая страница истории (page=N). Дубли на стыке страниц (новая
    /// операция сдвинула выдачу) отбрасываем по id.
    func loadMore() async {
        guard hasMore, !loadingMore, info != nil else { return }
        loadingMore = true
        defer { loadingMore = false }
        let next = page + 1
        do {
            let r: WalletPage = try await API.shared.get("api/v1/wallet", query: ["page": String(next)])
            let old = info?.transactions ?? []
            let seen = Set(old.compactMap { $0.id })
            let fresh = (r.info.transactions ?? []).filter { t in t.id.map { !seen.contains($0) } ?? true }
            info?.transactions = old + fresh
            page = next
            hasMore = r.hasMore && !(r.info.transactions ?? []).isEmpty
            moreFailed = false
        } catch is CancellationError {
        } catch {
            moreFailed = true
        }
    }

    /// Платёж создаётся — второе «Пополнить» в это время создавало второй платёж.
    @Published var creating = false

    func topup(amount: Decimal, method: String) async {
        guard !creating else { return }
        creating = true
        defer { creating = false }
        notice = nil
        do {
            let body = WalletTopupBody(amount: Money.wire(amount), method: method)
            let created: WalletTopupCreated = try await API.shared.post("api/v1/wallet/topup", body: body)
            guard let link = created.confirmationUrl, let url = URL(string: link) else {
                // Паритет с Android: прошлое пополнение на ту же сумму уже оплачено —
                // сервер отвечает status = confirmed без ссылки (routes/wallet.php,
                // POST …/topup). Раньше писали «не вернул ссылку», хотя деньги
                // зачислены. Есть номер пополнения — проверяем его статус.
                if let id = created.topupId, id > 0 {
                    awaitingTopupId = id
                    notice = "Ожидаем оплату. Баланс обновится сам, как только ЮKassa подтвердит платёж."
                    watch(id: id)
                } else {
                    notice = "Сервер не вернул ссылку на оплату. Попробуйте позже."
                }
                return
            }
            payLink = PayLink(url: url)
            if let id = created.topupId, id > 0 {
                awaitingTopupId = id
                notice = "Ожидаем оплату. Баланс обновится сам, как только ЮKassa подтвердит платёж."
                watch(id: id)
            }
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? "Не удалось создать платёж"
        }
    }

    /// Ждём ответа ЮKassa примерно 5 минут. Обрыв связи отказом не считаем —
    /// запрос просто повторяется, платёж от этого не пропадает.
    private func watch(id: Int) {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            for _ in 0..<100 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { return }
                guard let self, self.awaitingTopupId == id else { return }
                guard let st: WalletTopupStatus = try? await API.shared.get("api/v1/wallet/topup/\(id)") else { continue }
                if Task.isCancelled { return }
                switch st.status {
                case "confirmed":
                    self.awaitingTopupId = nil
                    self.notice = "Кошелёк пополнен на \(Money.format(st.amount ?? 0))"
                    await self.load()
                    return
                case "rejected":
                    self.awaitingTopupId = nil
                    self.notice = "Платёж не прошёл. Деньги не списаны, можно попробовать ещё раз."
                    await self.load()
                    return
                default:
                    continue
                }
            }
            guard let self, self.awaitingTopupId == id else { return }
            self.awaitingTopupId = nil
            self.notice = "Платёж обрабатывается. Баланс обновится сам — деньги не потеряются."
            await self.load()
        }
    }

    /// Человек закрыл страницу оплаты — проверяем статус сразу, не дожидаясь
    /// следующего тика опроса.
    func checkNow() async {
        guard let id = awaitingTopupId else { await load(); return }
        if let st: WalletTopupStatus = try? await API.shared.get("api/v1/wallet/topup/\(id)") {
            if st.status == "confirmed" {
                awaitingTopupId = nil
                notice = "Кошелёк пополнен на \(Money.format(st.amount ?? 0))"
            } else if st.status == "rejected" {
                awaitingTopupId = nil
                notice = "Платёж не прошёл. Деньги не списаны, можно попробовать ещё раз."
            }
        }
        await load()
    }
}

struct WalletView: View {
    @StateObject private var vm = WalletViewModel()
    @State private var showTopup = false
    @State private var pendingTopup: (amount: Decimal, method: String)?
    /// Паритет с Android: прошлое пополнение ещё ждёт ЮKassa — спрашиваем, прежде
    /// чем создать второй платёж (вернувшись со страницы оплаты, платили дважды).
    @State private var confirmNewTopup = false

    var body: some View {
        Group {
            if vm.loading {
                skeleton
            } else if let e = vm.error, vm.info == nil {
                ErrorRetryView(message: e) { Task { vm.loading = true; await vm.load() } }
            } else {
                content
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Кошелёк")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load() }
        .sheet(item: $vm.payLink, onDismiss: { Task { await vm.checkNow() } }) { link in
            SafariSheet(url: link.url)
        }
        // Платёж создаём ПОСЛЕ того, как лист пополнения закрылся: иначе на
        // быстрой сети payLink приходил, пока лист ещё уезжал, SwiftUI не мог
        // показать второй лист поверх первого — страница ЮKassa не открывалась,
        // а экран 5 минут писал «Ожидаем оплату».
        .sheet(isPresented: $showTopup, onDismiss: {
            if let p = pendingTopup {
                pendingTopup = nil
                Task { await vm.topup(amount: p.amount, method: p.method) }
            }
        }) {
            TopupSheet(min: vm.minTopup, max: vm.maxTopup) { amount, method in
                pendingTopup = (amount, method)
                showTopup = false
            }
        }
    }

    // MARK: Контент

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                heroCard

                // Обновление (жестом, после оплаты) не прошло, а старый баланс на
                // экране — раньше сбой был не виден, и баланс казался актуальным.
                if let e = vm.error {
                    Text("Не удалось обновить баланс: " + e)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.statusCancel)
                }

                if let n = vm.notice {
                    HStack(spacing: YMSpace.sm) {
                        if vm.awaitingTopupId != nil { ProgressView().scaleEffect(0.8) }
                        Text(n)
                            .font(YMFont.callout)
                            .foregroundStyle(vm.awaitingTopupId != nil ? YMColor.muted : YMColor.text)
                    }
                }

                if vm.info?.enabled == true {
                    Button {
                        if vm.creating { return }
                        if vm.awaitingTopupId != nil { confirmNewTopup = true } else { showTopup = true }
                    } label: {
                        Text(vm.creating ? "Создаём платёж…" : "Пополнить")
                            .font(YMFont.headline)
                            .foregroundStyle(YMColor.onAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                               startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                            )
                    }
                } else {
                    // enabled=false — онлайн-оплата на площадке не настроена.
                    // Кнопку не показываем: нажатие всё равно вернуло бы 503.
                    Text("Онлайн-пополнение пока не настроено на площадке. Баланс кошелька тратится на размещение объявлений.")
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }

                Text("История операций")
                    .font(YMFont.title3)
                    .foregroundStyle(YMColor.text)
                    .padding(.top, YMSpace.sm)

                let txs = vm.info?.transactions ?? []
                if txs.isEmpty {
                    Text("Операций пока нет")
                        .font(YMFont.body)
                        .foregroundStyle(YMColor.muted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(txs.enumerated()), id: \.offset) { idx, t in
                            WalletTxRow(tx: t)
                            if idx != txs.count - 1 { Divider().overlay(YMColor.hairline) }
                        }
                    }
                    .padding(.horizontal, YMSpace.md)
                    .padding(.vertical, YMSpace.xs)
                    .ymCard()

                    // П-27.11: есть ещё операции — кнопка «Показать ещё» (не
                    // автодогрузка: в обычном VStack подвал «виден» сразу).
                    if vm.hasMore {
                        Button { Task { await vm.loadMore() } } label: {
                            Group {
                                if vm.loadingMore { ProgressView() }
                                else {
                                    Text(vm.moreFailed ? "Не удалось загрузить — повторить" : "Показать ещё")
                                        .font(YMFont.callout).fontWeight(.semibold)
                                        .foregroundStyle(YMColor.accent)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, YMSpace.sm)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.loadingMore)
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .refreshable { await vm.load() }
        .confirmationDialog("Платёж ещё проверяется", isPresented: $confirmNewTopup, titleVisibility: .visible) {
            Button("Новое пополнение") { showTopup = true }
            Button("Подождать", role: .cancel) {}
        } message: {
            Text("Прошлое пополнение ждёт подтверждения ЮKassa. Если вы его уже оплатили, баланс обновится сам — второй платёж не нужен.")
        }
    }

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text("Баланс кошелька")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.onAccent.opacity(0.9))
            Text(Money.format(vm.info?.balance ?? 0))
                .font(YMFont.largeTitle)
                .foregroundStyle(YMColor.onAccent)
            // Прямо говорим, на что эти деньги. Раньше экран обещал оплату
            // заказов — заказы кошельком не оплачиваются.
            Text("Для размещения объявлений")
                .font(YMFont.caption)
                .foregroundStyle(YMColor.onAccent.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    private var skeleton: some View {
        VStack(spacing: YMSpace.md) {
            SkeletonBox(radius: YMRadius.card).frame(height: 110)
            ForEach(0..<4, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 64) }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// П-27.11: ответ GET api/v1/wallet вместе с meta конверта (has_more).
/// Сам кошелёк разбирается как прежде (WalletInfo), meta приносит API.perform.
private final class WalletPage: Decodable, PageMetaReceiving {
    let info: WalletInfo
    private var meta: PageMeta?
    var hasMore: Bool { meta?.hasMore ?? false }
    init(from decoder: Decoder) throws { info = try decoder.singleValueContainer().decode(WalletInfo.self) }
    func receive(meta: PageMeta?) { self.meta = meta }
}

// MARK: - Строка истории

private struct WalletTxRow: View {
    let tx: WalletTx

    private var amount: Decimal { tx.amount ?? 0 }
    private var positive: Bool { amount >= 0 }
    private var label: String {
        if let l = tx.typeLabel, !l.isEmpty { return l }
        switch tx.type {
        case "topup":        return "Пополнение"
        case "order_pay":    return "Оплата заказа"
        case "order_refund": return "Возврат по заказу"
        case "correction":   return "Корректировка"
        default:
            let v = (tx.type ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "Операция" : v
        }
    }
    private var subtitle: String {
        var parts: [String] = []
        if let d = tx.description, !d.isEmpty { parts.append(d) }
        let d = DateFmt.short(tx.createdAt)
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 18))
                .foregroundStyle(YMColor.accent)
                .frame(width: 44, height: 44)
                .background(YMColor.accent.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(YMFont.body).foregroundStyle(YMColor.text)
                if !subtitle.isEmpty {
                    Text(subtitle).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(positive ? "+" : "−")\(Money.format(positive ? amount : -amount))")
                    .font(YMFont.headline)
                    .foregroundStyle(positive ? YMColor.statusDone : YMColor.text)
                Text("= " + Money.format(tx.balanceAfter ?? 0))
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.muted)
            }
        }
        .padding(.vertical, YMSpace.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(positive ? "плюс" : "минус") \(Money.format(positive ? amount : -amount))")
    }
}

// MARK: - Пополнение

private struct TopupSheet: View {
    let min: Decimal
    let max: Decimal
    let onSubmit: (Decimal, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var amountText = "1000"
    @State private var method = "card"
    @State private var localError: String?

    private let presets: [Decimal] = [500, 1000, 3000, 5000]
    private var allowedPresets: [Decimal] {
        presets.filter { p in p >= min && p <= max }
    }

    /// Строгий разбор: Decimal(string:) читает только начало строки, и
    /// вставленное «150 000» становилось 150 ₽ (проходило проверку минимума),
    /// а «1000,5,5» — 1000,5. Пробелы (и неразрывные) убираем, запятая → точка,
    /// остальное должно быть числом целиком, не больше двух знаков после точки
    /// («100,» при наборе — это ещё 100, кнопку не гасим).
    private var parsed: Decimal? {
        let t = amountText
            .filter { !$0.isWhitespace }
            .replacingOccurrences(of: ",", with: ".")
        guard !t.isEmpty,
              t.range(of: #"^[0-9]+(\.[0-9]{0,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: t)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сумма") {
                    TextField("Сумма, ₽", text: $amountText)
                        .keyboardType(.decimalPad)
                    HStack(spacing: 8) {
                        // Только суммы в пределах сервера (min_topup…max_topup):
                        // кнопка «500 ₽» при минимуме 1000 ₽ вела к отказу.
                        // Пресеты целые: в поле — «3000», как стартовое «1000»,
                        // а не «3000.00».
                        ForEach(allowedPresets, id: \.self) { p in
                            Button(Money.format(p)) { amountText = NSDecimalNumber(decimal: p).stringValue }
                                .font(YMFont.caption)
                                .buttonStyle(.bordered)
                        }
                    }
                    Text("От \(Money.format(min)) до \(Money.format(max)). Оплата откроется на защищённой странице ЮKassa.")
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }
                Section("Способ") {
                    Picker("Способ", selection: $method) {
                        Text("Картой").tag("card")
                        Text("СБП").tag("sbp")
                    }
                    .pickerStyle(.segmented)
                }
                if let e = localError {
                    Section { Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel) }
                }
                Section {
                    Button {
                        guard let a = parsed, a >= min, a <= max else {
                            localError = "Сумма должна быть от \(Money.format(min)) до \(Money.format(max))"
                            return
                        }
                        onSubmit(a, method)
                    } label: {
                        HStack { Spacer(); Text("Пополнить").bold(); Spacer() }
                    }
                }
            }
            // У цифровой клавиатуры суммы нет «Готово» — убирается жестом прокрутки.
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Пополнение кошелька")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Отмена") { dismiss() } }
            }
        }
    }
}
