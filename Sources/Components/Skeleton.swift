import SwiftUI

/// Shimmer-плейсхолдер вместо спиннеров (README: skeleton shimmer при загрузке).
/// Уважает Reduce Motion — без анимации показывает статичную поверхность.
struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay(gradient.mask(content)).onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                phase = 2
            }
        }
    }
    private var gradient: some View {
        GeometryReader { geo in
            LinearGradient(
                colors: [.clear, YMColor.text.opacity(0.10), .clear],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: geo.size.width * 1.4)
            .offset(x: reduceMotion ? 0 : geo.size.width * phase)
        }
    }
}

extension View {
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Прямоугольная скелетон-плашка (surface2 + shimmer).
struct SkeletonBox: View {
    var radius: CGFloat = YMRadius.control
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(YMColor.surface2)
            .shimmer()
    }
}
