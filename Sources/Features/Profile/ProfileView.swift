//
//  ProfileView.swift — Профиль (premium-клиент)
//
//  Макет ProfilePhone: аватар 72 (золотой градиент), имя, телефон, 📍 город;
//  быстрые статы (заказы/избранное/записи; записи считаются по GET api/v1/appointments);
//  переключатель темы (Система/Светлая/Тёмная);
//  меню: Адреса, Уведомления (бейдж), Оплата, Мои записи, Поддержка, Выйти (красный),
//  удаление аккаунта. Токены, light+dark, Dynamic Type, Reduce Motion.
//
//  ИНИЦИАЛИЗАТОР (для навигации из RootTabView):
//    ProfileView(onOpenAddresses: (() -> Void)? = nil,
//                onOpenBookings:  (() -> Void)? = nil,
//                onOpenNotifications: (() -> Void)? = nil,
//                onOpenPayment:   (() -> Void)? = nil,
//                onOpenSupport:   (() -> Void)? = nil)
//  Если колбэк не передан — экран сам открывает соответствующий раздел через
//  внутренний NavigationStack (AddressesView / BookingsView).
//
//  ТЕМА: пишет в @AppStorage(AppStorageKey.theme) == "appearance" — ТОТ ЖЕ ключ,
//  который читает YumurtaApp.colorScheme (значения "system"|"light"|"dark").
//
//  ПРИВЯЗКА К API (как в старом ProfileView):
//    • GET  api/v1/profile                → Profile
//    • GET  api/v1/orders                 → [Order]   (счётчик «заказы»)
//    • GET  api/v1/favorites + product-favorites (счётчик «в избранном»)
//    • POST api/v1/auth/logout            (выход) → Session.signOut()
//    • DELETE api/v1/profile              (удаление аккаунта) → см. TODO(API) ниже
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var session: Session

    // Внешняя навигация (опционально). nil → внутренний NavigationStack push.
    private let onOpenAddresses: (() -> Void)?
    private let onOpenBookings: (() -> Void)?
    private let onOpenNotifications: (() -> Void)?
    private let onOpenPayment: (() -> Void)?
    private let onOpenSupport: (() -> Void)?

    init(onOpenAddresses: (() -> Void)? = nil,
         onOpenBookings: (() -> Void)? = nil,
         onOpenNotifications: (() -> Void)? = nil,
         onOpenPayment: (() -> Void)? = nil,
         onOpenSupport: (() -> Void)? = nil) {
        self.onOpenAddresses = onOpenAddresses
        self.onOpenBookings = onOpenBookings
        self.onOpenNotifications = onOpenNotifications
        self.onOpenPayment = onOpenPayment
        self.onOpenSupport = onOpenSupport
    }

    @AppStorage(AppStorageKey.theme) private var theme = "system"
    /// Тема экрана из выбранного оформления (реактивно через @AppStorage).
    private var themeScheme: ColorScheme? {
        switch theme { case "light": return .light; case "dark": return .dark; default: return nil }
    }

    @State private var profile: Profile?
    @State private var ordersCount = 0
    @State private var favCount = 0
    @State private var bookingsCount = 0
    @State private var unreadNotifs = 0
    /// «Отправить посылку» (А79): кнопка — только если quote отвечает 200;
    /// «Мои посылки» — ещё и когда посылки уже были (раздел могли выключить).
    @State private var parcelCanSend = false
    @State private var hasParcels = false
    /// А97: GET /api/v1/features — «Отправить посылку» и «Стать курьером».
    @ObservedObject private var features = FeaturesStore.shared
    /// А97: у аккаунта уже есть заявка курьера (GET /pool/me) — пункт виден и при courier_signup: false.
    @State private var courierHasRecord = false
    /// Гость нажал «Стать курьером» / «Отправить посылку» — после входа открываем этот экран.
    @State private var afterAuth: AfterAuthTarget?
    private enum AfterAuthTarget { case courier, parcel }
    /// А102: гость тапнул push ответа поддержки или посылки — экран откроем после входа.
    /// Отдельно от ProfilePushIntent: его 15 с не хватает на вход по коду. Профиль закрыли
    /// или ушли со входа, не войдя, — забываем.
    @State private var pendingPush: ProfilePushIntent.Screen?

    /// «Отправить посылку»: parcels: true / false — сервер сказал прямо; неизвестно (старый сервер,
    /// нет сети) — как раньше, по quote.
    private var parcelSendShown: Bool { features.current.parcels ?? parcelCanSend }
    /// «Стать курьером»: courier_signup: true — всем; заявка уже есть — вошедшему всегда.
    private var courierShown: Bool { features.current.courierSignup == true || (session.isLoggedIn && courierHasRecord) }

    // Внутренняя навигация по разделам профиля (стек маршрутов).
    @State private var path = NavigationPath()

    @State private var showLogoutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
    /// Удаление аккаунта в полёте: повторное «Удалить» слало второй DELETE
    /// (уже без сессии — 401), а итог первого терялся.
    @State private var deleting = false
    /// Профиль не загрузился (нет сети) — раньше шапка молча показывала
    /// «Профиль» и нули, без причины и без повтора.
    @State private var profileFailed = false

    private var displayName: String { profile?.name?.isEmpty == false ? profile!.name! : "Профиль" }
    private var avatarLetter: String { String((profile?.name ?? "U").prefix(1)).uppercased() }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 0) {
                    if session.isLoggedIn {
                        header
                        if profileFailed && profile == nil {
                            HStack(spacing: YMSpace.sm) {
                                Text("Не удалось загрузить профиль. Проверьте связь.")
                                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                                Spacer(minLength: 0)
                                Button("Повторить") { Task { await load() } }
                                    .font(YMFont.caption)
                            }
                            .padding(.horizontal, YMSpace.xl)
                            .padding(.top, YMSpace.xs)
                        }
                        if let note = emailNote { emailNoteRow(note) }
                        // Карта клиента: штрихкод для кассы магазина. Блок сам
                        // ничего не рисует, если код не пришёл или невалиден.
                        if let code = profile?.clientCode {
                            ClientCardBlock(code: code)
                        }
                        stats
                        themeSwitcher
                        menu
                        deleteAccountButton
                    } else {
                        loggedOut
                        // Паритет с Android: гостю доступны разделы, которым вход не
                        // нужен (оформление, подарочная карта, вакансии, избранное,
                        // настройки, поддержка). Раньше профиль гостя был тупиком.
                        themeSwitcher
                        guestMenu
                    }
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ProfileRoute.self) { route in
                profileDestination(route)
            }
            .navigationDestination(for: ParcelRoute.self) { route in
                ParcelRouteView(route: route,
                                open: { path.append($0) },
                                replace: { next in
                                    if !path.isEmpty { path.removeLast() }
                                    path.append(next)
                                })
            }
        }
        // Профиль открывается модально (sheet) и НЕ наследует preferredColorScheme
        // корневого экрана — применяем тему здесь же, чтобы смена «Светлая/Тёмная»
        // менялась на экране профиля сразу, без переоткрытия.
        .preferredColorScheme(themeScheme)
        .task { if session.isLoggedIn { await load() } }
        .task { await features.refresh() }
        // Push/строка ленты «кошелёк пополнен», «ответ поддержки»: раньше
        // открывался только корень профиля — нужный раздел искали сами.
        .onAppear { consumePushIntent() }
        // А102: профиль закрыли, не войдя, — отложенный переход из push забываем.
        .onDisappear { if !session.isLoggedIn { pendingPush = nil } }
        .onReceive(NotificationCenter.default.publisher(for: ProfilePushIntent.note)) { _ in consumePushIntent() }
        // Push посылки или новый вызов — видимость раздела перепроверяем.
        .onReceive(NotificationCenter.default.publisher(for: .ymParcelPushed)) { _ in
            guard session.isLoggedIn else { return }
            ParcelGate.invalidate()
            Task { await loadParcelGate() }
        }
        // А97: решение по заявке курьера — видимость пункта перепроверяем.
        .onReceive(NotificationCenter.default.publisher(for: .ymCourierPushed)) { _ in
            guard session.isLoggedIn else { return }
            CourierGate.invalidate()
            Task { courierHasRecord = await CourierGate.check() }
        }
        .onChange(of: session.isLoggedIn) { logged in
            if logged {
                Task { await load() }
                // Гость нажимал «Стать курьером» / «Отправить посылку» — вошёл: открываем экран
                // (после того как экран входа закроется).
                // А102: гость тапнул push (переписка, посылка) и вошёл — открываем его экран.
                if let push = pendingPush {
                    pendingPush = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard session.isLoggedIn else { return }
                        path = NavigationPath()
                        openPush(push)
                    }
                }
                if let next = afterAuth {
                    afterAuth = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        guard session.isLoggedIn else { return }
                        path = NavigationPath()
                        switch next {
                        case .courier: path.append(ProfileRoute.courier)
                        case .parcel:  path.append(ParcelRoute.send(nil))
                        }
                    }
                }
            } else {
                profile = nil
                // Счётчики прежнего аккаунта не должны показываться следующему,
                // пока у него грузится профиль.
                ordersCount = 0; favCount = 0; bookingsCount = 0; unreadNotifs = 0
                parcelCanSend = false; hasParcels = false
                ParcelGate.reset()
                courierHasRecord = false
                CourierGate.reset()
                // Сессия кончилась на открытом разделе (кошелёк, бонусы, записи):
                // экран прежнего аккаунта оставался в стеке, и после входа другого
                // человека тот видел чужие данные. Возвращаемся к корню профиля.
                if !path.isEmpty { path = NavigationPath() }
            }
        }
        // Вернулись к корню профиля (например, из уведомлений) — счётчик обновляем.
        // Только счётчик уведомлений: полная перезагрузка дублировала запросы
        // и при сбое сети стирала шапку профиля.
        // Шапку перечитываем тоже (после «Редактировать профиль» там было старое
        // имя и телефон), но без стирания: не пришло — остаётся прежняя.
        .onChange(of: path.count) { n in
            // Гость ушёл со входа, не войдя, — отложенный переход забываем.
            if n == 0, !session.isLoggedIn { afterAuth = nil; pendingPush = nil }
            if n == 0, session.isLoggedIn {
                Task {
                    await loadUnread()
                    if let p: Profile = try? await API.shared.get("api/v1/profile"), session.isLoggedIn { profile = p }
                    await loadParcelGate()
                    // А97: заявку курьера могли только что отправить (кэш — без лишнего запроса).
                    let courier = await CourierGate.check()
                    if session.isLoggedIn { courierHasRecord = courier }
                }
            }
        }
        .confirmationDialog("Выйти из аккаунта?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Выйти", role: .destructive) { logout() }
            Button("Отмена", role: .cancel) {}
        }
        .confirmationDialog("Удалить аккаунт? Это действие необратимо.",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Удалить аккаунт", role: .destructive) { deleteAccount() }
            Button("Отмена", role: .cancel) {}
        }
        .alert("Аккаунт не удалён", isPresented: Binding(
            get: { deleteError != nil }, set: { if !$0 { deleteError = nil } }
        )) {
            Button("Понятно", role: .cancel) { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
    }

    // ── Экраны разделов профиля (единый билдер для NavigationPath) ──
    @ViewBuilder
    private func profileDestination(_ route: ProfileRoute) -> some View {
        switch route {
        case .addresses:    AddressesView()
        case .bookings:     BookingsView()
        case .notifications: NotificationsView()
        case .editProfile:  EditProfileView()
        case .settings:     SettingsView()
        case .support:      SupportView()
        case .plus:         PlusView()
        case .loyalty:      LoyaltyView()
        case .wallet:       WalletView()
        // FavoritesScreen(…) без аргументов: у типа их нет вовсе
        // (DiscoverView.swift), переходы он делает сам.
        case .favorites:    FavoritesScreen()
        case .myAds:        MyAdsView()
        case .bonuses:      BonusesView()
        case .referral:     ReferralView()
        case .gift:         GiftCardView()
        case .jobs:         JobsView()
        case .applications: ApplicationsView()
        case .returns:      ReturnsView()
        case .auth:         AuthView()
        // А97: «Стать курьером»; 422 errors.phone — «Редактировать профиль» поверх.
        case .courier:      CourierSignupView(openEditProfile: { path.append(ProfileRoute.editProfile) })
        // А102: переписка с поддержкой (push type=support + ticket_id, строка ленты).
        case .supportTicket(let id): SupportTicketView(id: id)
        }
    }

    // ── Шапка: аватар 72 (золотой градиент), имя, телефон, город ──
    private var header: some View {
        HStack(spacing: YMSpace.lg) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [YMPalette.gold, YMPalette.goldDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .shadow(color: YMPalette.gold.opacity(0.5), radius: 24, y: 10)
                Text(avatarLetter)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(YMPalette.goldInk)
                // Паритет с Android: фото профиля (поле avatar, путь от корня сайта).
                // Не загрузилось или его нет — остаётся буква на золотом круге.
                if let url = API.imageURL(profile?.avatar) {
                    CachedAsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName)
                    .font(.system(size: 22, weight: .heavy)).tracking(-0.4)
                    .foregroundStyle(YMColor.text).lineLimit(1)
                if let phone = profile?.phone, !phone.isEmpty {
                    Text(phone).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
                }
                if let city = session.cityName, !city.isEmpty {
                    HStack(spacing: 5) {
                        Text("📍")
                        Text(city).font(.system(size: 12.5, weight: .bold))
                    }
                    .foregroundStyle(YMColor.accent)
                    .padding(.top, 3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.md)
        .padding(.bottom, YMSpace.xs)
    }

    // ── А114: почта не подтверждена / письма не доходят ──
    /// Текст строки под шапкой; nil — с почтой всё в порядке (или старый сервер).
    private var emailNote: (text: String, problem: Bool)? {
        guard let p = profile, !(p.email ?? "").trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        if p.emailProblem != nil { return ("Письма на эту почту не доходят — укажите другую", true) }
        if p.emailVerified == false { return ("Почта не подтверждена — подтвердить", false) }
        return nil
    }

    private func emailNoteRow(_ note: (text: String, problem: Bool)) -> some View {
        Button {
            Haptics.light()
            path.append(ProfileRoute.editProfile)
        } label: {
            HStack(spacing: YMSpace.sm) {
                Image(systemName: note.problem ? "exclamationmark.triangle.fill" : "envelope.badge")
                    .foregroundStyle(note.problem ? YMColor.statusCancel : YMColor.accent)
                Text(note.text)
                    .font(YMFont.caption)
                    .foregroundStyle(note.problem ? YMColor.statusCancel : YMColor.text)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(YMColor.muted)
            }
            .padding(.horizontal, YMSpace.lg).padding(.vertical, YMSpace.md)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.sm)
    }

    // ── Быстрые статы ──
    private var stats: some View {
        HStack(spacing: 10) {
            statCard(value: ordersCount, label: pluralOrders(ordersCount))
            statCard(value: favCount, label: "в избранном")
            statCard(value: bookingsCount, label: pluralBookings(bookingsCount))
        }
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    private func statCard(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .heavy))
                .foregroundStyle(YMColor.accent)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14).padding(.horizontal, 10)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }

    // ── Переключатель темы (пишет в реальный @AppStorage-ключ root) ──
    private var themeSwitcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Оформление")
                .font(.system(size: 13, weight: .heavy))
                .foregroundStyle(YMColor.text)
            YMSegmentedControl(options: ThemeOption.allCases.map { $0.title },
                               index: Binding(
                                   get: { ThemeOption(storage: theme).index },
                                   set: { theme = ThemeOption(index: $0).storage }
                               ))
        }
        .padding(14)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    // ── Программы и бонусы ──
    private var loyaltyMenu: some View {
        VStack(spacing: 0) {
            // Yumurta Plus и «Уровень лояльности» временно скрыты по требованию.
            menuRow(icon: "👛", label: "Кошелёк") { path.append(ProfileRoute.wallet) }
            divider
            menuRow(icon: "📣", label: "Мои объявления") { path.append(ProfileRoute.myAds) }
            divider
            menuRow(icon: "💰", label: "Бонусы") { path.append(ProfileRoute.bonuses) }
            divider
            menuRow(icon: "🎁", label: "Подарочная карта") { path.append(ProfileRoute.gift) }
            divider
            menuRow(icon: "🤝", label: "Пригласить друга") { path.append(ProfileRoute.referral) }
            divider
            menuRow(icon: "↩️", label: "Возвраты") { path.append(ProfileRoute.returns) }
            divider
            menuRow(icon: "💼", label: "Вакансии") { path.append(ProfileRoute.jobs) }
            divider
            menuRow(icon: "📝", label: "Мои отклики") { path.append(ProfileRoute.applications) }
        }
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    // ── Меню ──
    private var menu: some View {
        VStack(spacing: YMSpace.lg) {
            loyaltyMenu
            if parcelSendShown || parcelCanSend || hasParcels || courierShown { parcelMenu }
            VStack(spacing: 0) {
                menuRow(icon: "✏️", label: "Редактировать профиль") { path.append(ProfileRoute.editProfile) }
                divider
                menuRow(icon: "📍", label: "Адреса доставки") { openAddresses() }
                divider
                menuRow(icon: "🔔", label: "Уведомления", badge: unreadNotifs > 0 ? "\(unreadNotifs)" : nil) {
                    path.append(ProfileRoute.notifications)
                }
                divider
                menuRow(icon: "📅", label: "Мои записи") { openBookings() }
                divider
                // «Избранное» переехало сюда из нижней вкладки: её место занял
                // раздел объявлений.
                menuRow(icon: "❤️", label: "Избранное") { path.append(ProfileRoute.favorites) }
                divider
                menuRow(icon: "⚙️", label: "Настройки") { path.append(ProfileRoute.settings) }
                divider
                menuRow(icon: "🛟", label: "Поддержка") { path.append(ProfileRoute.support) }
                divider
                menuRow(icon: "🚪", label: "Выйти", danger: true, chevron: false) { showLogoutConfirm = true }
            }
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
            .padding(.horizontal, YMSpace.xl)
        }
    }

    // ── Посылки (А79): видно, только если раздел включён или посылки уже были ──
    // А97: здесь же «Стать курьером»; «Отправить посылку» — по features.parcels (неизвестно — как раньше).
    private var parcelMenu: some View {
        VStack(spacing: 0) {
            if parcelSendShown {
                menuRow(icon: "📦", label: "Отправить посылку") { path.append(ParcelRoute.send(nil)) }
            }
            if parcelCanSend || hasParcels || parcelSendShown {
                if parcelSendShown { divider }
                menuRow(icon: "🚚", label: "Мои посылки") { path.append(ParcelRoute.list(canSend: parcelSendShown)) }
            }
            if courierShown {
                if parcelSendShown || parcelCanSend || hasParcels { divider }
                menuRow(icon: "🛵", label: "Стать курьером") { path.append(ProfileRoute.courier) }
            }
        }
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.horizontal, YMSpace.xl)
    }

    private var divider: some View {
        Rectangle().fill(YMColor.hairline).frame(height: 1).padding(.leading, 64)
    }

    private func menuRow(icon: String, label: String, badge: String? = nil,
                         danger: Bool = false, chevron: Bool = true,
                         action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.light(); action() }) {
            HStack(spacing: YMSpace.lg) {
                Text(icon)
                    .font(.system(size: 16))
                    .frame(width: 34, height: 34)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(label)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(danger ? YMColor.statusCancel : YMColor.text)
                Spacer(minLength: 8)
                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(YMPalette.goldInk)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, 6)
                        .background(YMColor.accent, in: Capsule())
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(YMColor.muted)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // ── Меню гостя: разделы без входа (как в Android) ──
    private var guestMenu: some View {
        VStack(spacing: 0) {
            // А97: «Отправить посылку» и «Стать курьером» — когда сервер их включил; сначала вход.
            if features.current.parcels == true {
                menuRow(icon: "📦", label: "Отправить посылку") { afterAuth = .parcel; path.append(ProfileRoute.auth) }
                divider
            }
            if features.current.courierSignup == true {
                menuRow(icon: "🛵", label: "Стать курьером") { afterAuth = .courier; path.append(ProfileRoute.auth) }
                divider
            }
            menuRow(icon: "🎁", label: "Подарочная карта") { path.append(ProfileRoute.gift) }
            divider
            menuRow(icon: "💼", label: "Вакансии") { path.append(ProfileRoute.jobs) }
            divider
            menuRow(icon: "❤️", label: "Избранное") { path.append(ProfileRoute.favorites) }
            divider
            menuRow(icon: "⚙️", label: "Настройки") { path.append(ProfileRoute.settings) }
            divider
            menuRow(icon: "🛟", label: "Поддержка") { path.append(ProfileRoute.support) }
        }
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .padding(.horizontal, YMSpace.xl)
        .padding(.top, YMSpace.lg)
    }

    // ── Удаление аккаунта ──
    private var deleteAccountButton: some View {
        Button { if !deleting { showDeleteConfirm = true } } label: {
            Text(deleting ? "Удаляем аккаунт…" : "Удалить аккаунт")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(YMColor.statusCancel)
        }
        .disabled(deleting)
        .padding(.top, YMSpace.xl)
    }

    // ── Не залогинен ──
    private var loggedOut: some View {
        VStack(spacing: YMSpace.lg) {
            Text("👤").font(.system(size: 48))
            Text("Вы не вошли").font(YMFont.title3).foregroundStyle(YMColor.text)
            Text("Войдите, чтобы видеть профиль, записи и избранное.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                .padding(.horizontal, YMSpace.xxxl)
            Button { Haptics.light(); path.append(ProfileRoute.auth) } label: {
                Text("Войти в аккаунт").frame(maxWidth: .infinity)
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .padding(.horizontal, YMSpace.xxxl)
            .padding(.top, YMSpace.md)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    // ── Actions ──
    private func openAddresses() {
        if let cb = onOpenAddresses { cb() } else { path.append(ProfileRoute.addresses) }
    }
    private func openBookings() {
        if let cb = onOpenBookings { cb() } else { path.append(ProfileRoute.bookings) }
    }

    private func logout() {
        // Сначала запрос (с ещё живым токеном), потом локальный выход: раньше
        // signOut() успевал стереть токен до отправки, и сервер не знал, КТО
        // выходит, — сессия не закрывалась, push продолжали приходить сюда.
        // push_token — чтобы уведомления прежнего аккаунта сюда больше не шли.
        let body: [String: String] = Push.shared.fcmToken.map { ["push_token": $0] } ?? [:]
        Task {
            // Ждём ответ не дольше 3 секунд: без сети выход не должен «висеть».
            let req = Task { try? await API.shared.postVoid("api/v1/auth/logout", body: body) }
            // Раньше ждали через группу задач — а группа ждёт ВСЕХ детей, и выход
            // без сети висел до 40 с. Теперь ждём, что наступит раньше: ответ или
            // 3 секунды. Сам запрос не отменяем — он уже несёт токен и доведёт
            // выход на сервере (закрытие сессии, отвязку push) и после signOut.
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let once = ResumeOnce(c)
                Task { await req.value; once.fire() }
                Task { try? await Task.sleep(nanoseconds: 3_000_000_000); once.fire() }
            }
            session.signOut(clearLocalData: true)
            // Явный выход уже очистил корзину: что гость наберёт дальше, при
            // следующем входе (любым аккаунтом) не стираем (см. AuthLastUser).
            AuthLastUser.forget()
            profile = nil
        }
    }

    private func deleteAccount() {
        // TODO(API): эндпоинт удаления аккаунта (напр. DELETE api/v1/profile) в контракте
        // ещё не подтверждён. Пока — graceful: пытаемся вызвать, при отсутствии просто выходим.
        guard !deleting else { return }
        deleting = true
        Task {
            // Маршрут удаления — DELETE /api/v1/account (routes/api_v1.php).
            // Раньше здесь стоял "api/v1/profile": такого метода у этого пути
            // нет, ошибка гасилась `try?`, и человека просто разлогинивало —
            // аккаунт и данные оставались на сервере. Для App Store это ещё и
            // невыполненное обещание «удалить аккаунт».
            // Ошибку больше не гасим: сервер отказывает (409 — активные заказы,
            // деньги на балансе) или нет сети, а человека молча разлогинивало,
            // и он считал аккаунт удалённым.
            do {
                try await API.shared.deleteVoid("api/v1/account")
                // А108: сервер удалил установки человека — дальше новый id установки.
                InstallInfo.renewDeviceId()
                await MainActor.run { deleting = false; session.signOut(clearLocalData: true); AuthLastUser.forget(); profile = nil }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось удалить аккаунт"
                await MainActor.run { deleting = false; deleteError = msg }
            }
        }
    }

    private func load() async {
        var q: [String: String] = [:]
        // Город читаем здесь, до async let: дочерние задачи не трогают session.
        let parcelCity = session.cityId
        if let cid = session.cityId { q["city_id"] = String(cid) }
        let query = q
        // Шесть независимых запросов шли по очереди — на мобильной сети шапка и
        // счётчики появлялись через несколько секунд. Теперь параллельно.
        async let profileReq: Profile? = try? await API.shared.get("api/v1/profile")
        // Записи на услугу приходят в этом же списке (на сервере запись — это заказ),
        // но считаются отдельно, в счётчике «записи». Иначе один визит удваивал бы статистику.
        // Страница с meta: П-25 №2 (А62) — meta.total считает ВСЕ заказы, а не
        // первые 100 (у постоянного клиента счётчик застревал на 100).
        async let ordersReq: Page<Order>? = try? await API.shared.page("api/v1/orders", query: query)
        async let shopsReq: [Shop]? = try? await API.shared.list("api/v1/favorites")
        async let productsReq: [Product]? = try? await API.shared.list("api/v1/product-favorites")
        // П-21.3: записи постранично — счётчик по всем страницам, как в «Мои записи».
        async let apptsReq: [Appointment]? = try? await API.shared.allPages("api/v1/appointments", key: { (a: Appointment) in "\(a.id)-\(a.orderId ?? 0)" })
        // meta.unread — непрочитанные ВСЕГО (волна А3); на странице их максимум 20.
        // Старый сервер unread не присылает — считаем по первой странице, как раньше.
        async let notifReq: Page<AppNotification>? = try? await API.shared.page("api/v1/notifications")
        async let parcelReq = ParcelGate.flags(cityId: parcelCity)
        async let courierReq = CourierGate.check()

        // Сбой (метро, смена вкладки без сети) не стирает уже показанное: раньше
        // шапка превращалась в «Профиль» без телефона, а счётчики — в нули.
        let loaded = await profileReq
        if let p = loaded, session.isLoggedIn {
            profile = p
            AuthLastUser.confirm(p.id)
        }
        profileFailed = loaded == nil
        let ordersPage = await ordersReq
        let favShops = await shopsReq
        let favProducts = await productsReq
        if let favShops, let favProducts {
            favCount = favShops.count + favProducts.count
        }
        let appts = await apptsReq
        if let appts {
            bookingsCount = appts.count
        }
        if let ordersPage {
            ordersCount = Self.ordersTotal(ordersPage, appointments: appts?.count)
        }
        let notifPage = await notifReq
        unreadNotifs = notifPage.map { p in p.meta?.unread ?? p.items.filter { !$0.read }.count } ?? 0
        let gate = await parcelReq
        if session.isLoggedIn { parcelCanSend = gate.canSend; hasParcels = gate.hasParcels }
        let courier = await courierReq
        if session.isLoggedIn { courierHasRecord = courier }
    }

    /// Видимость раздела посылок (после возврата к корню профиля — могли отправить).
    private func loadParcelGate() async {
        let city = session.cityId
        let gate = await ParcelGate.flags(cityId: city)
        if session.isLoggedIn { parcelCanSend = gate.canSend; hasParcels = gate.hasParcels }
    }

    /// Счётчик «заказы» без записей на услугу. Вся история на одной странице —
    /// считаем точно, как раньше. Страниц больше — meta.total (в нём и записи,
    /// отдельного счётчика сервер не даёт) минус записи; не меньше, чем видно
    /// на первой странице. Старый сервер без total — по странице.
    private static func ordersTotal(_ page: Page<Order>, appointments: Int?) -> Int {
        let shown = page.items.filter { $0.isAppointment != true }.count
        guard page.hasMore, let total = page.meta?.total else { return shown }
        let onPage = page.items.count - shown
        let appts = max(appointments ?? onPage, onPage)
        return max(total - appts, shown)
    }

    private func loadUnread() async {
        guard let p: Page<AppNotification> = try? await API.shared.page("api/v1/notifications") else { return }
        unreadNotifs = p.meta?.unread ?? p.items.filter { !$0.read }.count
    }

    /// Раздел, о котором просит push или строка ленты уведомлений (см. ProfilePushIntent).
    private func consumePushIntent() {
        guard let screen = ProfilePushIntent.take() else { return }
        guard session.isLoggedIn else {
            // А102: гостю — после входа (onChange(of: isLoggedIn)). Только переписка и посылка:
            // остальные разделы гостю, как раньше, не открываем.
            switch screen {
            case .ticket, .parcel: pendingPush = screen
            // А104: лента после push о выигрыше в розыгрыше (гостем .notifications приходит только от него).
            case .notifications: pendingPush = screen
            default: break
            }
            return
        }
        openPush(screen)
    }

    /// Открыть раздел по push / строке ленты (только вошедшему).
    private func openPush(_ screen: ProfilePushIntent.Screen) {
        switch screen {
        case .wallet:        path.append(ProfileRoute.wallet)
        case .support:       path.append(ProfileRoute.support)
        case .bonuses:       path.append(ProfileRoute.bonuses)
        case .notifications: path.append(ProfileRoute.notifications)
        // Push pool_parcel: карточка посылки. Она уже открыта — только перечитываем.
        case .parcel(let id):
            if ParcelLive.cardId == id {
                NotificationCenter.default.post(name: .ymParcelPushed, object: id)
            } else {
                path.append(ParcelRoute.detail(id))
            }
        // А97: карточка «Отправить посылку» на главной — тот же экран, что здесь.
        case .parcelNew:     path.append(ParcelRoute.send(nil))
        // А97: push pool_account — экран «Стать курьером». Уже открыт — только перечитываем.
        case .courier:
            if CourierLive.open {
                NotificationCenter.default.post(name: .ymCourierPushed, object: nil)
            } else {
                path.append(ProfileRoute.courier)
            }
        // А102: ответ поддержки — переписка этого обращения. Уже открыта — только перечитываем.
        case .ticket(let id):
            if SupportTicketLive.openId == id {
                NotificationCenter.default.post(name: .ymSupportPushed, object: id)
            } else {
                path.append(ProfileRoute.supportTicket(id))
            }
        }
    }

    private func pluralOrders(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "заказ" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "заказа" }
        return "заказов"
    }
    private func pluralBookings(_ n: Int) -> String {
        let m10 = n % 10, m100 = n % 100
        if m10 == 1 && m100 != 11 { return "запись" }
        if (2...4).contains(m10) && !(12...14).contains(m100) { return "записи" }
        return "записей"
    }
}

/// Какой раздел профиля открыть по push или из ленты уведомлений.
/// Ставит вызывающий (AppDelegate рядом с profileOpen = true, лента — прямо
/// из профиля), забирает ProfileView: при появлении и по уведомлению note.
/// Старше 15 с — не исполняется: иначе застрявшая просьба сработала бы
/// позже, когда человек сам откроет профиль.
enum ProfilePushIntent {
    enum Screen { case wallet, support, bonuses, notifications, parcel(Int), parcelNew, courier, ticket(Int) }
    static let note = Notification.Name("ym.profilePushIntent")
    private static var pending: (screen: Screen, at: Date)?

    static func open(_ screen: Screen) {
        pending = (screen, Date())
        NotificationCenter.default.post(name: note, object: nil)
    }

    static func take() -> Screen? {
        guard let p = pending else { return nil }
        pending = nil
        return Date().timeIntervalSince(p.at) < 15 ? p.screen : nil
    }
}

/// Разделы профиля для NavigationPath (значения-маршруты).
private enum ProfileRoute: Hashable {
    case addresses, bookings, notifications, editProfile, settings, support
    case plus, loyalty, wallet, myAds, favorites, bonuses, referral, gift, jobs, applications, returns, auth
    case courier
    case supportTicket(Int)
}

/// Опция темы ↔ значение @AppStorage(AppStorageKey.theme) ("system"|"light"|"dark").
private enum ThemeOption: CaseIterable {
    case system, light, dark
    var title: String { self == .system ? "Система" : self == .light ? "Светлая" : "Тёмная" }
    var storage: String { self == .system ? "system" : self == .light ? "light" : "dark" }
    var index: Int { self == .system ? 0 : self == .light ? 1 : 2 }

    init(storage: String) {
        switch storage {
        case "light": self = .light
        case "dark":  self = .dark
        default:      self = .system
        }
    }
    init(index: Int) {
        switch index {
        case 1:  self = .light
        case 2:  self = .dark
        default: self = .system
        }
    }
}

/// Продолжение, которое возобновляется ровно один раз (кто первый — ответ или таймер).
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var cont: CheckedContinuation<Void, Never>?
    init(_ c: CheckedContinuation<Void, Never>) { cont = c }
    func fire() {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume()
    }
}
