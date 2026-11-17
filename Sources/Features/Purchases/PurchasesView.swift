import SwiftUI

//
//  PurchasesView.swift — «Профиль → Покупки» (П-84): список покупок и «Добавить чек».
//  GET api/v1/profile/purchases?channel=store|online|all&page&per_page=20 (meta.has_more),
//  POST api/v1/profile/purchases/claim {qr}. Вход: Профиль → «Покупки».
//  Паритет с Android: ui/screens/profile/PurchasesScreen.kt.
//

private enum PurchasesSheet: Identifiable {
    case scan
    var id: Int { 0 }
}

/// Итог «Добавить чек» для баннера над списком.
private struct PurchaseNotice {
    var text: String
    var isError: Bool
    var openId: Int?
}

struct PurchasesView: View {
    /// Открыть карточку покупки (экран кладёт маршрут в стек профиля).
    let onOpen: (Int) -> Void
    /// Гость нажал «Войти».
    let onLogin: () -> Void

    @EnvironmentObject private var session: Session

    @State private var channel: PurchaseChannel = .store
    @State private var rows: [Purchase]? = nil
    @State private var error: String?
    @State private var hasMore = false
    @State private var nextPage = 2
    @State private var moreFailed = false
    /// Поколение выдачи: ответ прежнего сегмента / обновления / «Показать ещё» отбрасывается.
    @State private var gen = 0
    @State private var moreBusy = false
    @State private var sheet: PurchasesSheet?
    @State private var claimBusy = false
    @State private var notice: PurchaseNotice?
    @State private var scannerMissing = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: YMForm.cardGap) {
                content
            }
            .padding(.horizontal, YMForm.screenPadding)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMUi.screenBg.ignoresSafeArea())
        .navigationTitle("Покупки")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if session.isLoggedIn {
                    Button("Добавить чек") { startScan() }
                        .disabled(claimBusy)
                }
            }
        }
        .task(id: channel) { await load() }
        // Другой сегмент — прежний список не показываем (поздний ответ отбросит счётчик поколения).
        .onChange(of: channel) { _ in
            gen += 1   // ответы «Показать ещё» прежнего сегмента отбрасываются сразу, до старта новой загрузки
            rows = nil; error = nil; hasMore = false; nextPage = 2; moreFailed = false; moreBusy = false
        }
        .onChange(of: session.isLoggedIn) { logged in
            if logged { Task { await load() } } else { rows = nil; notice = nil }
        }
        .refreshable { await load() }
        .sheet(item: $sheet) { _ in
            BarcodeScannerScreen(onCode: { code in handleScanned(code) },
                                 symbologies: [.qr],
                                 hint: "Наведите камеру на QR-код на кассовом чеке")
        }
        .alert("Сканер недоступен", isPresented: $scannerMissing) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Разрешите доступ к камере в настройках iPhone, чтобы добавить чек по QR-коду.")
        }
    }

    // MARK: Содержимое

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            guestBlock
        } else {
            YMSegmented(options: PurchaseChannel.allCases, selection: $channel, title: { $0.title })
            if let n = notice { noticeRow(n) }
            if claimBusy {
                Text("Проверяем чек…").ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
            }
            listBlock
        }
    }

    private var guestBlock: some View {
        VStack(spacing: YMSpace.md) {
            Text("Войдите, чтобы видеть покупки")
                .font(YMFont.body).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button { onLogin() } label: { Text("Войти") }
                .buttonStyle(YMPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, YMSpace.xxl)
    }

    @ViewBuilder private var listBlock: some View {
        if let list = rows {
            if list.isEmpty {
                emptyBlock
            } else {
                ForEach(list, id: \.rowId) { p in
                    Button { Haptics.light(); onOpen(p.rowId) } label: { PurchaseRowCard(p: p) }
                        .buttonStyle(.plain)
                }
                if hasMore {
                    LoadMoreFooter(page: nextPage, failed: moreFailed, onLoadMore: { await loadMore() })
                }
            }
        } else if let e = error {
            VStack(spacing: YMSpace.md) {
                Text(e).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                Button { Task { await load() } } label: { Text("Повторить") }
                    .buttonStyle(YMSecondaryButtonStyle())
            }
            .padding(.top, YMSpace.xl)
        } else {
            ProgressView().frame(maxWidth: .infinity).padding(.top, YMSpace.xxl)
        }
    }

    @ViewBuilder private var emptyBlock: some View {
        VStack(spacing: YMSpace.md) {
            if channel == .online {
                Text("Пока нет онлайн-покупок")
                    .font(YMFont.body).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
            } else {
                Text("Покажите QR-код карты на кассе — покупки появятся здесь")
                    .font(YMFont.body).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
                BonusCodeButton {
                    Text("Показать карту")
                        .font(YMFont.golos(15, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(YMColor.onAccent)
                        .frame(maxWidth: .infinity, minHeight: YMForm.buttonHeight)
                        .background(YMUi.accentFill, in: Capsule())
                }
                Button { startScan() } label: { Text("Добавить чек") }
                    .buttonStyle(YMSecondaryButtonStyle())
                    .disabled(claimBusy)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, YMSpace.xxl)
    }

    @ViewBuilder private func noticeRow(_ n: PurchaseNotice) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text(n.text)
                .font(YMFont.callout)
                .foregroundStyle(n.isError ? YMColor.statusCancel : YMColor.statusDone)
            if let id = n.openId {
                Button { onOpen(id) } label: { Text("Открыть покупку") }
                    .buttonStyle(YMSecondaryButtonStyle())
            }
        }
        .padding(YMForm.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
    }

    // MARK: Загрузка

    private func load() async {
        guard session.isLoggedIn else { return }
        gen += 1
        let my = gen
        let ch = channel
        moreBusy = false
        moreFailed = false
        do {
            let p: Page<Purchase> = try await API.shared.page(
                "api/v1/profile/purchases", query: ["channel": ch.rawValue, "page": "1", "per_page": "20"])
            if my != gen || Task.isCancelled { return }
            rows = PurchasesLogic.merge([], p.items)
            hasMore = p.hasMore
            nextPage = 2
            error = nil
        } catch {
            if my != gen || Task.isCancelled { return }
            // Сбой обновления не стирает уже показанный список.
            if rows == nil { self.error = error.userMessage ?? "Не удалось загрузить покупки" }
        }
    }

    private func loadMore() async {
        if moreBusy || !hasMore { return }
        moreBusy = true
        let my = gen
        let page = nextPage
        let ch = channel
        do {
            let p: Page<Purchase> = try await API.shared.page(
                "api/v1/profile/purchases", query: ["channel": ch.rawValue, "page": "\(page)", "per_page": "20"])
            if my != gen { return }
            rows = PurchasesLogic.merge(rows ?? [], p.items)
            hasMore = p.hasMore && !p.items.isEmpty
            nextPage = page + 1
            moreFailed = false
        } catch {
            if my == gen { moreFailed = true }
        }
        if my == gen { moreBusy = false }
    }

    // MARK: Добавить чек

    private func startScan() {
        guard !claimBusy else { return }
        if BarcodeScanner.isAvailable {
            Haptics.light()
            sheet = .scan
        } else {
            scannerMissing = true
        }
    }

    private func handleScanned(_ code: String) {
        Task { await claim(code) }
    }

    private func claim(_ raw: String) async {
        guard !claimBusy else { return }
        let qr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard PurchasesLogic.isReceiptQr(qr) else {
            Haptics.warning()
            notice = PurchaseNotice(text: "Это не QR кассового чека", isError: true, openId: nil)
            return
        }
        claimBusy = true
        notice = nil
        defer { claimBusy = false }
        do {
            let r: PurchaseClaimResponse = try await API.shared.post(
                "api/v1/profile/purchases/claim", body: PurchaseClaimBody(qr: qr))
            let id = r.purchase?.rowId ?? (r.id ?? 0)
            var text = "Чек добавлен"
            if let b = r.purchase?.bonusEarned, b > 0 { text += ". Начислено баллов: +\(PurchasesLogic.points(b))" }
            Haptics.success()
            notice = PurchaseNotice(text: text, isError: false, openId: nil)
            await reloadAfterClaim()
            if id > 0 {
                PurchaseFlash.text = text   // подсказка «Чек добавлен» — на карточке (как на Android)
                onOpen(id)
            }
        } catch {
            Haptics.warning()
            notice = failureNotice(error)
        }
    }

    private func reloadAfterClaim() async {
        if channel == .online { return }
        await load()
    }

    private func failureNotice(_ error: Error) -> PurchaseNotice {
        var text = error.userMessage ?? "Не удалось добавить чек. Попробуйте ещё раз"
        var openId: Int?
        if let api = error as? APIError {
            let d = api.rejectDetails
            // Декодер API — convertFromSnakeCase: ключи словаря details тоже могут прийти как purchaseId/retryAfter.
            let mine = d?["mine"]
            let pidRaw: String? = d?["purchase_id"] ?? d?["purchaseId"]
            let retryRaw: String? = d?["retry_after"] ?? d?["retryAfter"]
            if api.rejectStatus == 409, mine == "true" || mine == "1",
               let pid = pidRaw.flatMap({ Int($0) }), pid > 0 {
                openId = pid
            }
            if api.rejectStatus == 429 {
                let hint = PurchasesLogic.retryText(retryRaw)
                if !hint.isEmpty, !text.contains("мин") { text += " " + hint }
            }
        }
        return PurchaseNotice(text: text, isError: true, openId: openId)
    }
}

// MARK: - Карточка строки списка

private struct PurchaseRowCard: View {
    let p: Purchase

    var body: some View {
        let name = (p.shop?.name ?? "").isEmpty ? "Заведение" : (p.shop?.name ?? "")
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: YMSpace.md) {
                LogoBadge(url: API.imageURL(p.shop?.logo), letter: name.prefix(1).uppercased(), size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(YMFont.headline).foregroundStyle(YMColor.text).lineLimit(1)
                    Text(PurchasesLogic.whenLabel(p.createdAt))
                        .ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
                }
                Spacer(minLength: 8)
                Text(Money.format(p.total ?? 0))
                    .font(.custom(YMFont.golosName(.heavy), fixedSize: 16))
                    .foregroundStyle(YMColor.text)
            }
            HStack(spacing: 8) {
                pointsBadges
                if p.refunded == true { refundBadge }
                Spacer(minLength: 0)
            }
            Text(detailLine).ymText(YMText.caption).foregroundStyle(YMUi.textSecondary)
        }
        .padding(YMForm.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var pointsBadges: some View {
        if let e = p.bonusEarned, e > 0 {
            Text("+\(PurchasesLogic.points(e))")
                .ymFont(12, weight: .bold).foregroundStyle(YMColor.statusDone)
        }
        if let s = p.bonusSpent, s > 0 {
            Text("−\(PurchasesLogic.points(s))")
                .ymFont(12, weight: .bold).foregroundStyle(YMColor.statusCancel)
        }
    }

    private var refundBadge: some View {
        let sum: String = {
            if let r = p.refundTotal, r > 0 { return " " + Money.format(r) }
            return ""
        }()
        return Text("Возврат\(sum)")
            .ymFont(11, weight: .bold)
            .foregroundStyle(YMColor.statusCancel)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(YMColor.statusCancel.opacity(0.14), in: Capsule())
    }

    private var detailLine: String {
        var bits: [String] = []
        if let t = p.paymentMethodTitle, !t.isEmpty { bits.append(t) }
        if let n = p.itemsCount, n > 0 { bits.append("позиций: \(n)") }
        return bits.joined(separator: " · ")
    }
}
