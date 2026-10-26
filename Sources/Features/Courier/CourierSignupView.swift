//
//  CourierSignupView.swift — «Стать курьером» (волна А97, задача владельца)
//
//  Профиль → «Стать курьером», push pool_account. Те же ручки и тот же аккаунт, что
//  в приложении курьера «Yumurta Курьер»:
//    • GET  api/v1/pool/me?lite=1 — при каждом открытии экрана (и по push / возврату в приложение); А98:
//      лёгкий статус без побочных действий, старый сервер отдаёт полный /pool/me — разбор тот же;
//    • GET  api/v1/pool/rules — правило «только грузы и посылки», если /pool/me его не прислал;
//    • POST api/v1/pool/apply — заявка (multipart): full_name, city_id, car_model, car_color,
//      car_plate, self_employed, consent=1, no_passengers=1 + photo, license (JPEG).
//
//  Состояния: заявки нет — форма (как в приложении курьера: поля, тексты, проверки, фото
//  камерой или из галереи); pending — «Заявка на проверке»; rejected — причина + та же
//  форма; approved — «Вы курьер — откройте приложение курьера»; blocked — статус и причина,
//  без формы. Ссылки на «Yumurta Курьер» — из features.courier_app (на iPhone — App Store
//  и веб; пустую не показываем).
//
//  Машину и груз (А80) здесь не спрашиваем — курьер укажет их в приложении курьера
//  («Моя машина»); без них сервер считает машину легковой по городу.
//  Те же тексты и правила — Android ui/screens/courier/CourierSignupScreen.kt.
//

import SwiftUI
import UIKit
import PhotosUI
import AVFoundation

/// Тексты и проверки заявки — как в приложении курьера (ConsentLogic, ApplyView) и на сайте.
enum CourierSignupText {
    static let title = "Стать курьером"
    static let intro = "Администратор проверит данные и включит вам доступ к заказам. Фото прав видит только администратор площадки."
    static let workInApp = "Работают курьеры в приложении «Yumurta Курьер»: заказы, «На линии» и уведомления курьера приходят только туда. Войдите в нём тем же аккаунтом."
    static let closed = "Приём курьеров сейчас закрыт — загляните позже."
    static let pendingTitle = "Заявка на проверке"
    static let pendingText = "Как только администратор рассмотрит заявку, придёт уведомление. Обычно это занимает несколько часов. Пока можно установить «Yumurta Курьер»."
    static let approvedTitle = "Вы курьер — откройте приложение курьера"
    static let approvedText = "Заказы, «На линии» и расчёты — в приложении «Yumurta Курьер». Войдите в нём тем же аккаунтом."
    static let blockedTitle = "Аккаунт курьера заблокирован"
    static let blockedText = "Вопросы — в поддержку площадки."
    static let appTitle = "Приложение «Yumurta Курьер»"
    static let btnStore = "Скачать «Yumurta Курьер»"
    static let btnWeb = "Открыть веб-версию"
    static let btnRecheck = "Проверить снова"
    static let btnSend = "Отправить заявку"
    static let btnSending = "Отправляем…"
    static let btnProfile = "Добавить телефон в профиле"
    static let check = "Проверьте заявку"
    static let phoneMissing = "В аккаунте нет телефона — добавьте его в профиле, затем отправьте заявку."
    /// Галочка 1 — согласие на обработку персональных данных (ссылка на политику — рядом).
    static let pdText = "Даю согласие на обработку моих персональных данных (ФИО, телефон, почта, фото лица "
        + "и водительских прав, данные машины, геопозиция во время работы) в соответствии с политикой конфиденциальности."
    /// Галочка 2 — правила курьеров.
    static let rulesText = "Согласен с правилами курьеров: деньги клиента принадлежат заведению — сдаю их в заведение; "
        + "за порчу или недоставку заказа возмещаю ущерб сам."
    /// Галочка 3 — правило «только грузы и посылки» (А81), текст как на сайте.
    static let noPassengersText = "Подтверждаю: вожу только вещи — заказы, посылки и грузы. "
        + "Людей (и «попутно», и вместе с грузом) и животных не вожу."
    static let errPd = "Нужно согласие на обработку персональных данных"
    static let errRules = "Нужно согласие с правилами курьеров"
    static let privacyURL = "https://yumurta.ru/privacy#couriers"
    static let keyPd = "consent_pd"
    static let keyRules = "consent"

