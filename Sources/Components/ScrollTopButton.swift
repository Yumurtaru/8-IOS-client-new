import SwiftUI

/// Кнопка «Наверх» (ТЗ раздел 4): белый круг 44 со стрелкой. Показывает вызывающий,
/// когда экран прокручен больше чем на один экран; нажатие плавно возвращает к началу.
struct ScrollTopButton: View {
    var action: () -> Void

    var body: some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Image(systemName: "arrow.up")
                .ymIcon(17, weight: .semibold)
                .foregroundStyle(Color(hex: "#1A1206"))
                .frame(width: 44, height: 44)
                .background(Color.white, in: Circle())
                .shadow(color: Color.black.opacity(0.16), radius: 10, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Наверх")
    }
}

/// Смещение содержимого прокрутки относительно начала (отрицательное при прокрутке вниз).
struct YMScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Вешается на НЕ ленивое содержимое ScrollView (контейнер задаёт `.coordinateSpace(name:)`).
    /// `isFar` становится true, когда прокручено дальше высоты экрана.
    func ymTrackScrollFar(space: String, isFar: Binding<Bool>) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: YMScrollOffsetKey.self, value: g.frame(in: .named(space)).minY)
            }
        )
        .onPreferenceChange(YMScrollOffsetKey.self) { y in
            let far = y < -UIScreen.main.bounds.height
            if far != isFar.wrappedValue { isFar.wrappedValue = far }
        }
    }
}
