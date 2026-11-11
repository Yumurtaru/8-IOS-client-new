import Foundation
import LocalAuthentication

/// Подтверждение списания из кошелька / баллами: Face ID, Touch ID или код-пароль телефона.
/// Переключатель — «Профиль → Настройки → Подтверждать оплату Face ID». По умолчанию включён,
/// если на телефоне есть биометрия. Нет ни биометрии, ни код-пароля — подтверждать нечем,
/// оплата идёт как раньше (иначе человек не смог бы платить вовсе).
enum PayConfirm {
    static let storageKey = "confirm_pay_with_device_auth"

    /// Есть ли на телефоне Face ID / Touch ID.
    static var hasBiometrics: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
    }

    /// Можно ли подтвердить хоть чем-то (биометрия или код-пароль).
    static var canConfirm: Bool {
        var err: NSError?
        return LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: &err)
    }

    /// Включено ли подтверждение (нет сохранённого выбора — включено при наличии биометрии).
    static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: storageKey) == nil { return hasBiometrics }
            return UserDefaults.standard.bool(forKey: storageKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// Нужно ли сейчас спрашивать.
    static var isRequired: Bool { isEnabled && canConfirm }

    /// Спросить подтверждение. true — списывать можно; false — человек отказался или не прошёл
    /// проверку: ничего не списываем.
    static func confirm(reason: String) async -> Bool {
        guard isRequired else { return true }
        let context = LAContext()
        context.localizedCancelTitle = "Отмена"
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}
