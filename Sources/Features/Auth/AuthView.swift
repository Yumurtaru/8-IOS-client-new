//
//  AuthView.swift
//  Yumurta — маркетплейс (iOS, SwiftUI)
//
//  Экран входа/регистрации премиум-клиента (flash call убран — дорого).
//
//   Вход:  POST api/v1/auth/login  {login, password}  → {user, token, refresh, redirect}
//          login — email ИЛИ телефон.
//   Регистрация (2 шага, подтверждение почты):
//     1) POST api/v1/auth/register/request {name, phone, email, password} → {sent, ttl, email, debug_code}
//        (сервер шлёт 6-значный код на почту)
//     2) POST api/v1/auth/register/confirm {email, code} → {user, token, refresh, redirect}
//
//  Токены сохраняются через Session.signIn(token, refresh:): access → "token"
//  (Authorization: Bearer), refresh → "refresh_token". isLoggedIn флипается реактивно.
//
//  API.post<T> декодирует уже env.data. Ключи snake_case (debug_code) маппятся
//  авто-конвертером .convertFromSnakeCase.
//

import SwiftUI

// MARK: - DTO (полезная нагрузка `data` конверта v1)

/// Ответ register/request: подтверждение отправки + замаскированный email + dev-код.
private struct RegRequestResult: Decodable {
    let sent: Bool?
    let ttl: Int?
    let email: String?      // замаскированный адрес для UI
    let debugCode: String?  // dev-режим (debug_code → debugCode)
}

/// Ответ login / register/confirm: токены доступа и продления.
private struct AuthTokens: Decodable {
    let token: String?
    let refresh: String?
    /// user.id из ответа входа — только чтобы узнать, тот же ли это человек.
    let user: AuthUser?
}

/// Из `user` берём один id. Разбор не бросает ошибок: неожиданная форма
/// `user` не должна ломать сам вход.
private struct AuthUser: Decodable {
    let id: Int?
    private enum K: String, CodingKey { case id }
    init(from decoder: Decoder) throws {
        var v: Int? = nil
        if let c = try? decoder.container(keyedBy: K.self),
           let w = try? c.decode(LenientInt.self, forKey: .id) { v = w.wrappedValue }
        id = v
    }
}

/// Кто входил в этом телефоне последним. Сессия, кончившаяся сама (401),
/// оставляет корзину, историю поиска и «недавно смотрели» — чтобы тот же
/// человек вошёл и продолжил. Но если входит ДРУГОЙ человек, раньше он
/// получал всё это от прежнего. Явный выход чистит данные сам и забывает id.
enum AuthLastUser {
    static let key = "auth_last_user_id"
    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
    /// Вход, сделанный до этой версии: id ещё не записан — запоминаем по профилю.
    static func seed(_ uid: Int?) {
        guard let uid, uid > 0, UserDefaults.standard.integer(forKey: key) == 0 else { return }
        UserDefaults.standard.set(uid, forKey: key)
    }
    /// Профиль — точный источник: кто сейчас вошёл. Иначе после выхода по 401
    /// и входа другого человека без id в ответе чужим считались бы его же пуши.
    static func confirm(_ uid: Int?) {
        guard let uid, uid > 0 else { return }
        UserDefaults.standard.set(uid, forKey: key)
    }
    /// Вызывать до signIn. Другой id — чистим локальные данные прежнего.
    @MainActor static func switchTo(_ uid: Int?) {
        guard let uid, uid > 0 else { return }
        let prev = UserDefaults.standard.integer(forKey: key)
        if prev != 0 && prev != uid {
            Cart.shared.clear()
            SearchHistoryStore.clear()
            RecentStore.clear()
            // Черновик оформления (комментарий, стол, промокод) прежнего
            // человека не должен достаться новому.
            CheckoutDraft.clear()
        }
        UserDefaults.standard.set(uid, forKey: key)
    }
}

// MARK: - AuthView

struct AuthView: View {
    var onAuthed: (() -> Void)? = nil

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Вход по паролю; регистрация — форма → код с почты.
    private enum Step { case password, register, registerCode }
    @State private var step: Step = .password

