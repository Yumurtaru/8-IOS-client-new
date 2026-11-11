import AppIntents

// Siri и приложение «Команды» (iOS 16, App Intents). Все интенты только ОТКРЫВАЮТ нужный
// экран приложения (openAppWhenRun = true) и сами ничего не оформляют и не оплачивают.
// Маршрутизация — та же, что у быстрых действий иконки и push (AppRoute).

@available(iOS 16.0, *)
struct OpenOrdersIntent: AppIntent {
    static var title: LocalizedStringResource = "Мои заказы"
    static var description = IntentDescription("Открывает список ваших заказов в Yumurta.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRoute.perform(.orders)
        return .result()
    }
}

@available(iOS 16.0, *)
struct SendParcelIntent: AppIntent {
    static var title: LocalizedStringResource = "Отправить посылку"
    static var description = IntentDescription("Открывает форму отправки посылки в Yumurta.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRoute.perform(.sendParcel)
        return .result()
    }
}

@available(iOS 16.0, *)
struct RepeatLastOrderIntent: AppIntent {
    static var title: LocalizedStringResource = "Повторить последний заказ"
    static var description = IntentDescription("Открывает ваш последний заказ в Yumurta: там есть кнопка «Повторить заказ». Сам заказ не оформляется.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRoute.perform(.lastOrder)
        return .result()
    }
}

@available(iOS 16.0, *)
struct YumurtaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenOrdersIntent(),
            phrases: [
                "Мои заказы в \(.applicationName)",
                "Открой мои заказы в \(.applicationName)"
            ],
            shortTitle: "Мои заказы",
            systemImageName: "bag.fill"
        )
        AppShortcut(
            intent: SendParcelIntent(),
            phrases: [
                "Отправить посылку в \(.applicationName)",
                "Отправь посылку в \(.applicationName)"
            ],
            shortTitle: "Отправить посылку",
            systemImageName: "shippingbox.fill"
        )
        AppShortcut(
            intent: RepeatLastOrderIntent(),
            phrases: [
                "Повторить последний заказ в \(.applicationName)",
                "Повтори мой последний заказ в \(.applicationName)"
            ],
            shortTitle: "Повторить заказ",
            systemImageName: "arrow.clockwise"
        )
    }
}
