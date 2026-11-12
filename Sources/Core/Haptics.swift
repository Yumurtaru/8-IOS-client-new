import UIKit

/// Тактильный отклик для ключевых действий.
/// Генераторы общие на всё приложение: создавать новый на каждое нажатие дороже
/// и даёт задержку отклика. prepare() заранее будит Taptic Engine.
enum Haptics {
    private static let notify = UINotificationFeedbackGenerator()
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let selectGen = UISelectionFeedbackGenerator()
    /// Время последнего удара/уведомления — чтобы не дублировать отклик (lightIfQuiet).
    private static var lastAt: CFTimeInterval = 0

    /// Подготовить генераторы (вызывать перед вероятным нажатием, на главном потоке).
    static func prepare() {
        notify.prepare(); lightGen.prepare(); mediumGen.prepare(); selectGen.prepare()
    }
    static func success() { lastAt = CACurrentMediaTime(); notify.notificationOccurred(.success) }
    static func warning() { lastAt = CACurrentMediaTime(); notify.notificationOccurred(.warning) }
    static func error()   { lastAt = CACurrentMediaTime(); notify.notificationOccurred(.error) }
    static func light()   { lastAt = CACurrentMediaTime(); lightGen.impactOccurred() }
    static func medium()  { lastAt = CACurrentMediaTime(); mediumGen.impactOccurred() }
    /// Лёгкий отклик, только если за последние `within` с другого не было
    /// (экран товара уже дал success на «В корзину» — второй не нужен).
    static func lightIfQuiet(within: CFTimeInterval = 0.5) {
        if CACurrentMediaTime() - lastAt > within { light() }
    }
    static func selection() { selectGen.selectionChanged() }
}
