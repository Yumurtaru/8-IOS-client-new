import SwiftUI

//
//  CartConflictDialog.swift — модалка конфликта корзины. Дизайн 1:1 с DialogPhone.dc.html.
//
//  Триггер: пользователь добавляет товар из ДРУГОГО магазина, когда корзина уже занята
//  (инвариант single-store: одна корзина = один магазин, см. Core/Cart.add — оно само
//  очищает корзину при смене shopId). Диалог даёт явное подтверждение перед очисткой.
//
//  ПОДКЛЮЧЕНИЕ (централизованно, из карточек товара / экрана Org):
//    .cartConflictDialog(isPresented: $showConflict,
//                        currentShop: cart.shopName, newShop: pendingShopName,
//                        onConfirm: { /* очистить и добавить товар из нового магазина */ })
//
//  onConfirm вызывается по «Очистить и начать новую». «Оставить текущую» просто закрывает.
//  Токены — YM*. Reduce Motion уважается (pop только при выключенном).
//

// MARK: - View диалога

struct CartConflictDialog: View {
    /// Текущий магазин в корзине (для текста).
    var currentShop: String?
    /// Магазин, товар из которого пытаются добавить.
    var newShop: String?
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    /// Выбор уже сделан. Действие выполняется через 0,18 с (после анимации), и
    /// второе нажатие «Очистить и начать новую» в это время добавляло товар
    /// в корзину дважды (или «Очистить» + «Оставить» срабатывали оба).
    @State private var decided = false

    private var currentName: String { (currentShop?.isEmpty == false) ? currentShop! : "текущего заведения" }
    private var newName: String { (newShop?.isEmpty == false) ? newShop! : "другого заведения" }

    var body: some View {
        ZStack {
            // Затемнение + лёгкий blur (тап по фону = «Оставить текущую»).
            Rectangle()
                .fill(.black.opacity(0.62))
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .opacity(appeared ? 1 : 0)
                .onTapGesture { dismiss(confirm: false) }

            // Редизайн: белая карточка снизу, отступ 12 от краёв, скругление 38.
            VStack {
                Spacer()
                card
                    .offset(y: appeared || reduceMotion ? 0 : 40)
                    .opacity(appeared ? 1 : 0)
                    .padding(12)
            }
        }
        .onAppear {
            if reduceMotion { appeared = true }
            else { withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { appeared = true } }
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: { Haptics.light(); dismiss(confirm: false) }) {
                    Image(systemName: "xmark")
                        .ymIcon(14, weight: .bold)
                        .foregroundStyle(YMUi.text)
                        .frame(width: YMForm.closeButton, height: YMForm.closeButton)
                        .background(YMUi.screenBg, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Закрыть")
            }
            // Иконка 🛒 на мягкой золотой подложке.
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(YMColor.accent.opacity(0.14))
                    .frame(width: 64, height: 64)
                Text("🛒").ymFont(30)
            }

            Text("Начать новую корзину?")
                .ymFont(21, weight: .heavy)
                .foregroundStyle(YMColor.text)
                .multilineTextAlignment(.center)
                .padding(.top, YMSpace.lg)

            // «товары», а не «блюда»: диалог общий для кафе, магазинов и аптек.
            (Text("В корзине уже есть товары из ")
                + Text(currentName).font(YMFont.golos(14, .bold, relativeTo: .body)).foregroundColor(YMColor.text)
                + Text(". Заказ можно оформить только из одного заведения. Очистить корзину и добавить товар из ")
                + Text(newName).font(YMFont.golos(14, .bold, relativeTo: .body)).foregroundColor(YMColor.text)
                + Text("?"))
                .ymFont(14)
                .foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, YMSpace.sm)

            HStack(spacing: YMSpace.md) {
                Button(action: { Haptics.light(); dismiss(confirm: false) }) {
                    Text("Оставить текущую").lineLimit(2).minimumScaleFactor(0.8)
                }
                .buttonStyle(YMSecondaryButtonStyle())

                Button(action: { Haptics.warning(); dismiss(confirm: true) }) {
                    Text("Очистить и начать новую").lineLimit(2).minimumScaleFactor(0.8)
                }
                .buttonStyle(YMPrimaryButtonStyle())
            }
            .padding(.top, YMSpace.xl)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
        .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.sheetRadius, style: .continuous))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
    }

    private func dismiss(confirm: Bool) {
        guard !decided else { return }
        decided = true
        let action = { confirm ? onConfirm() : onCancel() }
        if reduceMotion {
            appeared = false; action()
        } else {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { appeared = false }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { action() }
        }
    }
}

// MARK: - ViewModifier + удобный API

private struct CartConflictModifier: ViewModifier {
    @Binding var isPresented: Bool
    var currentShop: String?
    var newShop: String?
    var onConfirm: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .ymSheetBehind(isPresented, reduceMotion: reduceMotion)
            .overlay {
            if isPresented {
                CartConflictDialog(
                    currentShop: currentShop,
                    newShop: newShop,
                    onConfirm: { isPresented = false; onConfirm() },
                    onCancel: { isPresented = false }
                )
                .transition(.opacity)
                .zIndex(999)
            }
        }
    }
}

extension View {
    /// Централизованное подключение диалога конфликта корзины.
    /// isPresented снимается автоматически по любой кнопке / тапу по фону.
    func cartConflictDialog(
        isPresented: Binding<Bool>,
        currentShop: String? = nil,
        newShop: String? = nil,
        onConfirm: @escaping () -> Void
    ) -> some View {
        modifier(CartConflictModifier(
            isPresented: isPresented,
            currentShop: currentShop,
            newShop: newShop,
            onConfirm: onConfirm
        ))
    }
}
