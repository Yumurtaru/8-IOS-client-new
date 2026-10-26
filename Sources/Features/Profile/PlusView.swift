//
//  PlusView.swift — Yumurta Plus (подписка клиента), премиум-клиент (iOS, SwiftUI)
//
//  Поток 1:1 со старым клиентом (3 IOS-client · Features/Plus/PlusView.swift) и
//  Android-аналогом (9 Android-client-new · loyalty/PlusScreen.kt):
//    • GET  api/v1/plus            → PlusInfo (active/until/priceMonth/cashbackBonus/benefits)
//    • POST api/v1/plus/subscribe  → PayOnlineResp (confirmationUrl/paymentId) — разовый платёж YooKassa
//    • POST api/v1/plus/activate   ← {payment_id} → PlusActivateResp (active/until)
//
//  Оплата: открываем confirmationUrl во внешнем браузере (openURL). При возврате в
//  приложение (scenePhase → .active) пробуем активировать подписку по payment_id —
//  та же логика, что ON_RESUME на Android.
//
//  Деньги — ТОЛЬКО Money (Decimal). Токены YM.*, light+dark, Dynamic Type, Reduce Motion.
//  Состояния: загрузка (skeleton) / ошибка + «Повторить» / контент.
//

import SwiftUI

// MARK: - Модели (локально: в общих Models.swift отсутствуют)

/// Ответ GET api/v1/plus. Ключи snake_case → camelCase через .convertFromSnakeCase.
/// Деньги — @LenientDecimal (сервер может отдать "199.00" строкой).
struct PlusInfo: Decodable {
    let active: Bool?
    let until: String?
    @LenientDecimal var priceMonth: Decimal?
    @LenientDouble var cashbackBonus: Double?
    let benefits: [String]?
    /// false — оформление выключено на сервере; кнопку не показываем.
    let available: Bool?
}
/// Ответ POST api/v1/plus/activate.
struct PlusActivateResp: Decodable {
    let active: Bool?
    let until: String?
}
/// Тело активации (camelCase → snake_case: payment_id).
private struct PlusActivateBody: Encodable { let paymentId: String }

