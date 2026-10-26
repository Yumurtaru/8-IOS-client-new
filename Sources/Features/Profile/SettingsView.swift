//
//  SettingsView.swift — Настройки (premium-клиент)
//
//  Оформление (Система/Светлая/Тёмная), «О приложении» (версия, документы),
//  «Город» (только показ). Токены YM, light+dark, Dynamic Type.
//
//  ТОЧКА ВХОДА (для навигации из ProfileView):
//    SettingsView()   — самодостаточный экран (внутренний ScrollView),
//                       навешивается через .navigationDestination.
//
//  ТЕМА: пишет в @AppStorage(AppStorageKey.theme) == "appearance" — ТОТ ЖЕ ключ,
//  который читает YumurtaApp.colorScheme (значения "system"|"light"|"dark").
//  Контракт API не затрагивается (локальная настройка UI).
//
//  ГОРОД: только показ из Session (cityName) — смена города живёт на главном экране.
//

import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject private var session: Session
    @AppStorage(AppStorageKey.theme) private var theme = "system"
    @Environment(\.scenePhase) private var scenePhase
    /// Разрешение iOS на уведомления (nil — ещё не узнали). Окно разрешения
    /// всплывает при первом запуске, и отказ там раньше был навсегда: в
    /// приложении не было ни признака, ни пути включить статусы заказов.
    @State private var notifStatus: UNAuthorizationStatus?

    private var appVersion: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                appearanceSection
                notificationsSection
                citySection
                aboutSection
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.lg)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshNotifStatus() }
        // Вернулись из настроек iPhone (или закрыли системное окно) — статус обновляем.
        .onChange(of: scenePhase) { phase in
            if phase == .active { refreshNotifStatus() }
        }
    }

    // ── Уведомления (разрешение iOS) ──
    @ViewBuilder
    private var notificationsSection: some View {
        if let st = notifStatus {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Уведомления")
                Text(notifText(st))
                    .font(YMFont.caption)
                    .foregroundStyle(st == .denied ? YMColor.statusCancel : YMColor.muted)
                if st == .denied {
                    Button("Открыть настройки iPhone") { openSystemSettings() }
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(YMColor.accent)
                } else if st == .notDetermined {
                    Button("Включить уведомления") { Push.shared.requestAuthorization() }
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(YMColor.accent)
                }
            }
            .padding(14)
            .settingsCard()
        }
    }

    private func notifText(_ st: UNAuthorizationStatus) -> String {
        switch st {
        case .denied:
            return "Выключены — статус заказа и ответы заведения не придут. Включить можно в настройках iPhone."
        case .notDetermined:
            return "Разрешите уведомления, чтобы сразу узнавать о статусе заказа и ответах заведения."
        default:
            return "Включены — статус заказа и ответы заведения придут сразу."
        }
    }

    private func refreshNotifStatus() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let st = s.authorizationStatus
            DispatchQueue.main.async { notifStatus = st }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // ── Оформление ──
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Оформление")
            YMSegmented(options: SettingsThemeOption.allCases,
                        selection: Binding(
                            get: { SettingsThemeOption(storage: theme) },
                            set: { theme = $0.storage }
                        )) { $0.title }
        }
        .padding(14)
        .settingsCard()
    }

    // ── Город (только показ) ──
    private var citySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Город")
            HStack(spacing: 8) {
                Text("📍")
                Text(session.cityName?.isEmpty == false ? session.cityName! : "Не выбран")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(YMColor.text)
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            Text("Город меняется на главном экране — от него зависят магазины и доставка.")
                .font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        .padding(14)
        .settingsCard()
    }

    // ── О приложении ──
    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("О приложении")
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)

            linkRow(icon: "lock.shield", label: "Политика конфиденциальности",
                    url: "https://yumurta.ru/privacy")
            rowDivider
            linkRow(icon: "doc.text", label: "Условия использования",
                    url: "https://yumurta.ru/terms")
            rowDivider
            HStack {
                Image(systemName: "info.circle")
                    .font(.system(size: 15)).foregroundStyle(YMColor.muted).frame(width: 26)
                Text("Версия").font(.system(size: 14.5, weight: .semibold)).foregroundStyle(YMColor.text)
                Spacer()
                Text(appVersion).font(.system(size: 13.5)).foregroundStyle(YMColor.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
        }
        .settingsCard()
    }

    private func linkRow(icon: String, label: String, url: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 15)).foregroundStyle(YMColor.accent).frame(width: 26)
                Text(label).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(YMColor.text)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(YMColor.muted)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .contentShape(Rectangle())
        }
    }

    private var rowDivider: some View {
        Rectangle().fill(YMColor.hairline).frame(height: 1).padding(.leading, 48)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 13, weight: .heavy)).foregroundStyle(YMColor.text)
    }
}

/// Опция темы ↔ значение @AppStorage(AppStorageKey.theme) ("system"|"light"|"dark").
/// Уникальное имя (в ProfileView живёт private ThemeOption — конфликта нет).
private enum SettingsThemeOption: CaseIterable, Hashable {
    case system, light, dark
    var title: String { self == .system ? "Система" : self == .light ? "Светлая" : "Тёмная" }
    var storage: String { self == .system ? "system" : self == .light ? "light" : "dark" }

    init(storage: String) {
        switch storage {
        case "light": self = .light
        case "dark":  self = .dark
        default:      self = .system
        }
    }
}

/// Карточка-контейнер секции настроек (surface + hairline).
private extension View {
    func settingsCard() -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}
