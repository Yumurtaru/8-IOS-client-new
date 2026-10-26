import SwiftUI
import UIKit

// П-52 (волна А101): показ «Вышла новая версия — обновите» (решение — Core/AppUpdate.swift).
// Тексты одинаковые на iOS и Android и во всех приложениях Yumurta.

/// Обязательное обновление: экран поверх всего, без закрытия (окно ForceUpdateWindow).
struct ForceUpdateView: View {
    let info: AppVersionInfo
    @AppStorage(AppStorageKey.theme) private var theme = "system"

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            // Текст короткий — по центру экрана; длинный (крупный шрифт) — прокручивается.
            GeometryReader { geo in
                ScrollView {
                    VStack(spacing: YMSpace.md) {
                        UpdateBadge()
                        Text("Нужно обновить приложение")
                            .font(YMFont.title2)
                            .foregroundStyle(YMColor.text)
                            .multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text(info.message.isEmpty
                             ? "Эта версия больше не поддерживается. Обновите приложение, чтобы продолжить."
                             : info.message)
                            .font(YMFont.callout)
                            .foregroundStyle(YMColor.muted)
                            .multilineTextAlignment(.center)
                        Button(action: { Haptics.light(); AppUpdateStore.openStore(info.storeURL) }) {
                            Text("Обновить")
                        }
                        .buttonStyle(YMPrimaryButtonStyle())
                        .padding(.top, YMSpace.sm)
                        Text("Установлена версия \(AppUpdateStore.currentVersion), нужна \(info.minVersion.isEmpty ? "новая" : info.minVersion) или новее")
                            .font(YMFont.caption)
                            .foregroundStyle(YMColor.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, YMSpace.xxxl)
                    .padding(.vertical, YMSpace.xxl)
                    .frame(maxWidth: .infinity, minHeight: geo.size.height)
                }
            }
        }
        .preferredColorScheme(theme == "light" ? .light : theme == "dark" ? .dark : nil)
    }
}

/// Золотой круг с иконкой обновления — как у диалога корзины.
private struct UpdateBadge: View {
    var body: some View {
        ZStack {
            Circle().fill(YMColor.accent.opacity(0.14)).frame(width: 64, height: 64)
            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(YMColor.accent)
        }
        .accessibilityHidden(true)
    }
}

/// Мягкое окно «Вышла новая версия» (RootTabView). Показывается, только когда можно:
/// «Главная», без шторок, обложек и других окон, после анимации запуска и онбординга.
/// Проверка раз в полторы секунды, пока окно ждёт; закрыли окна — оно появится.
///
/// Окно — наложение (как диалог корзины), а не системный alert: alert, висящий на
/// RootTabView, не дал бы открыть шторку чата/корзины/заведения из push или ссылки.
/// Приложение ушло с переднего плана или открывается окно из push/ссылки
/// (presentationKey изменился) — окно убираем БЕЗ «Позже» и ждём снова.
@MainActor
struct SoftUpdatePrompt: ViewModifier {
    @ObservedObject var store: AppUpdateStore
    /// Можно ли сейчас (вкладка и окна RootTabView).
    let canShow: () -> Bool
    /// Слепок флагов окон NavCoordinator/роутера: изменился — убираем окно.
    let presentationKey: String
    @Environment(\.scenePhase) private var scenePhase
    @State private var shown: AppVersionInfo?
    /// Сколько раз окно убирали без ответа — перезапускает ожидание.
    @State private var attempt = 0

    func body(content: Content) -> some View {
        content
            .task(id: "\(store.soft.map { AppUpdateLogic.snoozeKey($0) } ?? "-")#\(attempt)") { await waitAndShow() }
            .overlay {
                if let info = shown {
                    SoftUpdateCard(info: info,
                                   onUpdate: {
                                       // Человек мог и не обновиться — напомним через сутки.
                                       shown = nil
                                       store.snoozeSoft(info)
                                       AppUpdateStore.openStore(info.storeURL)
                                   },
                                   onLater: {
                                       shown = nil
                                       store.snoozeSoft(info)
                                   })
                        .transition(.opacity)
                        .zIndex(998)
                }
            }
            .onChange(of: scenePhase) { phase in
                if phase != .active { withdraw() }
            }
            .onChange(of: presentationKey) { _ in withdraw() }
            // Версию отложили или обязательное обновление пришло — окно больше не нужно.
            .onChange(of: store.soft) { s in if s == nil { shown = nil } }
            .onChange(of: store.force) { f in if f != nil { withdraw() } }
    }

    /// Убрать окно без ответа (не откладывая версию) и начать ждать заново.
    private func withdraw() {
        guard shown != nil else { return }
        shown = nil
        attempt += 1
    }

    /// Ждём момента, когда окно можно показать (или пока оно не станет не нужно).
    private func waitAndShow() async {
        while !Task.isCancelled, shown == nil, let s = store.soft {
            if store.force == nil, store.splashFinished, canShow(), Self.nothingPresented() {
                shown = s
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    /// Приложение на переднем плане и ни одна шторка/обложка/окно не открыты.
    @MainActor
    static func nothingPresented() -> Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        let root = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .rootViewController
        guard let root = root else { return false }
        return root.presentedViewController == nil
    }
}

/// Карточка мягкого окна: затемнение (тап — «Позже»), заголовок, текст, «Обновить» / «Позже».
private struct SoftUpdateCard: View {
    let info: AppVersionInfo
    let onUpdate: () -> Void
    let onLater: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.black.opacity(0.62))
                .ignoresSafeArea()
                .onTapGesture { onLater() }
                .accessibilityHidden(true)

            VStack(spacing: YMSpace.md) {
                UpdateBadge()
                Text(info.latestVersion.isEmpty ? "Вышла новая версия" : "Вышла новая версия \(info.latestVersion)")
                    .font(YMFont.title3)
                    .foregroundStyle(YMColor.text)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(info.message.isEmpty ? "Обновите приложение, чтобы пользоваться новыми возможностями." : info.message)
                    .font(YMFont.callout)
                    .foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: YMSpace.md) {
                    Button(action: { Haptics.light(); onUpdate() }) { Text("Обновить") }
                        .buttonStyle(YMPrimaryButtonStyle())
                    Button(action: { Haptics.light(); onLater() }) { Text("Позже") }
                        .buttonStyle(YMSecondaryButtonStyle())
                }
                .padding(.top, YMSpace.sm)
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)
            .padding(.bottom, 22)
            .background(YMColor.bg, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isModal)
        }
    }
}