struct PlusView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var info: PlusInfo?
    @State private var loading = true
    @State private var error: String?
    @State private var busy = false
    @State private var message: String?
    // Номер платежа храним и на диске: пока человек платит в приложении банка,
    // iOS может выгрузить наше, а активация подписки идёт только по этому номеру.
    // Раньше после такого возврата деньги были списаны, а «Оформить» висело снова.
    @State private var pendingPaymentId: String? = PlusView.storedPending()
    /// Прошлый платёж не подтвердился — следующее нажатие создаёт новый.
    @State private var payAgainAllowed = false
    @State private var activating = false
    static let pendingKey = "plus_pending_payment_id"
    static let pendingAtKey = "plus_pending_payment_at"
    /// Брошенный или отклонённый платёж не висит вечно: раньше каждый заход
    /// на экран дёргал активацию, а первое «Оформить» требовало второго нажатия.
    static let pendingTTL: TimeInterval = 24 * 60 * 60

    static func storedPending() -> String? {
        let d = UserDefaults.standard
        guard let id = d.string(forKey: pendingKey), !id.isEmpty else { return nil }
        let now = Date().timeIntervalSince1970
        let at = d.double(forKey: pendingAtKey)
        if at <= 0 { d.set(now, forKey: pendingAtKey); return id }   // сохранён прежней версией — считаем от сейчас
        if now - at > pendingTTL { d.removeObject(forKey: pendingKey); d.removeObject(forKey: pendingAtKey); return nil }
        return id
    }

    private func setPending(_ id: String?) {
        pendingPaymentId = id
        let d = UserDefaults.standard
        if let id { d.set(id, forKey: Self.pendingKey); d.set(Date().timeIntervalSince1970, forKey: Self.pendingAtKey) }
        else { d.removeObject(forKey: Self.pendingKey); d.removeObject(forKey: Self.pendingAtKey) }
    }

    var body: some View {
        Group {
            if loading {
                skeleton
            } else if let e = error {
                ErrorRetryView(message: e) { Task { await load() } }
            } else if let i = info {
                content(i)
            } else {
                ErrorRetryView(message: "Нет данных") { Task { await load() } }
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Yumurta Plus")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await load()
            if pendingPaymentId != nil { await tryActivate() }
        }
        // Возврат из браузера оплаты → пробуем активировать подписку.
        // Уведомление ЮKassa доходит до сервера с задержкой (бывает 10–20 с):
        // единственная проверка сразу после возврата из банка почти всегда
        // отвечала «не подтверждена», и подписка включалась лишь при следующем
        // открытии экрана. Теперь проверяем ещё несколько раз с паузой 3 с.
        .onChange(of: scenePhase) { phase in
            if phase == .active, pendingPaymentId != nil { Task { await tryActivate(attempts: 6) } }
        }
    }

    // MARK: Контент

    private func content(_ i: PlusInfo) -> some View {
        ScrollView {
            VStack(spacing: YMSpace.lg) {
                heroCard(i)
                if let benefits = i.benefits, !benefits.isEmpty { benefitsCard(benefits) }
                if let m = message, !m.isEmpty {
                    Text(m)
                        .font(YMFont.subhead)
                        .foregroundStyle(YMColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if i.available == false {
                    Text("Оформление подписки сейчас недоступно")
                        .font(YMFont.subhead)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    subscribeButton(i)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
    }

    /// Hero-карта статуса: золотой градиент.
    private func heroCard(_ i: PlusInfo) -> some View {
        let active = i.active ?? false
        return VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text(active ? "✨ Plus активна" : "✨ Yumurta Plus")
                .font(YMFont.title2)
                .foregroundStyle(YMColor.onAccent)
            Text(active
                 // «2026-11-09» → «09.11.2026»: ISO-дату человеку не показываем.
                 ? "Действует до \(DateFmt.day(i.until) ?? String(i.until?.prefix(10) ?? "—"))"
                 : "Подписка для тех, кто заказывает часто")
                .font(YMFont.callout)
                .foregroundStyle(YMColor.onAccent.opacity(0.85))
            if let cb = i.cashbackBonus, cb > 0 {
                Text("Повышенный кэшбэк +\(formatCashback(cb))%")
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.onAccent)
                    .padding(.top, YMSpace.xs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    /// Список бенефитов.
    private func benefitsCard(_ benefits: [String]) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Что даёт Plus")
                .font(YMFont.headline)
                .foregroundStyle(YMColor.text)
            ForEach(Array(benefits.enumerated()), id: \.offset) { _, b in
                HStack(spacing: YMSpace.sm) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(YMColor.accent)
                        .frame(width: 22, height: 22)
                        .background(YMColor.accent.opacity(0.16), in: Circle())
                    Text(b)
                        .font(YMFont.body)
                        .foregroundStyle(YMColor.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard()
    }

    private func subscribeButton(_ i: PlusInfo) -> some View {
        let active = i.active ?? false
        let price = Money.format(i.priceMonth ?? 0)
        return Button(action: subscribe) {
            HStack {
                if busy { ProgressView().tint(YMColor.onAccent) }
                else { Text((active ? "Продлить за " : "Оформить за ") + price + "/мес") }
            }
        }
        .buttonStyle(YMPrimaryButtonStyle())
        .disabled(busy)
    }

    // MARK: Скелетон

    private var skeleton: some View {
        VStack(spacing: YMSpace.lg) {
            SkeletonBox(radius: YMRadius.card).frame(height: 120)
            SkeletonBox(radius: YMRadius.card).frame(height: 200)
            SkeletonBox().frame(height: 54)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Данные

    private func load() async {
        loading = true; error = nil
        do {
            info = try await API.shared.get("api/v1/plus")
        } catch is CancellationError {
            // отмена задачи — не показываем ошибку
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    private func subscribe() {
        guard !busy else { return }
        busy = true; message = nil
        Task {
            defer { busy = false }
            // Есть неподтверждённый платёж — сначала проверяем его. Раньше каждое
            // нажатие создавало новый платёж ЮKassa, и после возврата из банка
            // («оплата ещё не подтверждена») человек платил второй раз.
            if pendingPaymentId != nil, Self.storedPending() == nil { setPending(nil) }
            if pendingPaymentId != nil && !payAgainAllowed {
                // Проверка уже идёт (вернулись из банка) — дождёмся её, а не
                // разрешаем новый платёж без проверки.
                if activating { message = "Проверяем прошлую оплату…"; return }
                if await tryActivate() { return }
                payAgainAllowed = true
                message = "Прошлая оплата ещё не подтверждена. Если вы её не завершили — нажмите ещё раз, чтобы оплатить заново."
                return
            }
            do {
                let r: PayOnlineResp = try await API.shared.post("api/v1/plus/subscribe")
                payAgainAllowed = false
                setPending(r.paymentId)
                if let link = r.confirmationUrl, let url = URL(string: link) {
                    Haptics.light()
                    openURL(url)
                } else {
                    message = "Не удалось создать платёж — попробуйте позже"
                }
            } catch {
                message = (error as? APIError)?.errorDescription ?? "Ошибка оплаты"
            }
        }
    }

    /// true — подписка активирована. Параллельные проверки (каждый возврат в
    /// приложение) не запускаем.
    @discardableResult
    private func tryActivate(attempts: Int = 1) async -> Bool {
        guard !activating else { return false }
        guard Self.storedPending() != nil else { if pendingPaymentId != nil { setPending(nil) }; return false }
        activating = true
        defer { activating = false }
        var notConfirmed = false
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if Task.isCancelled { break }
            }
            guard let pid = Self.storedPending() else { if pendingPaymentId != nil { setPending(nil) }; return false }
            do {
                let r: PlusActivateResp = try await API.shared.post("api/v1/plus/activate",
                                                                    body: PlusActivateBody(paymentId: pid))
                if r.active == true {
                    setPending(nil)
                    payAgainAllowed = false
                    message = "Yumurta Plus активна ✨"
                    Haptics.success()
                    await load()
                    return true
                } else {
                    notConfirmed = true
                }
            } catch {
                // оплата ещё не прошла — оставляем pendingPaymentId, проверим при следующем возврате
            }
        }
        if notConfirmed { message = "Оплата ещё не подтверждена — проверим при следующем открытии" }
        return false
    }

    private func formatCashback(_ v: Double) -> String {
        // Дробный процент — с запятой («+1,5%»), а не «+1.5%».
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Общий блок ошибки + «Повторить»

/// Единый экран ошибки для премиум-детальных экранов лояльности.
struct ErrorRetryView: View {
    let message: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: YMSpace.md) {
            Text("😕").font(.system(size: 44))
            Text(message)
                .font(YMFont.body)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
            Button(action: onRetry) {
                Text("Повторить")
                    .font(YMFont.headline)
                    .foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xl)
                    .frame(height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(YMSpace.xl)
    }
}