    static func rejected(_ note: String?) -> String {
        "Заявка отклонена" + ((note?.isEmpty == false) ? ": " + note! : "") + ". Исправьте и отправьте снова."
    }

    static func consentVersion(_ v: String) -> String { "Редакция согласия: " + v }

    /// Ошибки формы до отправки (как ApplyView.submit в приложении курьера).
    static func localErrors(cityId: Int, hasPhoto: Bool, hasLicense: Bool,
                            consentPd: Bool, consentRules: Bool, consentedBefore: Bool,
                            rule: CourierRule?, noPassengers: Bool) -> [String: String] {
        var out: [String: String] = [:]
        if cityId <= 0 { out["city_id"] = "Выберите город" }
        if !hasPhoto { out["photo"] = "Сделайте своё фото" }
        if !hasLicense { out["license"] = "Сфотографируйте водительские права" }
        if !consentedBefore {
            if !consentPd { out[keyPd] = errPd }
            if !consentRules { out[keyRules] = errRules }
        }
        if let r = rule, !noPassengers { out["no_passengers"] = r.confirmText }
        return out
    }

    /// Какую часть экрана показать по заявке: form | pending | approved | blocked | other.
    static func mode(_ c: CourierRecord?) -> String {
        guard let c else { return "form" }
        switch c.status {
        case "rejected": return "form"
        case "pending", "approved", "blocked": return c.status
        default: return "other"   // неизвестный статус (новый сервер) — без формы
        }
    }

    /// Фото ≤ ~2 МБ: JPEG, длинная сторона до 1600 px, качество снижаем, пока не влезет.
    static func jpeg(_ raw: Data) -> Data? {
        var side: CGFloat = 1600
        var quality: CGFloat = 0.85
        guard var out = ImageUpload.jpeg(from: raw, maxSide: side, quality: quality) else { return nil }
        while out.count > 2 * 1024 * 1024 && (quality > 0.56 || side > 900) {
            if quality > 0.56 { quality -= 0.1 } else { side -= 200 }
            guard let next = ImageUpload.jpeg(from: raw, maxSide: side, quality: quality) else { return nil }
            out = next
        }
        return out
    }
}

struct CourierSignupView: View {
    /// 422 errors.phone — в аккаунте нет телефона: «Редактировать профиль».
    var openEditProfile: () -> Void = {}

    @ObservedObject private var features = FeaturesStore.shared
    @State private var me: CourierMe?
    @State private var loading = true
    @State private var loadError: String?
    @State private var loadedRule: CourierRule?
    @State private var reloadTick = 0
    @State private var appearedOnce = false

    private var mode: String { CourierSignupText.mode(me?.courier) }
    private var rule: CourierRule? { me?.rule ?? loadedRule }
    /// Ссылки «Yumurta Курьер». Флаги неизвестны (старый сервер, нет сети) — веб-версия есть всегда.
    private var storeURL: String { features.current.courierApp?.ios ?? "" }
    private var webURL: String {
        guard let l = features.current.courierApp else { return API.base + "/kurer" }
        return l.web
    }

