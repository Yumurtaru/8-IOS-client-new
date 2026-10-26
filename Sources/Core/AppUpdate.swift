import SwiftUI
import UIKit

/// П-52 (волна А101): «Вышла новая версия — обновите».
///
/// YumurtaApp (запуск и каждый переход scenePhase → .active) зовёт onForeground: сервер
/// спрашиваем в фоне не чаще раза в 6 часов, а пока показан обязательный экран — при каждом
/// возврате (обновился — экран исчезнет). Любая ошибка (404 старого сервера, 429, нет сети,
/// битый ответ) — молча ничего: состояние и время проверки не трогаем.
///
/// Последний ответ хранится в UserDefaults: обязательное обновление после перезапуска
/// показывается сразу, не дожидаясь следующей проверки.
///  • обязательное — отдельное окно поверх всего (ForceUpdateWindow), закрыть нельзя;
///  • мягкое — системное окно «Обновить» / «Позже» в RootTabView, только на «Главной»
///    без других окон и после анимации запуска.
@MainActor
final class AppUpdateStore: ObservableObject {
    static let shared = AppUpdateStore()

    /// Обязательное обновление — или nil.
    @Published private(set) var force: AppVersionInfo?
    /// Мягкое окно «Вышла новая версия» ждёт показа — или nil.
    @Published private(set) var soft: AppVersionInfo?
    /// Анимация запуска доиграла: до этого ни экран, ни окно не показываем.
    @Published private(set) var splashFinished = !splashEnabled

    private enum Key {
        static let checkedAt = "updCheckedAt"
        static let info = "updInfo"
        static let snoozeKey = "updSnoozeKey"
        static let snoozedAt = "updSnoozedAt"
    }
    private let defaults = UserDefaults.standard
    private var running = false
    private var restored = false

    /// Установленная версия (CFBundleShortVersionString).
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
    }

    func onForeground() {
        let now = Date().timeIntervalSince1970
        if !restored {
            restored = true
            apply(AppVersionInfo.parseStored(defaults.string(forKey: Key.info) ?? ""), now: now)
        }
        // Окно могло не открыться (сцена ещё не была активной) — пробуем снова.
        syncForceWindow()
        guard AppUpdateLogic.shouldCheck(now: now, lastSuccessAt: defaults.double(forKey: Key.checkedAt),
                                         forceShown: force != nil) else { return }
        guard !running else { return }
        running = true
        // А105: + version, build, device_id, device_model, os_version — статистика версий на
        // сайте (AppInstalls::fromVersionCheck); старый сервер лишние параметры игнорирует.
        // До первой разблокировки (фоновый запуск тихим push / prewarm) файлы закрыты — без них:
        // иначе прочитали бы «нет id» (InstallInfo).
        let install = UIApplication.shared.isProtectedDataAvailable ? InstallInfo.versionQuery : [:]
        Task { [weak self] in
            // 404 / 429 / 5xx / нет сети / не JSON — как раньше, без окна.
            var query = install
            query["app"] = "client"
            query["platform"] = "ios"
            let res = try? await API.shared.raw("GET", "api/v1/app-version", json: nil, query: query)
            guard let self = self else { return }
            self.running = false
            // 404 — ручки на сервере больше нет: сохранённый ответ (и обязательное обновление
            // из него) забываем, иначе снять его было бы нечем. Прочие ошибки его не трогают.
            if let res = res, res.status == 404 {
                self.defaults.removeObject(forKey: Key.info)
                self.apply(nil, now: Date().timeIntervalSince1970)
                return
            }
            guard let res = res, (200..<300).contains(res.status), let info = AppVersionInfo.parse(res.data) else { return }
            let at = Date().timeIntervalSince1970
            self.defaults.set(at, forKey: Key.checkedAt)
            self.defaults.set(info.stored(), forKey: Key.info)
            self.apply(info, now: at)
        }
    }

    func splashDidFinish() {
        splashFinished = true
        syncForceWindow()
    }

    /// «Позже» (и «Обновить») в мягком окне: эту версию не показываем сутки.
    func snoozeSoft(_ info: AppVersionInfo) {
        defaults.set(AppUpdateLogic.snoozeKey(info), forKey: Key.snoozeKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Key.snoozedAt)
        if soft == info { soft = nil }
    }

    private func apply(_ info: AppVersionInfo?, now: TimeInterval) {
        let kind = AppUpdateLogic.decide(info, version: Self.currentVersion,
                                         snoozedKey: defaults.string(forKey: Key.snoozeKey) ?? "",
                                         snoozedAt: defaults.double(forKey: Key.snoozedAt), now: now)
        let newForce = kind == .force ? info : nil
        let newSoft = kind == .soft ? info : nil
        if force != newForce { force = newForce }
        if soft != newSoft { soft = newSoft }
        syncForceWindow()
    }

    private func syncForceWindow() {
        if let f = force, splashFinished { ForceUpdateWindow.shared.show(f) } else { ForceUpdateWindow.shared.hide() }
    }

    /// Открыть страницу приложения в App Store.
    static func openStore(_ url: String) {
        guard let u = URL(string: url) else { return }
        UIApplication.shared.open(u)
    }
}

/// Отдельное окно над всем приложением, включая шторки и обложки: обязательное обновление
/// не закрывается и не уходит под модальные экраны. VoiceOver не видит то, что под ним.
@MainActor
final class ForceUpdateWindow {
    static let shared = ForceUpdateWindow()
    private var window: UIWindow?
    private weak var previousKey: UIWindow?

    func show(_ info: AppVersionInfo) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.first(where: { $0.activationState == .foregroundActive })
        // Окно ещё живо на текущей активной сцене — только новый текст.
        if let w = window, let ws = w.windowScene,
           active == nil || ws === active, ws.activationState != .unattached,
           let host = w.rootViewController as? UIHostingController<ForceUpdateView> {
            host.rootView = ForceUpdateView(info: info)
            return
        }
        // Сцену пересоздала система (окно привязано к мёртвой сцене) — окно заново на активной.
        hide()
        guard let scene = active ?? scenes.first else { return }
        previousKey = scene.windows.first { $0.isKeyWindow }
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        w.rootViewController = UIHostingController(rootView: ForceUpdateView(info: info))
        w.accessibilityViewIsModal = true
        w.makeKeyAndVisible()
        window = w
    }

    func hide() {
        guard let w = window else { return }
        w.isHidden = true
        window = nil
        previousKey?.makeKey()
    }
}
