//
//  PdConsent.swift
//  Yumurta — маркетплейс (iOS, SwiftUI)
//
//  152-ФЗ (ст. 9 в ред. 156-ФЗ, с 01.09.2025): согласие на обработку персональных данных — ОТДЕЛЬНЫЙ документ
//  (https://yumurta.ru/consent), политика — https://yumurta.ru/privacy. Галочка на входе/регистрации по умолчанию
//  не отмечена. Серверного поля pd_consent пока нет — на сервер ничего не шлём, факт и время хранятся на
//  устройстве (UserDefaults, ключ pd_consent_at, ISO-8601). Те же тексты — Android PdConsent.kt и приложения курьера.
//

import SwiftUI

enum PdConsent {
    static let text = "Даю согласие на обработку персональных данных"
    static let linkWord = "согласие"
    static let error = "Отметьте согласие на обработку персональных данных"
    static let privacyTitle = "Политика конфиденциальности"
    static let consentTitle = "Согласие на обработку персональных данных"
    static let consentURL = "https://yumurta.ru/consent"
    static let privacyURL = "https://yumurta.ru/privacy"
    static let keyAt = "pd_consent_at"

    /// Без галочки продолжать нельзя.
    static func allowed(_ checked: Bool) -> Bool { checked }

    /// Текст с markdown-ссылкой на слове «согласие».
    static var markdown: String {
        text.replacingOccurrences(of: linkWord, with: "[\(linkWord)](\(consentURL))")
    }

    /// Запомнить факт и время согласия на устройстве (на сервер не шлём).
    static func remember() {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        UserDefaults.standard.set(f.string(from: Date()), forKey: keyAt)
    }
}

/// Отдельная галочка согласия + строка «Политика конфиденциальности» (ознакомление, не галочка).
struct PdConsentRow: View {
    @Binding var checked: Bool
    /// Подсветить «Отметьте согласие…» (нажали кнопку без галочки).
    var showError: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Button {
                    Haptics.light()
                    checked.toggle()
                } label: {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .ymFont(22)
                        .foregroundStyle(checked ? YMColor.accent : (showError ? YMColor.statusCancel : YMColor.muted))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(PdConsent.consentTitle)
                .accessibilityValue(checked ? "отмечено" : "не отмечено")
                .accessibilityAddTraits(.isButton)

                // Слово «согласие» — ссылка на /consent (внешний браузер); для VoiceOver — через ротор «Ссылки».
                Text(.init(PdConsent.markdown))
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.text)
                    .tint(YMColor.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityHint("Двойное нажатие на ссылку откроет текст согласия")
            }
            if showError && !checked {
                Text(PdConsent.error)
                    .font(YMFont.caption)
                    .foregroundStyle(YMColor.statusCancel)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            if let u = URL(string: PdConsent.privacyURL) {
                Link(destination: u) {
                    Text(PdConsent.privacyTitle)
                        .font(YMFont.subhead.weight(.semibold))
                        .foregroundStyle(YMColor.accent)
                        .frame(minHeight: 44, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
