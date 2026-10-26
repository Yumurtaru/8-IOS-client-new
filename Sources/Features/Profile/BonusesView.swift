//
//  BonusesView.swift — Мои бонусы (баланс по магазинам + история), премиум-клиент (iOS, SwiftUI)
//
//  Поток 1:1 со старым клиентом (3 IOS-client · Features/Profile/ProfileView.swift · BonusesView) и
//  Android-аналогом (9 Android-client-new · loyalty/BonusesScreen.kt):
//    • GET api/v1/profile/bonuses          → [BonusShopBalance] (shopId, shop, balance)
//    • GET api/v1/profile/bonuses/history  → [BonusTx] (id, shop, type, amount, createdAt)
//  Модели — из общих Models.swift.
//
//  Итоговый баланс = сумма balance по магазинам. Деньги — Money (Decimal), суммы из
//  @LenientDouble сводятся к Decimal через Money.dec. Токены YM.*, light+dark, Dynamic Type.
//  Состояния: загрузка (skeleton) / пусто / ошибка + «Повторить» / контент.
//

import SwiftUI

struct BonusesView: View {
    @State private var balances: [BonusShopBalance] = []
    @State private var history: [BonusTx] = []
    @State private var loading = true
    @State private var error: String?
    // П-23.2: история постранично (meta.has_more); старый сервер — одна страница.
    @State private var historyPage = 1
    @State private var historyHasMore = false
    @State private var historyLoadingMore = false
    /// Догрузка истории не прошла — раньше кнопка просто ничего не делала.
    @State private var historyMoreFailed = false
    /// Паритет с Android: история не загрузилась, а балансы есть — говорим об
    /// этом с «Повторить» (раньше блок просто пропадал: «операций нет»).
    @State private var historyError: String?

    private var total: Decimal { balances.reduce(0) { $0 + Money.dec($1.balance) } }

