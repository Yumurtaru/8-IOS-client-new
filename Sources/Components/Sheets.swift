import SwiftUI

//
//  Sheets.swift — оформление всплывающих листов (редизайн, этап 6).
//  .ymSheetChrome(onClose:) — ручка, скругление, фон, круглый крестик 36 справа сверху.
//  onClose = nil — крестик не рисуется (у листа уже есть своя кнопка закрытия).
//  Только внешний вид: содержимое и onDismiss листа не меняются.
//

private struct YMSheetChrome: ViewModifier {
    var onClose: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .background(YMUi.screenBg.ignoresSafeArea())
            .overlay(alignment: .topTrailing) {
                if let onClose {
                    Button(action: { Haptics.light(); onClose() }) {
                        Image(systemName: "xmark")
                            .ymIcon(14, weight: .bold)
                            .foregroundStyle(YMUi.text)
                            .frame(width: YMForm.closeButton, height: YMForm.closeButton)
                            .background(YMUi.card, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Закрыть")
                    .padding(.top, 12)
                    .padding(.trailing, YMForm.screenPadding)
                }
            }
            .presentationDragIndicator(.visible)
            .ymSheetCorner()
    }
}

private extension View {
    @ViewBuilder func ymSheetCorner() -> some View {
        if #available(iOS 16.4, *) {
            self.presentationCornerRadius(YMForm.sheetRadius)
        } else {
            self
        }
    }
}

extension View {
    /// Единое оформление системного .sheet. Вешать на содержимое листа.
    func ymSheetChrome(onClose: (() -> Void)? = nil) -> some View {
        modifier(YMSheetChrome(onClose: onClose))
    }

    /// «Лист поверх листа» для собственных оверлеев: фон под ними слегка уходит назад
    /// (scale 0,94 + скругление), 0,3 с; при Reduce Motion — без анимации и без масштаба.
    func ymSheetBehind(_ active: Bool, reduceMotion: Bool) -> some View {
        self
            .scaleEffect(active && !reduceMotion ? 0.94 : 1)
            .clipShape(YMBehindClip(radius: active && !reduceMotion ? YMForm.sheetRadius : 0,
                                    outset: active && !reduceMotion ? 0 : 2000))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: active)
    }
}

/// Клип «лист позади». В обычном состоянии прямоугольник раздвинут на 2000 pt, то есть ничего не обрезает
/// (фоны под safe area и тени целы), а идентичность вью не меняется; при активации сжимается к экрану.
private struct YMBehindClip: Shape {
    var radius: CGFloat
    var outset: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(radius, outset) }
        set { radius = newValue.first; outset = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: rect.insetBy(dx: -outset, dy: -outset))
    }
}
