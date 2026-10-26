//
//  GiftCardView.swift — Подарочная карта (premium-клиент)
//
//  Экран «Подарочная карта»: ввод кода + «Проверить и активировать», показ баланса, статуса и срока.
//  Токены YM.*, light+dark, Dynamic Type, Reduce Motion. Состояния: idle / загрузка / результат / ошибка+Повторить.
//
//  ПРИВЯЗКА К API (как в старом GiftCardView + Android-аналог):
//    • GET api/v1/gift-cards/{code} → GiftCard { code, balance, status, expiresAt }
//
//  ДЕНЬГИ: GiftCard.balance форматируем ТОЛЬКО через Money.format(Decimal). Никогда не Double напрямую.
//  Пушится в NavigationStack профиля → системная кнопка «Назад» (как AddressesView/BookingsView).
//

import SwiftUI

struct GiftCardView: View {
    @State private var code = ""
    @State private var card: GiftCard?
    @State private var loading = false
    @State private var error: String?
    /// П-27.12: привязка найденной карты к аккаунту
    /// (POST api/profile/giftcard/activate {code}) — только для вошедшего.
    @ObservedObject private var session = Session.shared
    @State private var activating = false
    @State private var activateResult: (text: String, ok: Bool)?

    private var canCheck: Bool {
        code.trimmingCharacters(in: .whitespaces).count >= 4 && !loading
    }

