import Foundation
import UIKit

final class Push {
    static let shared = Push()
    var fcmToken: String?

    /// Запросить разрешение на уведомления (вызывать после входа / в настройках).
    func requestAuthorization() {
        (UIApplication.shared.delegate as? AppDelegate)?.requestPushAuth()
    }

    /// Отправить токен на бэкенд (если вошли и токен получен).
    /// Вместе с токеном уходит выбранный город: по нему приходят уведомления
    /// о новых заведениях в городе клиента.
    func registerIfPossible() async {
        guard let token = fcmToken, TokenStore.access != nil else { return }
        let city = Session.shared.cityId
        // А105: id установки — только когда файлы открыты (не до первой разблокировки):
        // иначе InstallInfo не прочитает id и поле просто не уйдёт.
        let unlocked = await MainActor.run { UIApplication.shared.isProtectedDataAvailable }
        let devId = InstallInfo.loadDeviceId(protectedDataAvailable: unlocked)
        try? await API.shared.postVoid(
            "api/v1/push/register",
            body: PushBody(token: token, platform: "ios", cityId: (city ?? 0) > 0 ? city : nil,
                           // А105: версия, сборка, id установки, модель и ОС — статистика на сайте.
                           appVersion: InstallInfo.appVersion, appBuild: InstallInfo.appBuild,
                           deviceId: devId, deviceModel: InstallInfo.deviceModel,
                           osVersion: InstallInfo.osVersion))
    }

    /// П-28.6: сессия истекла (продление отказано) — гасим push-токен этого
    /// телефона на сервере, иначе уведомления прежнего входа шли бы сюда и дальше.
    /// POST api/v1/push/unregister {token} — без Authorization (сессии уже нет),
    /// ответ не ждём и не разбираем. Следующий вход снова регистрирует токен
    /// (Session.signIn → registerIfPossible), как и раньше. Старый сервер
    /// ответит 404 — это ничего не ломает.
    func unregisterSilently() {
        guard let token = fcmToken, !token.isEmpty,
              let url = URL(string: API.base + "/api/v1/push/unregister"),
              let body = try? JSONSerialization.data(withJSONObject: ["token": token]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 15
        // Отдельная сессия без cookie: заголовка входа и чужих cookie здесь быть не должно.
        let s = URLSession(configuration: .ephemeral)
        s.dataTask(with: req) { _, _, _ in }.resume()
        s.finishTasksAndInvalidate()
    }
}
