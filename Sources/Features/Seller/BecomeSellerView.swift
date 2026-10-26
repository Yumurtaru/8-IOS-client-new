//
//  BecomeSellerView.swift — регистрация своей организации ПРЯМО В ПРИЛОЖЕНИИ (без сайта).
//
//  Flow:
//    Промо-карточка в списках заведений (после каждых 3-х) → BecomeSellerView (описание)
//    → кнопка «Подать заявку» → .sheet с формой (название, ФИО, телефон, тип) → «ждите модерацию».
//
//  API: POST api/v1/organizations/apply  body {org_name, full_name, phone, type, city_id}
//       → OrgApplyResult {registration_id, status:"pending"}. Заявка падает в shop_registrations
//       (pending) → модерация в админке. Тип — канон API: store | restaurant | service | lodging.
//       Волна А75: сервер может сразу создать организацию — approved: true, message
//       (что делать дальше). Тогда вместо «на рассмотрении» — «Организация создана».
//
//  Токены — только YM. Light + dark. Русские литералы.
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Промо-карточка (вставляется в списки заведений после каждых 3-х)
// ─────────────────────────────────────────────────────────────────────────────

struct BecomeSellerPromoCard: View {
    var onTap: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            onTap()
        } label: {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Text("YUMURTA ДЛЯ БИЗНЕСА")
                    .font(YMFont.caption2).fontWeight(.semibold)
                    .foregroundStyle(YMColor.accent)
                Text("Добавьте свою организацию")
                    .font(YMFont.title3).foregroundStyle(YMColor.text)
                Text("Продавайте товары, блюда и услуги на Yumurta. Заявка — прямо в приложении.")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 4) {
                    Text("Подать заявку").font(YMFont.headline).foregroundStyle(YMColor.accent)
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.lg)
            .background(YMColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .strokeBorder(YMColor.accent.opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Экран описания «Стать продавцом»
// ─────────────────────────────────────────────────────────────────────────────

struct BecomeSellerView: View {
    @State private var showForm = false
    @State private var submitted = false
    /// П-23.5: сервер ответил duplicate: true — заявка уже есть, новую не создал.
    @State private var duplicate = false
    /// Волна А75: approved == true — организация уже создана (не «на рассмотрении»).
    @State private var approved = false
    /// Текст сервера к созданной организации (в т.ч. про пароль по ссылке из письма).
    @State private var serverNote: String?

    private let benefits: [(String, String)] = [
        ("Витрина в приложении", "Ваши товары и услуги видят клиенты вашего города."),
        ("Заказы и оплата", "Приём заказов, онлайн-оплата и доставка — всё внутри Yumurta."),
        ("Без вложений на старте", "Подключение бесплатно. Оставьте заявку — мы поможем настроить."),
    ]

    var body: some View {
        ScrollView {
            if submitted {
                doneContent
            } else {
                introContent
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Стать продавцом")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showForm) {
            ApplyOrgFormView { ok, dup, result in
                if ok {
                    duplicate = dup
                    // Старый сервер поля approved не шлёт — nil, экран прежний.
                    approved = result?.approved == true
                    let note = result?.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    serverNote = approved && !note.isEmpty ? note : nil
                    withAnimation { submitted = true }
                }
            }
        }
    }

    private var introContent: some View {
        VStack(alignment: .leading, spacing: YMSpace.lg) {
            Text("Продавайте на Yumurta")
                .font(YMFont.title).foregroundStyle(YMColor.text)
            Text("Магазин, ресторан, услуги или жильё — разместите свою организацию в приложении и получайте заказы и брони от клиентов вашего города.")
                .font(YMFont.body).foregroundStyle(YMColor.muted)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: YMSpace.md) {
                ForEach(benefits, id: \.0) { title, sub in
                    HStack(alignment: .top, spacing: YMSpace.md) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20)).foregroundStyle(YMColor.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(YMFont.headline).foregroundStyle(YMColor.text)
                            Text(sub).font(YMFont.callout).foregroundStyle(YMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.top, YMSpace.xs)

            Button {
                Haptics.light()
                showForm = true
            } label: { Text("Подать заявку") }
                .buttonStyle(YMPrimaryButtonStyle())
                .padding(.top, YMSpace.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.md)
        .padding(.bottom, YMSpace.xxxl)
    }

    private var doneContent: some View {
        VStack(spacing: YMSpace.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64)).foregroundStyle(YMColor.accent)
                .padding(.top, YMSpace.xxxl)
            if approved {
                // Волна А75: организация активирована сразу — «на рассмотрении»
                // было бы неправдой; ведём в приложение продавца.
                Text("Организация создана").font(YMFont.title2).foregroundStyle(YMColor.text)
                Text("Войдите в приложение продавца (Yumurta Бизнес) — заполните товары и отправьте на публикацию.")
                    .font(YMFont.body).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let serverNote {
                    // Текст сервера: дальнейшие шаги и, для нового владельца,
                    // «Пароль для входа задайте по ссылке из письма».
                    Text(serverNote)
                        .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // П-23.5: при повторе — честное «уже подана», а не «отправлена».
                Text(duplicate ? "Заявка уже подана" : "Заявка отправлена!").font(YMFont.title2).foregroundStyle(YMColor.text)
                Text(duplicate
                     ? "Ваша прошлая заявка ещё на рассмотрении. Мы свяжемся с вами по указанному телефону."
                     : "Мы проверим данные и свяжемся с вами по указанному телефону. Обычно это занимает до 24 часов.")
                    .font(YMFont.body).foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Форма заявки (sheet): название, ФИО, телефон, тип
// ─────────────────────────────────────────────────────────────────────────────

private struct ApplyOrgFormView: View {
    /// success — родитель показывает экран «ждите модерацию»;
    /// второй флаг — П-23.5: заявка уже была подана (duplicate);
    /// третий — ответ сервера (волна А75: approved, message), nil при неудаче.
    let onResult: (Bool, Bool, OrgApplyResult?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var orgName = ""
    @State private var fullName = ""
    @State private var phone = ""
    // store | restaurant | service | lodging
    // «Жильё» (lodging) — четвёртый формат площадки: отели, гостевые дома,
    // квартиры посуточно. На сайте он в заявке был с самого начала, сервер его
    // принимает, а в приложении варианта не было — человек с гостевым домом
    // выбирал «Услуги» и попадал в кабинет без календаря и броней.
    @State private var type = "store"
    @State private var sending = false
    @State private var error: String?
    // П-23.5: новому владельцу (телефона нет в базе) сервер шлёт код на почту:
    // 422 details.need == "email_code" → поле кода и повтор с email_code.
    @State private var email = ""
    @State private var emailCode = ""
    @State private var needCode = false
    @State private var info: String?

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Паритет с Android и сервером (organizations/apply: isValidPhone):
    /// российский номер — 10 цифр или 11 с 7/8. Раньше подходили любые 10+
    /// цифр, и сервер отвечал «Укажите корректный номер телефона».
    private var phoneOk: Bool {
        let d = phone.filter { $0.isASCII && $0.isNumber }
        if d.count == 10 { return true }
        return d.count == 11 && (d.hasPrefix("7") || d.hasPrefix("8"))
    }

    private var valid: Bool {
        orgName.trimmingCharacters(in: .whitespaces).count >= 2
            && fullName.trimmingCharacters(in: .whitespaces).count >= 2
            && phoneOk
            // Почта необязательна (нужна только новому владельцу), но если
            // введена — похожа на адрес; после письма нужен код.
            && (trimmedEmail.isEmpty || trimmedEmail.contains("@"))
            && (!needCode || !emailCode.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Почему «Отправить заявку» серая — то же правило, что в valid. Раньше
    /// кнопка просто не нажималась (например, в телефоне 9 цифр), без слова.
    private var invalidReason: String? {
        if orgName.trimmingCharacters(in: .whitespaces).count < 2 { return "Укажите название организации" }
        if fullName.trimmingCharacters(in: .whitespaces).count < 2 { return "Укажите ФИО" }
        if !phoneOk { return "Номер в формате +7 900 000-00-00" }
        if !trimmedEmail.isEmpty && !trimmedEmail.contains("@") { return "Проверьте email" }
        if needCode && emailCode.trimmingCharacters(in: .whitespaces).isEmpty { return "Введите код из письма" }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Организация") {
                    TextField("Название организации", text: $orgName)
                        .textInputAutocapitalization(.words)
                    Picker("Тип", selection: $type) {
                        Text("Магазин").tag("store")
                        Text("Ресторан").tag("restaurant")
                        Text("Услуги").tag("service")
                        Text("Жильё").tag("lodging")
                    }
                    // Обычный список вместо segmented: четыре подписи в одной
                    // полосе на iPhone SE обрезаются до «Ресто…», и выбрать
                    // формат становится гаданием.
                    .pickerStyle(.automatic)
                }
                Section("Контакты") {
                    TextField("Ваше ФИО", text: $fullName)
                        .textContentType(.name)
                    TextField("Телефон", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                }
                // П-23.5: почта и код подтверждения для нового владельца.
                Section {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(sending)
                        // Другая почта — прежний код к ней не подходит.
                        .onChange(of: email) { _ in
                            if needCode { needCode = false; emailCode = ""; info = nil }
                        }
                    if needCode {
                        TextField("Код из письма", text: $emailCode)
                            .textContentType(.oneTimeCode)
                            .keyboardType(.numberPad)
                            .disabled(sending)
                        Button("Отправить код ещё раз") { submit(resendCode: true) }
                            .disabled(sending || trimmedEmail.isEmpty)
                    }
                } header: {
                    Text("Почта")
                } footer: {
                    Text("Нужна, если вы ещё не зарегистрированы на Yumurta: пришлём код подтверждения.")
                }
                if let info {
                    Text(info).font(YMFont.caption).foregroundStyle(YMColor.accent)
                }
                if let error {
                    Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Section {
                    Button(action: { submit() }) {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else { Text("Отправить заявку").fontWeight(.bold) }
                            Spacer()
                        }
                    }
                    .disabled(!valid || sending)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        // Причина серой кнопки — сразу под ней.
                        if !sending, let why = invalidReason {
                            Text(why).foregroundStyle(YMColor.accent)
                        }
                        Text("Заявка уйдёт на модерацию. После одобрения мы свяжемся с вами по телефону.")
                    }
                }
            }
            .navigationTitle("Заявка")
            .navigationBarTitleDisplayMode(.inline)
            // Пока заявка отправляется, форму не закрыть: закрыл — ответ (код из
            // письма, «уже подана», ошибка) пропадал вместе с формой и введёнными
            // данными, а заявка при этом могла уйти.
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(sending) } }
            .task { await prefill() }
        }
        .tint(YMColor.accent)
        .interactiveDismissDisabled(sending)
    }

    /// Автоподстановка ФИО/телефона из профиля (если вошёл) — клиент правит.
    private func prefill() async {
        guard Session.shared.isLoggedIn else { return }
        if let p: Profile = try? await API.shared.get("api/v1/profile") {
            await MainActor.run {
                if fullName.isEmpty, let n = p.name, !n.isEmpty { fullName = n }
                if phone.isEmpty, let ph = p.phone, !ph.isEmpty { phone = ph }
                // П-23.5: почта из профиля — не придётся вводить заново.
                if email.isEmpty, let em = p.email, !em.isEmpty { email = em }
            }
        }
    }

    /// resendCode — П-23.5: запрос без кода, чтобы сервер прислал новое письмо.
    private func submit(resendCode: Bool = false) {
        // Двойное нажатие до перерисовки кнопки отправляло две заявки на модерацию.
        guard !sending else { return }
        // Повтор письма — без проверки формы на клиенте (кода ещё нет; поля проверит сервер).
        if !resendCode { guard valid else { return } }
        error = nil
        sending = true
        let em = trimmedEmail
        let code = emailCode.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = OrgApplyBody(
            orgName: orgName.trimmingCharacters(in: .whitespaces),
            fullName: fullName.trimmingCharacters(in: .whitespaces),
            phone: phone.trimmingCharacters(in: .whitespaces),
            type: type,
            cityId: Session.shared.cityId
        )
        // П-23.5: почту шлём, только если её ввели; код — только на шаге кода.
        body.email = em.isEmpty ? nil : em
        body.emailCode = (needCode && !resendCode && !code.isEmpty) ? code : nil
        // В Task — неизменяемая копия: захват var в параллельном коде Xcode 15 не пропускает.
        let sendBody = body
        Task {
            do {
                let r: OrgApplyResult = try await API.shared.post("api/v1/organizations/apply", body: sendBody)
                await MainActor.run {
                    Haptics.success()
                    sending = false
                    onResult(true, r.duplicate == true, r)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    sending = false
                    let api = error as? APIError
                    let text = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить заявку"
                    // П-23.5: письмо с кодом ушло — это следующий шаг, а не ошибка.
                    if api?.rejectStatus == 422, api?.rejectDetails?["need"] == "email_code",
                       sendBody.emailCode != nil {
                        // Код отправляли, а сервер снова ответил need=email_code — это
                        // «Неверный или просроченный код» (api_v1.php:1054), а не новое
                        // письмо. Раньше поле кода стиралось и писалось «Мы отправили код».
                        info = nil
                        self.error = text
                    } else if api?.rejectStatus == 422, api?.rejectDetails?["need"] == "email_code" {
                        needCode = true
                        emailCode = ""
                        info = "Мы отправили код на \(em). Введите его и нажмите «Отправить заявку»."
                    } else if api?.rejectStatus == 429 {
                        // Больше 5 попыток кода (или частые запросы) — ждать.
                        info = nil
                        self.error = text.isEmpty ? "Слишком много попыток. Попробуйте позже" : text
                    } else {
                        // 409 (почта занята / телефон другого аккаунта), неверный код и
                        // «Укажите email» — показываем текст сервера как есть.
                        info = nil
                        self.error = text
                    }
                }
            }
        }
    }
}