    // Вход
    @State private var loginField = ""
    @State private var password = ""
    // Регистрация
    @State private var name = ""
    @State private var phone = ""
    @State private var regEmail = ""
    // Подтверждение почты
    @State private var code = ""
    @State private var sentMask: String?
    /// Повторная отправка кода: раньше ни паузы, ни отклика — каждое нажатие
    /// слало новое письмо (быстро упирались в лимит 429), а на экране ничего
    /// не менялось, и было непонятно, ушёл ли код. Теперь пауза 60 с с отсчётом.
    @State private var resendLeft = 0
    @State private var resendTimer: Task<Void, Never>?
    @State private var notice: String?

    @State private var busy = false
    @State private var error: String?

    @FocusState private var focused: Field?
    private enum Field { case login, password, name, code }

    // MARK: Нормализация / валидация

    private func normalizedPhone() -> String {
        let digits = phone.filter(\.isNumber)
        let d: String
        switch true {
        case digits.count == 11 && digits.hasPrefix("8"): d = "7" + digits.dropFirst()
        case digits.count == 11 && digits.hasPrefix("7"): d = digits
        case digits.count == 10:                          d = "7" + digits
        default:                                          d = digits
        }
        return "+" + d
    }

    /// Паритет с Android и сервером (isValidPhone: 7XXXXXXXXXX после нормализации):
    /// 10 цифр или 11, начиная с 7/8. Раньше подходили любые 10–11 цифр
    /// («9…» с лишней цифрой), и сервер отвечал «Некорректный телефон».
    private var phoneValid: Bool {
        let d = phone.filter { $0.isASCII && $0.isNumber }
        if d.count == 10 { return true }
        return d.count == 11 && (d.hasPrefix("7") || d.hasPrefix("8"))
    }
    private var emailValid: Bool {
        let e = regEmail.trimmingCharacters(in: .whitespaces)
        return e.contains("@") && (e.split(separator: "@").last?.contains(".") ?? false) && !e.hasSuffix("@")
    }
    private var passwordValid: Bool { !loginField.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty }
    private var registerValid: Bool {
        name.trimmingCharacters(in: .whitespaces).count >= 2 && phoneValid && emailValid && password.count >= 6
    }
    private var codeValid: Bool { code.filter(\.isNumber).count == 6 }

    /// Почему «Получить код» ещё серая. Раньше кнопка молча не нажималась
    /// (пароль из 5 символов, телефон с лишней цифрой) — «кнопка не работает».
    /// Показываем, только когда человек уже начал заполнять форму.
    private var registerHint: String? {
        guard step == .register, !registerValid else { return nil }
        let started = !name.isEmpty || !phone.isEmpty || !regEmail.isEmpty || !password.isEmpty
        guard started else { return nil }
        if name.trimmingCharacters(in: .whitespaces).count < 2 { return "Укажите имя — минимум 2 буквы" }
        if !phoneValid { return "Номер в формате +7 900 000-00-00" }
        if !emailValid { return "Проверьте email — на него придёт код" }
        return "Пароль — минимум 6 символов"
    }

    private var actionEnabled: Bool {
        guard !busy else { return false }
        switch step {
        case .password:     return passwordValid
        case .register:     return registerValid
        case .registerCode: return codeValid
        }
    }

    private var actionTitle: String {
        if busy { return "Подождите…" }
        switch step {
        case .password:     return "Войти"
        case .register:     return "Получить код"
        case .registerCode: return "Подтвердить"
        }
    }

    // MARK: Body