    var body: some View {
        content
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(CourierSignupText.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: reloadTick) { await load() }
            .task { await features.refresh() }
            // Решение администратора пришло push — перечитываем; вернулись в приложение — тоже.
            .onReceive(NotificationCenter.default.publisher(for: .ymCourierPushed)) { _ in reloadTick += 1 }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                // Вернулись из браузера / App Store, куда ушли по ссылке с этого экрана, — не перечитываем.
                if CourierLive.leftForLink { CourierLive.leftForLink = false; return }
                reloadTick += 1
            }
            .onAppear {
                CourierLive.open = true
                // Вернулись с «Редактировать профиль» — телефон мог появиться.
                if appearedOnce { reloadTick += 1 }
                appearedOnce = true
            }
            .onDisappear { CourierLive.open = false }
    }

    @ViewBuilder
    private var content: some View {
        if me == nil && loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if me == nil {
            VStack(spacing: YMSpace.md) {
                Text(loadError ?? "Не удалось загрузить")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                Button("Повторить") { reloadTick += 1 }
                    .buttonStyle(YMSecondaryButtonStyle())
                    .frame(maxWidth: 220)
            }
            .padding(YMSpace.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if mode == "form", let m = me {
            CourierApplyForm(me: m, rule: rule, storeURL: storeURL, webURL: webURL,
                             onSent: { sent in me = sent; CourierGate.note(sent) },
                             onDisabled: { me?.enabled = false },
                             onReload: { reloadTick += 1 },
                             openEditProfile: openEditProfile)
        } else if let c = me?.courier {
            ScrollView {
                VStack(spacing: YMSpace.lg) {
                    statusCard(c)
                    if mode != "blocked" { CourierAppLinksBlock(storeURL: storeURL, webURL: webURL) }
                    if mode == "pending" || mode == "other" {
                        Button(CourierSignupText.btnRecheck) { reloadTick += 1 }
                            .buttonStyle(YMSecondaryButtonStyle())
                            .disabled(loading)
                    }
                }
                .padding(YMSpace.xl)
            }
        }
    }

    @ViewBuilder
    private func statusCard(_ c: CourierRecord) -> some View {
        switch mode {
        case "pending":
            let who = [c.fullName, c.car].filter { !$0.isEmpty }.joined(separator: " · ")
            CourierStatusCard(icon: "⏳", title: CourierSignupText.pendingTitle,
                              lines: [who, CourierSignupText.pendingText])
        case "approved":
            CourierStatusCard(icon: "✅", title: CourierSignupText.approvedTitle, lines: [CourierSignupText.approvedText])
        case "blocked":
            CourierStatusCard(icon: "⛔", title: CourierSignupText.blockedTitle,
                              lines: [c.reviewNote ?? "", CourierSignupText.blockedText], danger: true)
        default:
            CourierStatusCard(icon: "ℹ️", title: c.statusLabel.isEmpty ? c.status : c.statusLabel, lines: [c.reviewNote ?? ""])
        }
    }

    private func load() async {
        if me == nil { loading = true }
        do {
            let m = try await CourierAPI.me()
            me = m
            loadError = nil
            CourierGate.note(m)
            if m.rule == nil && CourierSignupText.mode(m.courier) == "form" && loadedRule == nil {
                loadedRule = await CourierAPI.rule()
            }
        } catch is CancellationError {
        } catch {
            // Ошибка при уже показанном экране — оставляем его (форма не пропадает).
            if me == nil { loadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить" }
        }
        loading = false
    }
}

/// Ссылки на «Yumurta Курьер»: App Store и веб-версия; пустую не показываем.
struct CourierAppLinksBlock: View {
    let storeURL: String
    let webURL: String

    var body: some View {
        if !storeURL.isEmpty || !webURL.isEmpty {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                Text(CourierSignupText.appTitle).font(YMFont.headline).foregroundStyle(YMColor.text)
                if let u = URL(string: storeURL), !storeURL.isEmpty {
                    Button { CourierLive.leftForLink = true; UIApplication.shared.open(u) } label: { Text(CourierSignupText.btnStore).frame(maxWidth: .infinity) }
                        .buttonStyle(YMPrimaryButtonStyle())
                }
                if let u = URL(string: webURL), !webURL.isEmpty {
                    Button { CourierLive.leftForLink = true; UIApplication.shared.open(u) } label: { Text(CourierSignupText.btnWeb).frame(maxWidth: .infinity) }
                        .buttonStyle(YMSecondaryButtonStyle())
                }
            }
            .padding(YMSpace.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        }
    }
}

private struct CourierStatusCard: View {
    let icon: String
    let title: String
    let lines: [String]
    var danger = false

    var body: some View {
        VStack(spacing: YMSpace.sm) {
            Text(icon).font(.system(size: 40))
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text).multilineTextAlignment(.center)
            ForEach(Array(lines.filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, line in
                Text(line).font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(YMSpace.xl)
        .frame(maxWidth: .infinity)
        .background(danger ? YMColor.statusCancel.opacity(0.10) : YMColor.surface,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(danger ? YMColor.statusCancel.opacity(0.45) : YMColor.hairline, lineWidth: 1))
    }
}

/// Камера для заявки (лицо — фронтальной).
private struct CourierPhotoRequest: Identifiable {
    let kind: String
    var id: String { kind }
}

/// Форма заявки курьера (заявки нет или отклонена).
private struct CourierApplyForm: View {
    let me: CourierMe
    let rule: CourierRule?
    let storeURL: String
    let webURL: String
    let onSent: (CourierMe) -> Void
    let onDisabled: () -> Void
    let onReload: () -> Void
    let openEditProfile: () -> Void

    @State private var fullName: String
    @State private var cityId: Int
    @State private var cityName: String
    @State private var carModel: String
    @State private var carColor: String
    @State private var carPlate: String
    @State private var selfEmployed: Bool
    @State private var consentPd = false
    @State private var consentRules = false
    @State private var noPassengers = false
    @State private var photo: Data?
    @State private var license: Data?
    @State private var photoThumb: UIImage?
    @State private var licenseThumb: UIImage?
    @State private var photoItem: PhotosPickerItem?
    @State private var licenseItem: PhotosPickerItem?

    @State private var processing: String?
    @State private var fields: [String: String] = [:]
    @State private var topError: String?
    @State private var sending = false
    @State private var showCities = false
    @State private var cameraReq: CourierPhotoRequest?
    @State private var cameraDenied = false

    init(me: CourierMe, rule: CourierRule?, storeURL: String, webURL: String,
         onSent: @escaping (CourierMe) -> Void, onDisabled: @escaping () -> Void,
         onReload: @escaping () -> Void, openEditProfile: @escaping () -> Void) {
        self.me = me
        self.rule = rule
        self.storeURL = storeURL
        self.webURL = webURL
        self.onSent = onSent
        self.onDisabled = onDisabled
        self.onReload = onReload
        self.openEditProfile = openEditProfile
        // Повторная заявка — прежние данные.
        let c = me.courier
        _fullName = State(initialValue: c?.fullName ?? "")
        _cityId = State(initialValue: c?.cityId ?? 0)
        _cityName = State(initialValue: c?.city ?? "")
        _carModel = State(initialValue: c?.carModel ?? "")
        _carColor = State(initialValue: c?.carColor ?? "")
        _carPlate = State(initialValue: c?.carPlate ?? "")
        _selfEmployed = State(initialValue: c?.selfEmployed ?? false)
    }

    private var courier: CourierRecord? { me.courier }
    private var enabled: Bool { me.enabled != false }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if !enabled { banner(CourierSignupText.closed, danger: true) }
                if let c = courier, c.status == "rejected" { banner(CourierSignupText.rejected(c.reviewNote)) }
                Text(CourierSignupText.intro).font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(CourierSignupText.workInApp).font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)

                if fields["phone"] != nil {
                    VStack(alignment: .leading, spacing: YMSpace.sm) {
                        Text(CourierSignupText.phoneMissing).font(YMFont.callout).foregroundStyle(YMColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(CourierSignupText.btnProfile) { openEditProfile() }
                            .buttonStyle(YMSecondaryButtonStyle())
                    }
                    .padding(YMSpace.md)
                    .background(YMColor.statusCancel.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if let e = topError { errorLine(e) }

                field("Имя и фамилия", text: $fullName, prompt: "Иван Иванов", key: "full_name", alt: "name", cap: .words)
                cityField
                field("Машина (марка и модель)", text: $carModel, prompt: "Лада Гранта", key: "car_model")
                HStack(alignment: .top, spacing: YMSpace.sm) {
                    field("Цвет", text: $carColor, prompt: "Белый", key: "car_color")
                    field("Госномер", text: $carPlate, prompt: "А123ВС161", key: "car_plate", cap: .characters)
                        .onChange(of: carPlate) { v in
                            let up = v.uppercased()
                            if up != v { carPlate = up }
                        }
                }

                photoBlock(kind: "photo", title: "Ваше фото (лицо хорошо видно)",
                           hint: "Снимите себя фронтальной камерой", thumb: photoThumb,
                           hasNew: photo != nil, hasOld: courier?.hasPhoto == true, item: $photoItem)
                photoBlock(kind: "license", title: "Фото водительских прав",
                           hint: "Сфотографируйте права целиком, чтобы всё читалось", thumb: licenseThumb,
                           hasNew: license != nil, hasOld: courier?.hasLicense == true, item: $licenseItem)

                checkRow(selfEmployed, "Я самозанятый («Мой налог»)") { selfEmployed.toggle() }

                // Правило сервиса (А81) — обязательная галочка; старый сервер без правила — галочки нет.
                if let r = rule {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(r.text.hasSuffix(".") ? r.text : r.text + ".")
                            .font(YMFont.headline).foregroundStyle(YMColor.text)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(r.details.enumerated()), id: \.offset) { _, line in
                            Text("• " + line).font(YMFont.caption).foregroundStyle(YMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        checkRow(noPassengers, CourierSignupText.noPassengersText) {
                            noPassengers.toggle()
                            fields["no_passengers"] = nil
                        }
                        if let e = fields["no_passengers"] { errorLine(e) }
                    }
                    .padding(YMSpace.md)
                    .background(YMColor.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(fields["no_passengers"] != nil ? YMColor.statusCancel : YMColor.accent.opacity(0.45), lineWidth: 1))
                }

                // 152-ФЗ: согласие на персональные данные — отдельной галочкой, со ссылкой на политику.
                checkRow(consentPd, CourierSignupText.pdText) {
                    consentPd.toggle()
                    fields[CourierSignupText.keyPd] = nil
                }
                Button("Политика конфиденциальности") {
                    if let u = URL(string: CourierSignupText.privacyURL) { CourierLive.leftForLink = true; UIApplication.shared.open(u) }
                }
                .font(YMFont.callout.weight(.semibold))
                .foregroundStyle(YMColor.accent)
                if let v = me.consentVersion {
                    Text(CourierSignupText.consentVersion(v)).font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                if let e = fields[CourierSignupText.keyPd] { errorLine(e) }
                checkRow(consentRules, CourierSignupText.rulesText) {
                    consentRules.toggle()
                    fields[CourierSignupText.keyRules] = nil
                }
                if let e = fields[CourierSignupText.keyRules] { errorLine(e) }

                Button { submit() } label: {
                    HStack(spacing: 8) {
                        if sending { ProgressView() }
                        Text(sending ? CourierSignupText.btnSending : CourierSignupText.btnSend)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(YMPrimaryButtonStyle())
                .disabled(sending || processing != nil || !enabled)
                .opacity(sending || processing != nil || !enabled ? 0.6 : 1)
                .padding(.top, 4)

                CourierAppLinksBlock(storeURL: storeURL, webURL: webURL)
                Color.clear.frame(height: YMSpace.xl)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
        }
        .scrollDismissesKeyboard(.interactively)
        .task { await prefillName() }
        .sheet(isPresented: $showCities) {
            CourierCityPicker { city in
                cityId = city.id
                cityName = city.name ?? ""
                fields["city_id"] = nil
                showCities = false
            }
        }
        .fullScreenCover(item: $cameraReq) { req in
            CourierCameraPicker(front: req.kind == "photo") { image in
                cameraReq = nil
                // Кадр 12 Мп в JPEG кодируем не здесь (главный поток), а в process.
                if let img = image { process(req.kind, image: img) }
            }
            .ignoresSafeArea()
        }
        .onChange(of: photoItem) { item in loadPicked(item, kind: "photo") }
        .onChange(of: licenseItem) { item in loadPicked(item, kind: "license") }
        .alert("Нет доступа к камере", isPresented: $cameraDenied) {
            Button("Открыть настройки") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Разрешите доступ к камере в настройках iPhone, чтобы сфотографировать лицо и права. Или выберите фото из галереи.")
        }
    }

    // MARK: Части формы

    private func banner(_ text: String, danger: Bool = false) -> some View {
        Text(text)
            .font(YMFont.callout).foregroundStyle(YMColor.text)
            .fixedSize(horizontal: false, vertical: true)
            .padding(YMSpace.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((danger ? YMColor.statusCancel : YMColor.accent).opacity(0.12),
                        in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }

    private func errorLine(_ text: String) -> some View {
        Text(text).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func field(_ label: String, text: Binding<String>, prompt: String, key: String, alt: String? = nil,
                       cap: TextInputAutocapitalization = .sentences) -> some View {
        let err = fields[key] ?? alt.flatMap { fields[$0] }
        return VStack(alignment: .leading, spacing: 6) {
            Text(label).font(YMFont.subhead).foregroundStyle(YMColor.text)
            TextField(prompt, text: text)
                .textInputAutocapitalization(cap)
                .autocorrectionDisabled()
                .font(YMFont.body)
                .padding(.horizontal, 14).frame(height: 46)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(err != nil ? YMColor.statusCancel : Color.clear, lineWidth: 1))
                .onChange(of: text.wrappedValue) { _ in
                    if fields[key] != nil { fields[key] = nil }
                    if let a = alt, fields[a] != nil { fields[a] = nil }
                }
            if let err { errorLine(err) }
        }
    }

    private var cityField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Город").font(YMFont.subhead).foregroundStyle(YMColor.text)
            Button { showCities = true } label: {
                HStack {
                    Text(cityName.isEmpty ? "Выберите город" : cityName)
                        .font(YMFont.body)
                        .foregroundStyle(cityName.isEmpty ? YMColor.muted : YMColor.text)
                    Spacer()
                    Image(systemName: "chevron.down").foregroundStyle(YMColor.muted)
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                    .strokeBorder(fields["city_id"] != nil ? YMColor.statusCancel : Color.clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            if let e = fields["city_id"] { errorLine(e) }
        }
    }

    private func photoBlock(kind: String, title: String, hint: String, thumb: UIImage?,
                            hasNew: Bool, hasOld: Bool, item: Binding<PhotosPickerItem?>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(YMFont.headline).foregroundStyle(YMColor.text)
            Text(hasNew ? "Фото готово — можно переснять" : (hasOld ? "Фото уже загружено — можно переснять" : hint))
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
            HStack(alignment: .center, spacing: YMSpace.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(YMColor.surface2)
                    if processing == kind {
                        ProgressView()
                    } else if let t = thumb {
                        Image(uiImage: t).resizable().scaledToFill()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .accessibilityLabel(title)
                    } else {
                        Text("Нет фото").font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                }
                .frame(width: 96, height: 96)
                VStack(spacing: 6) {
                    Button { shoot(kind) } label: {
                        Label(hasNew || hasOld ? "Переснять" : "Сфотографировать", systemImage: "camera")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(YMSecondaryButtonStyle())
                    .disabled(processing == kind)
                    PhotosPicker(selection: item, matching: .images) {
                        Text("Выбрать из галереи")
                            .font(YMFont.callout.weight(.semibold))
                            .foregroundStyle(YMColor.accent)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(processing == kind)
                }
            }
            .padding(.top, 6)
            if let e = fields[kind] { errorLine(e) }
        }
        .padding(YMSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(fields[kind] != nil ? YMColor.statusCancel : YMColor.hairline, lineWidth: 1))
    }

    private func checkRow(_ checked: Bool, _ text: String, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(checked ? YMColor.accent : YMColor.muted)
                Text(text).font(YMFont.callout).foregroundStyle(YMColor.text).multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // VoiceOver — текст и «отмечено / не отмечено».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(checked ? "отмечено" : "не отмечено")
        .accessibilityAddTraits(checked ? .isSelected : [])
    }

    // MARK: Действия

    /// Первая заявка — имя из профиля (если поле пустое).
    private func prefillName() async {
        guard fullName.isEmpty else { return }
        if let p: Profile = try? await API.shared.get("api/v1/profile"), fullName.isEmpty {
            fullName = p.name ?? ""
        }
    }

    private func shoot(_ kind: String) {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            topError = "Нет камеры — выберите фото из галереи"
            return
        }
        // Доступ к камере запрещён — системная камера откроется чёрной: объясняем и ведём в настройки.
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .denied, .restricted:
            cameraDenied = true
            return
        default:
            break
        }
        cameraReq = CourierPhotoRequest(kind: kind)
    }

    private func loadPicked(_ item: PhotosPickerItem?, kind: String) {
        guard let item else { return }
        processing = kind
        Task {
            let raw = try? await item.loadTransferable(type: Data.self)
            if kind == "photo" { photoItem = nil } else { licenseItem = nil }
            guard let raw else {
                processing = nil
                topError = "Не удалось прочитать фото — попробуйте ещё раз"
                return
            }
            process(kind, raw)
        }
    }

    /// Сжать снимок вне главного потока и запомнить готовый JPEG.
    private func process(_ kind: String, _ raw: Data) {
        process(kind, source: { raw })
    }

    /// Снимок камеры: jpegData(0.92) кадра 12 Мп — сотни мс, раньше шло на
    /// главном потоке в колбэке камеры. Теперь и это кодирование в Task.detached.
    private func process(_ kind: String, image: UIImage) {
        process(kind, source: { image.jpegData(compressionQuality: 0.92) })
    }

    private func process(_ kind: String, source: @escaping @Sendable () -> Data?) {
        processing = kind
        Task { @MainActor in
            let (out, small) = await Task.detached(priority: .userInitiated) { () -> (Data?, Data?) in
                guard let raw = source() else { return (nil, nil) }
                let o = CourierSignupText.jpeg(raw)
                let t = o.flatMap { ImageUpload.jpeg(from: $0, maxSide: 300, quality: 0.8) }
                return (o, t)
            }.value
            if let data = out {
                let thumb = small.flatMap { UIImage(data: $0) }
                if kind == "photo" { photo = data; photoThumb = thumb } else { license = data; licenseThumb = thumb }
                fields[kind] = nil
            } else {
                topError = "Не удалось прочитать фото — попробуйте ещё раз"
            }
            processing = nil
        }
    }

    private func submit() {
        guard !sending, processing == nil else { return }   // двойное нажатие — один запрос
        let local = CourierSignupText.localErrors(
            cityId: cityId,
            hasPhoto: photo != nil || courier?.hasPhoto == true,
            hasLicense: license != nil || courier?.hasLicense == true,
            consentPd: consentPd, consentRules: consentRules, consentedBefore: courier?.consentAt != nil,
            rule: rule, noPassengers: noPassengers)
        if !local.isEmpty {
            fields = local
            topError = CourierSignupText.check
            return
        }
        sending = true
        topError = nil
        Task {
            do {
                let m = try await CourierAPI.apply(fullName: fullName, cityId: cityId, carModel: carModel,
                                                   carColor: carColor, carPlate: carPlate, selfEmployed: selfEmployed,
                                                   consent: consentPd && consentRules,
                                                   noPassengers: rule != nil ? noPassengers : nil,
                                                   photo: photo, license: license)
                sending = false
                fields = [:]
                // Снимки лица и прав в памяти не держим.
                photo = nil; license = nil
                onSent(m)
            } catch is CancellationError {
                sending = false
            } catch let f as CourierFailure {
                sending = false
                switch (f.status, f.code) {
                case (403, _):
                    // Аккаунт курьера заблокирован — экран покажет статус и причину.
                    topError = f.message
                    onReload()
                case (409, "disabled"):
                    topError = f.message
                    onDisabled()
                default:
                    fields = f.fields
                    topError = f.fields.isEmpty ? f.message : CourierSignupText.check
                }
            } catch {
                sending = false
                topError = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить заявку"
            }
        }
    }
}

/// Выбор города с поиском: те же города, что у веб-страницы и приложения курьера (with_orgs=1).
private struct CourierCityPicker: View {
    let onPick: (City) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cities: [City] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    private var filtered: [City] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return cities }
        return cities.filter { ($0.name ?? "").range(of: q, options: .caseInsensitive) != nil }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                TextField("Поиск города", text: $query)
                    .padding(.horizontal, YMSpace.lg)
                    .padding(.vertical, 12)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, YMSpace.md)
                if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let e = error, cities.isEmpty {
                    VStack(spacing: YMSpace.sm) {
                        Text(e).font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await load() } }
                            .font(YMFont.callout.weight(.bold)).foregroundStyle(YMColor.accent)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 40)
                } else if filtered.isEmpty {
                    Text("Город не найден — напишите в поддержку")
                        .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    ScrollView {
                        LazyVStack(spacing: YMSpace.sm) {
                            ForEach(filtered) { city in
                                Button { onPick(city) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(city.name ?? "—").font(YMFont.body).foregroundStyle(YMColor.text)
                                        if let r = city.region, !r.isEmpty {
                                            Text(r).font(YMFont.caption).foregroundStyle(YMColor.muted)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, YMSpace.lg).padding(.vertical, 12)
                                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.bottom, YMSpace.xl)
                    }
                }
                Spacer(minLength: 0)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Город")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }.foregroundStyle(YMColor.accent)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true; error = nil
        do {
            cities = try await CourierAPI.cities()
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить города"
        }
        loading = false
    }
}

/// Съёмка системной камерой (UIImagePickerController). front — фронтальная (селфи).
/// Разрешение на камеру iOS спрашивает сама при первом открытии (NSCameraUsageDescription в project.yml).
private struct CourierCameraPicker: UIViewControllerRepresentable {
    let front: Bool
    let onDone: (UIImage?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        if front && UIImagePickerController.isCameraDeviceAvailable(.front) {
            picker.cameraDevice = .front
        }
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onDone: (UIImage?) -> Void

        init(onDone: @escaping (UIImage?) -> Void) {
            self.onDone = onDone
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onDone(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onDone(nil)
        }
    }
}