    var body: some View {
        ScrollView {
            VStack(spacing: YMSpace.lg) {
                heroCard
                inputSection

                if loading {
                    loadingBlock
                } else if let c = card {
                    balanceCard(c)
                } else if let e = error {
                    errorBlock(e)
                }
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Подарочная карта")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Hero (золотой градиент)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Image(systemName: "giftcard.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(YMColor.onAccent)
            Text("Подарочная карта")
                .font(YMFont.title3).foregroundStyle(YMColor.onAccent)
            // Экран только проверяет баланс — «и активировать её» обещало
            // действие, которого здесь нет (кнопку уже переименовали).
            Text("Введите код с карты, чтобы проверить её баланс и срок действия.")
                .font(YMFont.callout).foregroundStyle(YMColor.onAccent.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xxl)
        .background(
            LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
        )
    }

    // MARK: - Ввод кода

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Код карты").font(YMFont.title3).foregroundStyle(YMColor.text)
            TextField("Например, GIFT-XXXX-XXXX", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(YMFont.body)
                .foregroundStyle(YMColor.text)
                .padding(.horizontal, YMSpace.md)
                .frame(height: 54)
                .background(YMColor.surface2,
                            in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .onChange(of: code) { _ in error = nil; card = nil; activateResult = nil }

            Button { Haptics.light(); check() } label: {
                Group {
                    if loading {
                        ProgressView().tint(YMColor.onAccent)
                    } else {
                        // Экран только проверяет баланс (GET), активации нет —
                        // «и активировать» обещало то, чего не происходит.
                        Text("Проверить баланс").font(YMFont.headline)
                    }
                }
                .foregroundStyle(canCheck ? YMColor.onAccent : YMColor.muted)
                .frame(maxWidth: .infinity, minHeight: 54)
                .background {
                    if canCheck {
                        LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                       startPoint: .leading, endPoint: .trailing)
                            .clipShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .fill(YMColor.surface2)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!canCheck)
        }
    }

    // MARK: - Загрузка

    private var loadingBlock: some View {
        ProgressView().tint(YMColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, YMSpace.xxl)
    }

    // MARK: - Результат: баланс

    private func balanceCard(_ c: GiftCard) -> some View {
        let active = isActive(c.status)
        return VStack(alignment: .leading, spacing: YMSpace.md) {
            HStack(spacing: YMSpace.sm) {
                Text("✅").font(.system(size: 20))
                Text("Карта найдена").font(YMFont.headline).foregroundStyle(YMColor.text)
            }
            VStack(alignment: .leading, spacing: YMSpace.xs) {
                Text("Баланс").font(YMFont.caption).foregroundStyle(YMColor.muted)
                Text(Money.format(Money.dec(c.balance)))
                    .font(YMFont.largeTitle).foregroundStyle(YMColor.accent)
            }
            infoRow("Статус", statusLabel(c.status), valueColor: active ? YMColor.statusDone : YMColor.muted)
            if let e = c.expiresAt, !e.isEmpty {
                // Срок — со временем (карта перестаёт действовать в этот момент);
                // дата другого года теперь показывается с годом (DateFmt.short).
                infoRow("Действует до", DateFmt.short(e))   // с временем: карта перестаёт действовать в этот момент
            }
            // П-27.12: активную карту можно привязать к своему аккаунту. Ответы
            // сервера 404 / 400 / 409 / 429 — его текстом; свою карту повторно — 200.
            if active && session.isLoggedIn {
                if let r = activateResult {
                    Text(r.text).font(YMFont.callout)
                        .foregroundStyle(r.ok ? YMColor.statusDone : YMColor.statusCancel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if activateResult?.ok != true {
                    Button { Haptics.light(); activate() } label: {
                        Group {
                            if activating { ProgressView().tint(YMColor.accent) }
                            else { Text("Привязать к аккаунту").font(YMFont.headline).foregroundStyle(YMColor.accent) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .overlay(
                            RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                                .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(activating)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1)
        )
    }

    private func infoRow(_ label: String, _ value: String, valueColor: Color = YMColor.text) -> some View {
        HStack {
            Text(label).font(YMFont.callout).foregroundStyle(YMColor.muted)
            Spacer()
            Text(value).font(YMFont.subhead).foregroundStyle(valueColor)
        }
    }

    // MARK: - Ошибка + Повторить

    private func errorBlock(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Text("😔").font(.system(size: 34))
            Text(message).font(YMFont.body).foregroundStyle(YMColor.text).multilineTextAlignment(.center)
            Button { Haptics.light(); check() } label: {
                Text("Повторить").font(YMFont.headline).foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xl).padding(.vertical, YMSpace.sm)
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!canCheck)
        }
        .frame(maxWidth: .infinity)
        .padding(YMSpace.xl)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                .strokeBorder(YMColor.statusCancel.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Данные

    private func check() {
        let input = code.trimmingCharacters(in: .whitespaces)
        guard input.count >= 4, !loading else { return }
        loading = true; error = nil; card = nil
        Task {
            // Код правят, пока идёт проверка: ответ по прежнему коду раньше
            // ложился под новый («Карта найдена» с чужим балансом).
            var stillSame: Bool { code.trimmingCharacters(in: .whitespaces) == input }
            do {
                // «/» в коде не должен менять путь запроса.
                var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "/")
                let path = "api/v1/gift-cards/\(input.addingPercentEncoding(withAllowedCharacters: allowed) ?? input)"
                let c: GiftCard = try await API.shared.get(path)
                if stillSame { Haptics.success(); card = c }
            } catch is CancellationError {
            } catch {
                if stillSame {
                    Haptics.error()
                    // 404 без текста сервера: общее «Не найдено — возможно, уже
                    // удалено» про карту звучало странно — говорим прямо.
                    let api = error as? APIError
                    if api?.rejectStatus == 404, api?.errorDescription == APIError.httpText(404) {
                        self.error = "Карта с таким кодом не найдена. Проверьте код"
                    } else {
                        self.error = api?.errorDescription ?? "Сертификат не найден"
                    }
                }
            }
            loading = false
        }
    }

    /// П-27.12: привязать карту к аккаунту. Конверт сайта {ok, data:{balance, amount}}.
    private func activate() {
        let input = code.trimmingCharacters(in: .whitespaces)
        guard !activating, input.count >= 4 else { return }
        activating = true; activateResult = nil
        Task {
            do {
                let _: GiftActivateResp = try await API.shared.post("api/profile/giftcard/activate",
                                                                    body: ["code": input])
                if code.trimmingCharacters(in: .whitespaces) == input {
                    Haptics.success()
                    activateResult = ("Карта привязана к вашему аккаунту", true)
                }
            } catch is CancellationError {
            } catch {
                if code.trimmingCharacters(in: .whitespaces) == input {
                    Haptics.error()
                    activateResult = ((error as? LocalizedError)?.errorDescription ?? "Не удалось привязать карту", false)
                }
            }
            activating = false
        }
    }

    // MARK: - Хелперы статуса

    private func isActive(_ status: String?) -> Bool {
        guard let s = status?.trimmingCharacters(in: .whitespaces).lowercased(), !s.isEmpty else { return true }
        return ["active", "активна", "активный", "valid", "ok"].contains(s)
    }

    private func statusLabel(_ raw: String?) -> String {
        guard let r = raw?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return "Активна" }
        switch r.lowercased() {
        case "active", "активна", "активный", "valid", "ok": return "Активна"
        case "used", "spent", "использована":                return "Использована"
        case "expired", "истекла":                           return "Истёк срок"
        case "blocked", "disabled", "заблокирована":         return "Заблокирована"
        // Паритет с Android: неактивная карта (касса выпускает карту «в ожидании») —
        // раньше человек видел английское слово статуса.
        case "pending", "inactive":                          return "Не активирована"
        default:                                             return r
        }
    }
}

/// П-27.12: ответ привязки карты — {balance, amount}; поля экрану не нужны,
/// но разбираются толерантно (строки "500.00" или числа).
private struct GiftActivateResp: Decodable {
    @LenientDecimal var balance: Decimal?
    @LenientDecimal var amount: Decimal?
}
