//
//  ReferralView.swift — Реферальная программа (premium-клиент)
//
//  Экран «Пригласить друга»: свой код-приглашение, «Поделиться» (ShareLink) и «Копировать»,
//  счётчик приглашённых, ввод чужого кода + «Применить», блок «Как это работает».
//  Токены YM.*, light+dark, Dynamic Type, Reduce Motion. Состояния: загрузка/ошибка+Повторить/контент.
//
//  ПРИВЯЗКА К API (как в старом ReferralView + Android-аналог):
//    • GET  api/v1/referral         → ReferralInfo { code, invited, reward }
//    • POST api/v1/referral/apply   ← { code } → ReferralApplyResp { applied?, message?, reward? }
//
//  Пушится в NavigationStack профиля → системная кнопка «Назад» (как AddressesView/BookingsView).
//

import SwiftUI
import UIKit

struct ReferralView: View {
    /// Необязательный пред-заполненный код друга (например, из deeplink /r/CODE).
    var prefillCode: String? = nil

    @EnvironmentObject private var session: Session
    @State private var info: ReferralInfo?
    @State private var loading = true
    @State private var loadError: String?

    // Применение чужого кода.
    @State private var friendCode = ""
    @State private var didPrefill = false
    @State private var applying = false
    @State private var applyMsg: String?
    @State private var applyOk = false

    private var reward: Int { info?.reward ?? 200 }
    private var code: String { info?.code?.trimmingCharacters(in: .whitespaces) ?? "" }
    private var invited: Int { info?.invited ?? 0 }
    /// Сумма награды общим форматом денег («1 000 ₽»): было «1000 ₽»,
    /// не как на остальных экранах.
    private var rewardText: String { Money.format(Decimal(reward)) }

    private var shareText: String {
        let c = code.isEmpty ? "" : code
        let r = rewardText
        return "Заказывай в Yumurta по моему коду \(c) — получишь \(r) на первый заказ! https://yumurta.ru/r/\(c)"
    }

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Пригласить друга")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Ссылку-приглашение /r/КОД чаще всего открывает тот, кто ещё не
            // вошёл. Раньше гость получал «Сессия истекла» с вечным «Повторить»,
            // и код друга пропадал. Теперь — вход; после него (.task срабатывает
            // снова при возврате на экран) код применяется.
            guard session.isLoggedIn else { loading = false; return }
            await load()
            // Код из ссылки применяем один раз. После «Код принят» поле очищается,
            // и при возврате на экран (.task снова) код уходил повторно — ответ
            // «код уже применён» затирал сообщение об успехе.
            if !didPrefill, let p = prefillCode?.trimmingCharacters(in: .whitespaces), !p.isEmpty, friendCode.isEmpty {
                didPrefill = true
                friendCode = p.uppercased()
                await apply()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !session.isLoggedIn {
            guestState
        } else if loading {
            VStack(spacing: YMSpace.lg) {
                SkeletonBox(radius: YMRadius.card).frame(height: 150)
                SkeletonBox(radius: YMRadius.card).frame(height: 170)
                SkeletonBox(radius: YMRadius.card).frame(height: 120)
            }
        } else if let e = loadError, info == nil {
            errorState(e)
        } else {
            VStack(spacing: YMSpace.lg) {
                heroCard
                codeCard
                if invited > 0 { invitedRow }
                applyCard
                howItWorksCard
            }
        }
    }

    // MARK: - Гость (вход не выполнен)

