import UIKit

/// Быстрые действия иконки (долгое нажатие). Сами пункты описаны в Info.plist
/// (UIApplicationShortcutItems в project.yml); здесь — разбор нажатия.
enum QuickActions {
    /// Нажатие на пункт → маршрут приложения. true — пункт знакомый.
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        let type = item.type
        if type.hasSuffix(".orders") {
            AppRoute.perform(.orders)
        } else if type.hasSuffix(".parcel") {
            AppRoute.perform(.sendParcel)
        } else if type.hasSuffix(".search") {
            AppRoute.perform(.search)
        } else if type.hasSuffix(".cart") {
            AppRoute.perform(.cart)
        } else {
            return false
        }
        return true
    }
}

/// Делегат сцены нужен только ради быстрых действий на уже запущенном приложении
/// (SwiftUI-приложение без него не получает performActionFor).
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(QuickActions.handle(shortcutItem))
    }
}
