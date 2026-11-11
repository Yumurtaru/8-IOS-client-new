import StoreKit
import SwiftUI

/// Просьба оценить приложение в App Store. Только после хорошего опыта:
///   • заказ получен (статус done), и человек поставил 4–5 звёзд или вернулся к уже доставленному заказу;
///   • выполненных заказов (которые человек видел) не меньше 3;
///   • с прошлой просьбы прошло не меньше 120 дней.
/// Состояние хранится в UserDefaults. Сам системный диалог iOS показывает не всегда — это его правило.
enum ReviewPrompt {
    private static let doneKey = "review_done_orders"
    private static let lastKey = "review_last_ask"
    private static let seenKey = "review_seen_done_detail"
    static let minOrders = 3
    static let minDays = 120

    /// Выполненные заказы (id), которые человек видел в списке.
    static func noteDone(_ ids: [Int]) {
        guard !ids.isEmpty else { return }
        var set = Set(UserDefaults.standard.array(forKey: doneKey) as? [Int] ?? [])
        let before = set.count
        for id in ids { set.insert(id) }
        if set.count != before { UserDefaults.standard.set(Array(set.suffix(200)), forKey: doneKey) }
    }

    /// Человек открыл доставленный заказ. true — это уже НЕ первый раз («вернулся»).
    static func visitDone(_ id: Int) -> Bool {
        noteDone([id])
        var seen = UserDefaults.standard.array(forKey: seenKey) as? [Int] ?? []
        if seen.contains(id) { return true }
        seen.append(id)
        UserDefaults.standard.set(Array(seen.suffix(200)), forKey: seenKey)
        return false
    }

    /// Можно ли просить оценку прямо сейчас (3 заказа и 120 дней). При true время просьбы запоминается.
    static func claim() -> Bool {
        let done = (UserDefaults.standard.array(forKey: doneKey) as? [Int] ?? []).count
        guard done >= minOrders else { return false }
        let last = UserDefaults.standard.double(forKey: lastKey)
        if last > 0 {
            let days = (Date().timeIntervalSince1970 - last) / 86400
            guard days >= Double(minDays) else { return false }
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        return true
    }

    /// Выход из аккаунта: заказы прежнего человека не считаем. Дату последней просьбы
    /// оставляем — она про устройство, а не про аккаунт.
    static func clearAccountData() {
        UserDefaults.standard.removeObject(forKey: doneKey)
        UserDefaults.standard.removeObject(forKey: seenKey)
    }
}

/// Подключается к экрану заказа. isDone — заказ выполнен; goodReview — человек только что
/// отправил отзыв на 4–5 звёзд.
struct ReviewPromptModifier: ViewModifier {
    @Environment(\.requestReview) private var requestReview
    let orderId: Int
    let isDone: Bool
    let goodReview: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: isDone) { done in
                if done, ReviewPrompt.visitDone(orderId) { ask() }
            }
            .onChange(of: goodReview) { good in
                if good && isDone { ask() }
            }
    }

    private func ask() {
        guard ReviewPrompt.claim() else { return }
        let action = requestReview
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            action()
        }
    }
}

extension View {
    func reviewPrompt(orderId: Int, isDone: Bool, goodReview: Bool) -> some View {
        modifier(ReviewPromptModifier(orderId: orderId, isDone: isDone, goodReview: goodReview))
    }
}