    var body: some View {
        Group {
            if loading {
                skeleton
            } else if let e = error {
                ErrorRetryView(message: e) { Task { await load() } }
            } else if balances.isEmpty && history.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои бонусы")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: Контент

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                heroCard

                if !balances.isEmpty {
                    Text("Баланс по магазинам")
                        .font(YMFont.title3)
                        .foregroundStyle(YMColor.text)
                        .padding(.top, YMSpace.xs)
                    VStack(spacing: YMSpace.md) {
                        // П-25 №3: ключ строки — shop_id (всегда число и уникален).
                        ForEach(Array(balances.enumerated()), id: \.element.rowKey) { _, b in
                            ShopBalanceRow(balance: b)
                        }
                    }
                }

                if let he = historyError, history.isEmpty {
                    VStack(alignment: .leading, spacing: YMSpace.sm) {
                        Text(he).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                        Button("Повторить") { Task { await load() } }
                            .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                    }
                    .padding(.top, YMSpace.sm)
                }

                if !history.isEmpty {
                    Text("История операций")
                        .font(YMFont.title3)
                        .foregroundStyle(YMColor.text)
                        .padding(.top, YMSpace.sm)
                    VStack(spacing: 0) {
                        // П-25 №3: в истории shop_id может быть null — ключ по id
                        // операции (догрузка страниц не путает строки).
                        ForEach(Array(history.enumerated()), id: \.element.stableId) { idx, t in
                            HistoryRow(tx: t)
                            if idx != history.count - 1 { Divider().overlay(YMColor.hairline) }
                        }
                    }
                    .padding(.horizontal, YMSpace.md)
                    .padding(.vertical, YMSpace.xs)
                    .ymCard()

                    // П-23.2: следующая страница истории по кнопке (нажатие
                    // во время загрузки не шлёт второй запрос).
                    if historyHasMore {
                        if historyMoreFailed && !historyLoadingMore {
                            Text("Не удалось загрузить ещё. Нажмите, чтобы повторить.")
                                .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                                .frame(maxWidth: .infinity)
                        }
                        Button { Task { await loadMoreHistory() } } label: {
                            Group {
                                if historyLoadingMore { ProgressView() }
                                else { Text("Показать ещё").font(.system(size: 14.5, weight: .heavy)).foregroundStyle(YMColor.accent) }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.plain)
                        .disabled(historyLoadingMore)
                    }
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
    }

    /// Hero-карта: суммарный бонусный баланс на золотом градиенте.
    private var heroCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text("Всего бонусов")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.onAccent.opacity(0.9))
            Text(Money.format(total))
                .font(YMFont.largeTitle)
                .foregroundStyle(YMColor.onAccent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    // MARK: Состояния

    private var skeleton: some View {
        VStack(spacing: YMSpace.md) {
            SkeletonBox(radius: YMRadius.card).frame(height: 110)
            ForEach(0..<4, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 64) }
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var emptyState: some View {
        VStack(spacing: YMSpace.sm) {
            Text("🎁").font(.system(size: 44))
            Text("Бонусов пока нет")
                .font(YMFont.title3)
                .foregroundStyle(YMColor.text)
            Text("Делайте заказы и копите бонусы.")
                .font(YMFont.body)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(YMSpace.xl)
    }

    // MARK: Данные

    private func load() async {
        loading = true; error = nil
        do {
            balances = try await API.shared.list("api/v1/profile/bonuses")
            // История — best-effort: её отсутствие не должно ронять экран.
            // П-23.2: первая страница + признак has_more (нет meta — страниц больше нет).
            var p: Page<BonusTx>? = nil
            var histFailed: String? = nil
            do {
                let fetched: Page<BonusTx> = try await API.shared.page("api/v1/profile/bonuses/history")
                p = fetched
            } catch is CancellationError {
            } catch {
                histFailed = (error as? APIError)?.errorDescription ?? "Не удалось загрузить историю бонусов"
            }
            // Паритет с Android: истории нет и балансов нет — это ошибка, а не
            // «Бонусов пока нет» (без связи человек решал, что баллы пропали).
            if let hf = histFailed, balances.isEmpty { self.error = hf }
            historyError = balances.isEmpty ? nil : histFailed
            history = p?.items ?? []
            historyPage = 1
            historyMoreFailed = false
            historyHasMore = (p?.hasMore ?? false) && !(p?.items.isEmpty ?? true)
        } catch is CancellationError {
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    /// П-23.2: следующая страница истории. Пустая страница = конец; дубли по id
    /// на стыке страниц отбрасываем; сбой — кнопка остаётся для повтора.
    private func loadMoreHistory() async {
        guard historyHasMore, !historyLoadingMore else { return }
        historyLoadingMore = true
        defer { historyLoadingMore = false }
        let next = historyPage + 1
        historyMoreFailed = false
        let p: Page<BonusTx>
        do {
            p = try await API.shared.page("api/v1/profile/bonuses/history", query: ["page": String(next)])
        } catch is CancellationError {
            return
        } catch {
            historyMoreFailed = true
            return
        }
        let known = Set(history.compactMap(\.id))
        history += p.items.filter { $0.id == nil || !known.contains($0.id!) }
        historyPage = next
        historyHasMore = p.hasMore && !p.items.isEmpty
    }
}

// MARK: - Строка баланса по магазину

private struct ShopBalanceRow: View {
    let balance: BonusShopBalance

    var body: some View {
        HStack(spacing: YMSpace.md) {
            Image(systemName: "star.fill")
                .font(.system(size: 18))
                .foregroundStyle(YMColor.accent)
                .frame(width: 44, height: 44)
                .background(YMColor.accent.opacity(0.16),
                            in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
            Text(shopName)
                .font(YMFont.headline)
                .foregroundStyle(YMColor.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Money.format(Money.dec(balance.balance)))
                .font(YMFont.headline)
                .foregroundStyle(YMColor.accent)
        }
        .padding(YMSpace.md)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shopName): \(Money.format(Money.dec(balance.balance)))")
    }

    private var shopName: String {
        let v = (balance.shop ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "Магазин" : v
    }
}

// MARK: - Строка истории операций

private struct HistoryRow: View {
    let tx: BonusTx

    /// П-22.4: знак — по type (earn «+», spend/expire «−»), сумма — по модулю:
    /// в старых строках знак amount бывает неверным («−-10 ₽»). Неизвестный
    /// type — по знаку самой суммы.
    private var isEarn: Bool {
        switch tx.type {
        case "earn":            return true
        case "spend", "expire": return false
        default:                return (tx.amount ?? 0) >= 0
        }
    }
    private var amountText: String { Money.format(abs(tx.amount ?? 0)) }
    private var label: String {
        switch tx.type {
        case "earn":   return "Начислено"
        case "spend":  return "Списано"
        case "expire": return "Сгорело"
        default:
            let v = (tx.type ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "Операция" : v
        }
    }
    private var subtitle: String {
        var parts: [String] = []
        if let s = tx.shop, !s.isEmpty { parts.append(s) }
        let d = DateFmt.short(tx.createdAt)
        if !d.isEmpty { parts.append(d) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(YMFont.body)
                    .foregroundStyle(YMColor.text)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.muted)
                }
            }
            Spacer(minLength: 8)
            Text("\(isEarn ? "+" : "−")\(amountText)")
                .font(YMFont.headline)
                .foregroundStyle(isEarn ? YMColor.statusDone : YMColor.muted)
        }
        .padding(.vertical, YMSpace.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(isEarn ? "плюс" : "минус") \(amountText)")
    }
}
