import Foundation
#if canImport(AppMetricaCore)
import AppMetricaCore
#endif
#if canImport(AppMetricaCrashes)
import AppMetricaCrashes
#endif

/// Тонкая обёртка над AppMetrica (отчёты о падениях и события).
/// Ключ приложения лежит в Info.plist (AppMetricaAPIKey, значение задаётся в project.yml).
/// Ключ пустой — SDK не запускается вообще, события никуда не уходят.
enum Metrica {
    /// Ключ из Info.plist; пустая строка — отключено.
    static var apiKey: String {
        let raw = Bundle.main.object(forInfoDictionaryKey: "AppMetricaAPIKey") as? String ?? ""
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Незаполненная подстановка вида $(ИМЯ) тоже считается «пусто».
        return key.hasPrefix("$(") ? "" : key
    }

    private static var started = false

    /// Запущена ли AppMetrica (есть ключ и SDK подключён).
    static var isActive: Bool { started }

    /// Запуск при старте приложения. Без ключа ничего не делает.
    static func activate() {
        #if canImport(AppMetricaCore)
        #if DEBUG
        // Отладочные сборки не шлют данные: тестовые запуски не смешиваются со статистикой (как Android BuildConfig.DEBUG).
        return
        #else
        guard !started, !apiKey.isEmpty else { return }
        guard let configuration = AppMetricaConfiguration(apiKey: apiKey) else { return }
        AppMetrica.activate(with: configuration)
        #if canImport(AppMetricaCrashes)
        // Отчёты о падениях включаются самим подключением модуля AppMetricaCrashes.
        _ = AppMetricaCrashes.crashes()
        #endif
        started = true
        #endif // DEBUG
        #endif // canImport(AppMetricaCore)
    }

    /// Событие воронки. Параметры — только строки и числа, без телефонов и денег.
    static func report(_ name: String, _ params: [String: Any] = [:]) {
        #if canImport(AppMetricaCore)
        guard started else { return }
        var wire: [AnyHashable: Any] = [:]
        for (key, value) in params { wire[key] = value }
        AppMetrica.reportEvent(name: name, parameters: wire.isEmpty ? nil : wire, onFailure: nil)
        #endif
    }
}
