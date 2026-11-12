import SwiftUI

/// Ключи @AppStorage (единая точка правды для персистентных настроек UI).
enum AppStorageKey {
    static let theme     = "appearance"   // "system" | "light" | "dark"; нет значения — "light" (по умолчанию светлая)
    static let onboarded = "onboarded"
    static let cityId    = "cityId"
    static let cityName  = "cityName"
}

@main
struct YumurtaApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session.shared
    // Синглтоны, которые body не читает: @StateObject не нужен (иначе корень
    // пересобирался при каждом изменении корзины/роутера).
    private let cart = Cart.shared
    @StateObject private var net = NetworkMonitor.shared
    private let router = DeepLinkRouter.shared
    private let coord = NavCoordinator.shared
    /// П-52: проверка «Вышла новая версия» — при запуске и каждом возврате на передний план.
    @Environment(\.scenePhase) private var scenePhase

    @AppStorage(AppStorageKey.theme) private var theme = "light"
    @AppStorage(AppStorageKey.onboarded) private var onboarded = false

    /// Анимация запуска. Показывается один раз за холодный старт.
    @State private var splashVisible = SplashSchedule.shouldShowAndMark()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(session)
                .environmentObject(cart)
                .environmentObject(net)
                .environmentObject(router)
                .environmentObject(coord)
                .tint(YMColor.accent)
                // Редизайн, этап 2: текст без явного шрифта — Golos Text того же размера,
                // что системный по умолчанию (17, растёт с «Размером текста»).
                .font(YMFont.golos(17, .regular, relativeTo: .body))
                .preferredColorScheme(colorScheme)
                .fullScreenCover(isPresented: Binding(
                    // Онбординг ждёт, пока доиграет анимация запуска: модальный
                    // экран показывается ПОВЕРХ всего, включая overlay ниже, и
                    // иначе перекрыл бы её на первом запуске.
                    get: { !onboarded && !splashVisible },
                    set: { if !$0 { onboarded = true } }
                )) {
                    OnboardingView(onFinish: { onboarded = true })
                        // ВАЖНО: модальные экраны в этом проекте НЕ наследуют
                        // environmentObject автоматически — пробрасываем явно,
                        // иначе @EnvironmentObject session в онбординге падает на старте.
                        .environmentObject(session)
                        .environmentObject(cart)
                        .environmentObject(net)
                        .environmentObject(router)
                        .environmentObject(coord)
                        .preferredColorScheme(colorScheme)
                }
                // Анимация идёт ПОВЕРХ приложения, а не вместо него: RootTabView
                // под ней уже смонтирован и грузит данные, поэтому сплэш ничего
                // не задерживает. overlay выбран вместо ZStack намеренно — он не
                // влияет на раскладку того, на что накладывается.
                .overlay {
                    if splashVisible {
                        SplashView(onFinished: {
                            splashVisible = false
                            // П-52: окно обновления ждёт конца анимации запуска.
                            AppUpdateStore.shared.splashDidFinish()
                        })
                            .ignoresSafeArea()
                            .preferredColorScheme(colorScheme)
                    }
                }
                .onOpenURL { url in router.handle(url: url) }
                // Результат Spotlight (заведение, товар, заказ).
                .onContinueUserActivity(SpotlightIndex.activityType) { activity in
                    SpotlightIndex.handle(activity: activity)
                }
                .onAppear {
                    AppRoute.markReady()
                    // Заставка сегодня уже была — окно обновления не ждёт её конца.
                    if !splashVisible { AppUpdateStore.shared.splashDidFinish() }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { router.handle(url: url) }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active {
                        AppUpdateStore.shared.onForeground()
                        // Виджеты и Live Activity заказа берут свежие данные при возврате в приложение
                        // (applicationDidBecomeActive в приложении со сценами не вызывается).
                        Task { await OrderWidgetBridge.syncOnActive() }
                    }
                }
                .task {
                    // П-52: в фоне, запуск не ждёт (не чаще раза в 6 часов).
                    await MainActor.run { AppUpdateStore.shared.onForeground() }
                    await Push.shared.registerIfPossible()
                }
        }
    }

    /// Тема применяется глобально через preferredColorScheme.
    private var colorScheme: ColorScheme? {
        switch theme {
        case "light": return .light
        case "dark":  return .dark
        default:      return nil   // system
        }
    }
}
