import SwiftUI

/// Короткое сообщение внизу экрана (2,5 с) — для отказов фоновых действий без
/// своей формы: например ♥ «в избранное». Раньше сердечко молча возвращалось
/// назад, и человек не знал причины (нет связи, нужно войти, отказ сервера).
/// Тёмная подложка и белый текст читаются и в светлой, и в тёмной теме.
private struct ErrorToastModifier: ViewModifier {
    @Binding var text: String?
    var bottom: CGFloat

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let t = text {
                Text(t)
                    .font(YMFont.caption).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.black.opacity(0.85), in: Capsule())
                    .padding(.horizontal, YMSpace.lg)
                    .padding(.bottom, bottom)
                    // Свой таймер у каждого текста: новый не гаснет раньше срока.
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if !Task.isCancelled { text = nil }
                    }
                    // Ушли с экрана раньше таймера — при возврате старое сообщение не показываем.
                    .onDisappear { text = nil }
            }
        }
    }
}

extension View {
    /// Показать text коротким сообщением внизу; по таймеру text сбрасывается в nil.
    /// bottom — отступ снизу (над липкой корзиной экрана — побольше).
    func errorToast(_ text: Binding<String?>, bottom: CGFloat = YMSpace.lg) -> some View {
        modifier(ErrorToastModifier(text: text, bottom: bottom))
    }
}

extension Error {
    /// Текст для человека или nil, если показывать нечего (отмена запроса).
    var userMessage: String? {
        if self is CancellationError { return nil }
        return (self as? LocalizedError)?.errorDescription ?? "Не удалось выполнить действие. Попробуйте ещё раз"
    }
}