    var body: some View {
        ZStack(alignment: .top) {
            YMColor.bg.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    topBar
                    logo.padding(.top, YMSpace.xxl)
                    heading.padding(.top, YMSpace.lg)
                    fields.padding(.top, YMSpace.xxl)

                    if let error, !error.isEmpty {
                        Text(error)
                            .font(YMFont.subhead)
                            .foregroundStyle(YMColor.statusCancel)
                            .padding(.top, YMSpace.sm)
                    } else if let notice, !notice.isEmpty {
                        Text(notice)
                            .font(YMFont.subhead)
                            .foregroundStyle(YMColor.muted)
                            .padding(.top, YMSpace.sm)
                    } else if let hint = registerHint {
                        Text(hint)
                            .font(YMFont.subhead)
                            .foregroundStyle(YMColor.muted)
                            .padding(.top, YMSpace.sm)
                    }

                    Button(action: act) {
                        HStack(spacing: YMSpace.sm) {
                            if busy { ProgressView().tint(YMColor.onAccent) }
                            Text(actionTitle)
                        }
                    }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .disabled(!actionEnabled)
                    .opacity(actionEnabled ? 1 : 0.55)
                    .padding(.top, YMSpace.xl)

                    footerLinks.padding(.top, YMSpace.md)
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, YMSpace.xxxl)
            }
            // У цифровой клавиатуры (телефон, код) нет «Готово»: на маленьком
            // экране она закрывала кнопку. Убирается жестом прокрутки.
            .scrollDismissesKeyboard(.interactively)
        }
        .animation(YMMotion.adaptive(YMMotion.spring, reduceMotion: reduceMotion), value: step)
    }

    // MARK: Шапка «← Назад»

    private var topBar: some View {
        HStack {
            Button {
                Haptics.light()
                back()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(YMColor.text)
                    .frame(width: 38, height: 38)
                    .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(YMColor.hairline, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.top, YMSpace.md)
    }

    // MARK: Логотип

    private var logo: some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(LinearGradient(colors: [YMPalette.goldBright, YMPalette.goldDeep],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 64, height: 64)
            .overlay(
                Text("Y").font(.system(size: 34, weight: .heavy))
                    .foregroundStyle(YMPalette.goldInk)
            )
            .shadow(color: YMPalette.gold.opacity(0.45), radius: 20, y: 10)
    }

    // MARK: Заголовок + подзаголовок

    private var heading: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text(titleText)
                .font(.system(size: 30, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(YMColor.text)
            Text(subtitleText)
                .font(YMFont.body)
                .foregroundStyle(YMColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var titleText: String {
        switch step {
        case .password:     return "Вход"
        case .register:     return "Регистрация"
        case .registerCode: return "Подтвердите почту"
        }
    }

    private var subtitleText: String {
        switch step {
        case .password:     return "Введите email или телефон и пароль"
        case .register:     return "Заполните данные — на почту придёт код подтверждения"
        case .registerCode: return "Мы отправили 6-значный код на \(sentMask ?? regEmail.trimmingCharacters(in: .whitespaces))"
        }
    }

    // MARK: Поля ввода

    @ViewBuilder
    private var fields: some View {
        switch step {
        case .password:
            VStack(alignment: .leading, spacing: YMSpace.md) {
                AuthField(placeholder: "Телефон или email", text: $loginField)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .focused($focused, equals: .login)
                    .onAppear { focused = .login }
                AuthField(placeholder: "Пароль", text: $password, secure: true)
                    .textContentType(.password)
                    .focused($focused, equals: .password)
            }

        case .register:
            VStack(alignment: .leading, spacing: YMSpace.md) {
                AuthField(placeholder: "Ваше имя", text: $name)
                    .textContentType(.name)
                    .textInputAutocapitalization(.words)
                    .focused($focused, equals: .name)
                    .onAppear { focused = .name }
                AuthField(placeholder: "+7 900 000-00-00", text: $phone)
                    .keyboardType(.phonePad)
                    .textContentType(.telephoneNumber)
                AuthField(placeholder: "Email", text: $regEmail)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.emailAddress)
                AuthField(placeholder: "Пароль (минимум 6 символов)", text: $password, secure: true)
                    .textContentType(.newPassword)
            }

        case .registerCode:
            AuthField(placeholder: "Код из письма", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .font(YMFont.title2)
                .multilineTextAlignment(.center)
                .focused($focused, equals: .code)
                .onAppear { focused = .code }
                .onChange(of: code) { new in
                    code = String(new.filter(\.isNumber).prefix(6))
                }
        }
    }

    // MARK: Нижние ссылки

    @ViewBuilder
    private var footerLinks: some View {
        if step == .registerCode {
            linkButton(resendLeft > 0 ? "Отправить код повторно через \(resendLeft) с" : "Отправить код повторно",
                       enabled: resendLeft == 0) { registerRequest() }
        }
        if step == .password || step == .register {
            linkButton(step == .register ? "Уже есть аккаунт? Войти" : "Регистрация") {
                back(to: step == .register ? .password : .register)
            }
        }
    }

    private func linkButton(_ title: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.light(); action() }) {
            Text(title)
                .font(YMFont.subhead)
                .foregroundStyle(enabled ? YMColor.accent : YMColor.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, YMSpace.sm)
        }
        .buttonStyle(.plain)
        .disabled(busy || !enabled)
    }

    /// Пауза перед следующей повторной отправкой кода (см. resendLeft).
    private func startResendCooldown() {
        resendTimer?.cancel()
        resendLeft = 60
        resendTimer = Task { @MainActor in
            while resendLeft > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                resendLeft -= 1
            }
        }
    }

    // MARK: Переходы

    private func back(to step: Step) {
        self.step = step
        error = nil
        notice = nil
    }

    /// Кнопка «назад» в шапке: registerCode → register → password → закрыть.
    private func back() {
        switch step {
        case .password:     dismiss()
        case .register:     back(to: .password)
        case .registerCode: code = ""; back(to: .register)
        }
    }

    // MARK: Действия

    private func act() {
        switch step {
        case .password:     loginByPassword()
        case .register:     registerRequest()
        case .registerCode: registerConfirm()
        }
    }

    /// Вход логин(email/телефон) + пароль → токены.
    private func loginByPassword() {
        guard passwordValid, !busy else { return }
        busy = true; error = nil
        Task {
            do {
                let t: AuthTokens = try await API.shared.post(
                    "api/v1/auth/login",
                    body: ["login": loginField.trimmingCharacters(in: .whitespaces), "password": password]
                )
                finish(t)
            } catch {
                fail(error, fallback: "Неверный логин или пароль")
            }
        }
    }

    /// Шаг 1 регистрации: отправить код на почту.
    private func registerRequest() {
        guard registerValid, !busy else { return }
        busy = true; error = nil
        let body: [String: String] = [
            "name": name.trimmingCharacters(in: .whitespaces),
            "phone": normalizedPhone(),
            "email": regEmail.trimmingCharacters(in: .whitespaces),
            "password": password,
        ]
        Task {
            do {
                let r: RegRequestResult = try await API.shared.post("api/v1/auth/register/request", body: body)
                await MainActor.run {
                    let resent = step == .registerCode
                    busy = false
                    sentMask = r.email
                    // После повторной отправки прежний набранный код уже не тот —
                    // поле очищаем (как Android), иначе «Подтвердить» слало старый
                    // и получало «Неверный код». dev-режим — подставляем новый.
                    if let dc = r.debugCode, !dc.isEmpty { code = dc } else { code = "" }
                    Haptics.success()
                    back(to: .registerCode)
                    if resent { notice = "Новый код отправлен на почту" }
                    startResendCooldown()
                }
            } catch {
                fail(error, fallback: "Не удалось отправить код")
            }
        }
    }

    /// Шаг 2 регистрации: подтвердить код → аккаунт создан, входим.
    private func registerConfirm() {
        guard codeValid, !busy else { return }
        busy = true; error = nil
        let email = regEmail.trimmingCharacters(in: .whitespaces).lowercased()
        Task {
            do {
                let t: AuthTokens = try await API.shared.post(
                    "api/v1/auth/register/confirm",
                    // Только цифры: codeValid считает цифры, и вставленный «123 456»
                    // или «123-456» проходил проверку, а сервер отвечал «Неверный код».
                    body: ["email": email, "code": code.filter { $0.isASCII && $0.isNumber }]
                )
                finish(t)
            } catch {
                fail(error, fallback: "Неверный код")
            }
        }
    }

    /// Сохранение токенов + колбэк.
    @MainActor
    private func finish(_ tokens: AuthTokens) {
        busy = false
        guard let token = tokens.token, !token.isEmpty else {
            error = "Не получили токен"
            Haptics.error()
            return
        }
        AuthLastUser.switchTo(tokens.user?.id)
        session.signIn(token, refresh: tokens.refresh)
        Haptics.success()
        if let onAuthed { onAuthed() } else { dismiss() }
    }

    @MainActor
    private func fail(_ error: Error, fallback: String) {
        busy = false
        if error is CancellationError { return }
        let msg = error.localizedDescription
        self.error = msg.isEmpty ? fallback : msg
        Haptics.error()
    }
}

// MARK: - AuthField (стилизованное поле под премиум-токены)

/// Поле ввода в surface-боксе с hairline. secure=true → SecureField.
private struct AuthField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $text)
            } else {
                TextField(placeholder, text: $text)
            }
        }
        .font(YMFont.body)
        .foregroundStyle(YMColor.text)
        .tint(YMColor.accent)
        .padding(.horizontal, YMSpace.lg)
        .frame(height: 54)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1)
        )
    }
}