    private var guestState: some View {
        let p = (prefillCode ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        return VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("🎁").font(.system(size: 34))
            Text(p.isEmpty
                 ? "Войдите или зарегистрируйтесь — здесь появится ваш код-приглашение."
                 : "Код друга \(p) применится после входа или регистрации.")
                .font(YMFont.body).foregroundStyle(YMColor.text)
            NavigationLink { AuthView() } label: { Text("Войти") }
                .buttonStyle(YMPrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .ymCard()
    }

    // MARK: - Состояние ошибки

    private func errorState(_ message: String) -> some View {
        VStack(spacing: YMSpace.md) {
            Text("😔").font(.system(size: 44))
            Text(message).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
            Button { Haptics.light(); Task { await load() } } label: {
                Text("Повторить").font(YMFont.headline)
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .frame(maxWidth: 220)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xl).padding(.top, 40)
    }

    // MARK: - Hero (золотой градиент)

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("🎁").font(.system(size: 34))
            Text("Приглашайте друзей — получайте по \(rewardText)")
                .font(YMFont.title3).foregroundStyle(YMColor.onAccent)
            Text("Когда друг сделает первый заказ, \(rewardText) получите и вы, и он.")
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

    // MARK: - Свой код + Копировать/Поделиться

    private var codeCard: some View {
        VStack(spacing: YMSpace.md) {
            Text("Ваш код-приглашение").font(YMFont.caption).foregroundStyle(YMColor.muted)
            Text(code.isEmpty ? "———" : code)
                .font(.system(size: 30, weight: .heavy, design: .monospaced))
                .tracking(3)
                .foregroundStyle(YMColor.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, YMSpace.lg)
                .background(YMColor.accent.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                        .strokeBorder(YMColor.accent.opacity(0.4), lineWidth: 1)
                )
            HStack(spacing: YMSpace.sm) {
                Button { Haptics.light(); UIPasteboard.general.string = code } label: {
                    actionLabel("Копировать", "doc.on.doc", gold: false)
                }
                .buttonStyle(.plain)
                .disabled(code.isEmpty)
                .opacity(code.isEmpty ? 0.5 : 1)

                ShareLink(item: shareText) {
                    actionLabel("Поделиться", "square.and.arrow.up", gold: true)
                }
                .disabled(code.isEmpty)
                .opacity(code.isEmpty ? 0.5 : 1)
            }
        }
        .padding(YMSpace.xl)
        .ymCard()
    }

    private func actionLabel(_ title: String, _ icon: String, gold: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
            Text(title).font(YMFont.subhead)
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .foregroundStyle(gold ? YMColor.onAccent : YMColor.accent)
        .background {
            if gold {
                LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
            }
        }
    }

    // MARK: - Приглашено

    private var invitedRow: some View {
        HStack(spacing: YMSpace.md) {
            Text("👥").font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text("Вы уже пригласили").font(YMFont.caption).foregroundStyle(YMColor.muted)
                Text("\(invited) \(pluralInvited(invited))").font(YMFont.headline).foregroundStyle(YMColor.text)
            }
            Spacer(minLength: 0)
        }
        .padding(YMSpace.lg)
        .ymCard()
    }

    private func pluralInvited(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "друга" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "друга" }
        return "друзей"
    }

    // MARK: - Ввести код друга

    private var applyCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text("Ввести код друга").font(YMFont.title3).foregroundStyle(YMColor.text)
            HStack(spacing: YMSpace.sm) {
                TextField("Промокод друга", text: $friendCode)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(YMFont.body)
                    .foregroundStyle(YMColor.text)
                    .padding(.horizontal, YMSpace.md)
                    .frame(height: 54)
                    .background(YMColor.surface2,
                                in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .onChange(of: friendCode) { new in if !new.isEmpty { applyMsg = nil } }   // очистка поля после «Код принят» не стирает сообщение

                Button { Haptics.light(); Task { await apply() } } label: {
                    Group {
                        if applying {
                            ProgressView().tint(YMColor.onAccent)
                        } else {
                            Text("Применить").font(YMFont.headline)
                        }
                    }
                    .foregroundStyle(canApply ? YMColor.onAccent : YMColor.muted)
                    .padding(.horizontal, YMSpace.lg)
                    .frame(height: 54)
                    .background {
                        if canApply {
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
                .disabled(!canApply)
            }
            if let m = applyMsg {
                Text(m).font(YMFont.subhead)
                    .foregroundStyle(applyOk ? YMColor.statusDone : YMColor.statusCancel)
            }
            Text("Код можно ввести только до первого заказа.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        .padding(YMSpace.xl)
        .ymCard()
    }

    private var canApply: Bool {
        !friendCode.trimmingCharacters(in: .whitespaces).isEmpty && !applying
    }

    // MARK: - Как это работает

    private var howItWorksCard: some View {
        VStack(alignment: .leading, spacing: YMSpace.md) {
            Text("Как это работает").font(YMFont.title3).foregroundStyle(YMColor.text)
            howRow(1, "Поделитесь кодом с другом любым способом")
            howRow(2, "Друг вводит код и делает первый заказ")
            howRow(3, "Вы оба получаете по \(rewardText) на бонусный счёт")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.xl)
        .ymCard()
    }

    private func howRow(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .center, spacing: YMSpace.md) {
            Text("\(n)")
                .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                .frame(width: 32, height: 32)
                .background(YMColor.accent.opacity(0.14), in: Circle())
            Text(text).font(YMFont.callout).foregroundStyle(YMColor.muted)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Данные

    private func load() async {
        loading = true; loadError = nil
        do {
            info = try await API.shared.get("api/v1/referral")
        } catch is CancellationError {
            // Ушли с экрана посреди загрузки — это не ошибка («Не удалось загрузить»).
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Не удалось загрузить"
        }
        loading = false
    }

    private func apply() async {
        // Паритет с Android: друг присылает сообщение «Поделиться» целиком — со
        // ссылкой https://yumurta.ru/r/КОД. Вставленный текст уходил на сервер как
        // код и получал «Код не найден». Берём код из ссылки, если она есть.
        let raw = friendCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let clean = Self.codeFromLink(raw).uppercased()
        // Двойной тап «Применить» отправлял код дважды: второй ответ «код уже
        // применён» затирал сообщение об успехе.
        guard !clean.isEmpty, !applying else { return }
        applying = true; applyMsg = nil
        do {
            let res: ReferralApplyResp = try await API.shared.post(
                "api/v1/referral/apply", body: ReferralApplyBody(code: clean)
            )
            Haptics.success()
            applyOk = true
            applyMsg = res.message?.isEmpty == false
                ? res.message
                : "Код принят! Бонусы придут после вашего первого заказа."
            friendCode = ""
            await load()
        } catch {
            Haptics.error()
            applyOk = false
            applyMsg = (error as? APIError)?.errorDescription ?? "Не удалось применить код"
        }
        applying = false
    }
}

extension ReferralView {
    /// «…https://yumurta.ru/r/AB12…» → «AB12»; ссылки нет — текст как есть.
    static func codeFromLink(_ raw: String) -> String {
        guard let r = raw.range(of: "/r/") else { return raw }
        let tail = raw[r.upperBound...]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        var code = ""
        for ch in tail.unicodeScalars {
            if allowed.contains(ch) && ch.isASCII { code.unicodeScalars.append(ch) } else { break }
        }
        return code.isEmpty ? raw : code
    }
}

// MARK: - DTO применения кода (локально; поля 1:1 с сервером/Android)

/// Тело POST api/v1/referral/apply. camelCase → snake_case автоматически (здесь один ключ `code`).
private struct ReferralApplyBody: Encodable { let code: String }

/// Ответ применения кода. Все поля толерантно-опциональны (сервер может вернуть только success).
private struct ReferralApplyResp: Decodable {
    let applied: Bool?
    let message: String?
    @LenientInt var reward: Int?
}
