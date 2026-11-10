import UIKit

/// Тактильный отклик для ключевых действий.
/// Генераторы общие на всё приложение: создавать новый на каждое нажатие дороже
/// и даёт задержку отклика. prepare() заранее будит Taptic Engine.
enum Haptics {
    private static let notify = UINotificationFeedbackGenerator()
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let selectGen = UISelectionFeedbackGenerator()

    /// Подготовить генераторы (вызывать перед вероятным нажатием, на главном потоке).
    static func prepare() {
        notify.prepare(); lightGen.prepare(); mediumGen.prepare(); selectGen.prepare()
    }
    static func success() { notify.notificationOccurred(.success) }
    static func warning() { notify.notificationOccurred(.warning) }
    static func error()   { notify.notificationOccurred(.error) }
    static func light()   { lightGen.impactOccurred() }
    static func medium()  { mediumGen.impactOccurred() }
    static func selection() { selectGen.selectionChanged() }
}
