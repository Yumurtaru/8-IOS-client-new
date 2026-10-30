import Foundation

/// Волна А105: сведения об установке для статистики «у кого какое приложение и версия»
/// (сайт: core/AppInstalls.php). Уходят необязательными полями в POST push/register
/// (app_version, app_build, device_id, device_model, os_version — PushBody) и параметрами
/// GET app-version (version, build, device_id, device_model, os_version — AppUpdateStore).
/// Старый сервер лишнее игнорирует; чего не получить — не шлём.
///
/// device_id — UUID, созданный один раз и хранимый файлом Application Support/client_device_id
/// с пометкой «не в резервную копию» (isExcludedFromBackup), как номер установки у курьера
/// (DeviceId): не в UserDefaults (они уходят в копию iCloud / «Быстрое начало» — два телефона
/// с одним id) и не IDFA / identifierForVendor. Ограничения — как на сервере (AppInstalls::fields):
/// device_id до 64 знаков [0-9A-Za-z_-:.], device_model до 80, os_version до 40, версия до 20.
///
/// До первой разблокировки телефона (запуск в фоне тихим push / prewarm) файл закрыт: новый id
/// НЕ создаём — вернём nil, поле не уйдёт. Вызывающие ещё и сами проверяют
/// isProtectedDataAvailable (AppUpdateStore.onForeground, Push.registerIfPossible).
enum InstallInfo {
    /// Ключ UserDefaults первой версии этой правки (не выпускалась) — удаляем при чтении.
    private static let legacyKey = "installDeviceId"
    static let fileName = "client_device_id"
    private static let lock = NSLock()
    private static var cached: String?

    static var fileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent(fileName)
    }

    /// Стабильный id установки (UUID, 36 знаков) или nil (данные закрыты / записать не вышло).
    static var deviceId: String? { loadDeviceId(protectedDataAvailable: true) }

    /// protectedDataAvailable == false — только прочитать, новый не создавать.
    static func loadDeviceId(protectedDataAvailable: Bool, file: URL? = InstallInfo.fileURL,
                             defaults: UserDefaults = .standard) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let v = cached { return v }
        guard let f = file else { return nil }
        var unreadable = false
        do {
            let d = try Data(contentsOf: f)
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidId(s) { cached = s; defaults.removeObject(forKey: legacyKey); return s }
            // Мусор в файле — перезапишем новым id ниже.
        } catch {
            // Файл есть, но не читается (закрыт до первой разблокировки) — не перезаписываем.
            unreadable = FileManager.default.fileExists(atPath: f.path)
        }
        guard protectedDataAvailable, !unreadable else { return nil }
        let id = UUID().uuidString.lowercased()
        // Записать не вышло — поле не шлём (иначе каждый запуск — новый id).
        guard save(id, to: f) else { return nil }
        defaults.removeObject(forKey: legacyKey)
        cached = id
        return id
    }

    /// А108: аккаунт удалён — сервер стёр строки установок человека, и прежний id
    /// больше не присылаем (иначе следующий запуск без входа завёл бы строку с тем
    /// же id, моделью и ОС). Новый UUID — сразу в файл; записать не вышло — файл
    /// удаляем, и новый id создаст следующее чтение. Звать только после успешного
    /// DELETE /api/v1/account.
    @discardableResult
    static func renewDeviceId(file: URL? = InstallInfo.fileURL) -> String? {
        lock.lock(); defer { lock.unlock() }
        cached = nil
        guard let f = file else { return nil }
        let id = UUID().uuidString.lowercased()
        if save(id, to: f) { cached = id; return id }
        try? FileManager.default.removeItem(at: f)
        return nil
    }

    /// Записать id в файл и пометить «не в резервную копию». true — записано.
    private static func save(_ id: String, to file: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(id.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { return false }
        #if os(iOS) || os(macOS)
        var u = file
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
        #endif
        return true
    }

    static func isValidId(_ s: String) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        return s.unicodeScalars.allSatisfy { c in
            ("0"..."9").contains(c) || ("a"..."z").contains(c) || ("A"..."Z").contains(c)
                || c == "_" || c == "-" || c == ":" || c == "."
        }
    }

    /// Идентификатор модели («iPhone16,2») из utsname.machine; в симуляторе — модель,
    /// которую он изображает. Человеко-читаемое имя не выдумываем. До 80 знаков.
    static var deviceModel: String? {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !sim.isEmpty {
            return String(sim.prefix(80))
        }
        var u = utsname()
        guard uname(&u) == 0 else { return nil }
        // Размер — заранее: внутри withUnsafePointer(to: &u.machine) читать u нельзя (эксклюзивный доступ).
        let size = MemoryLayout.size(ofValue: u.machine)
        let machine = withUnsafePointer(to: &u.machine) { p in
            p.withMemoryRebound(to: CChar.self, capacity: size) { String(cString: $0) }
        }
        let s = machine.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(80))
    }

    /// «iOS 18.1» (patch — только если не ноль: «iOS 17.4.1»). До 40 знаков.
    static var osVersion: String? {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        guard v.majorVersion > 0 else { return nil }
        var s = "iOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { s += ".\(v.patchVersion)" }
        return String(s.prefix(40))
    }

    /// CFBundleShortVersionString («1.3»), до 20 знаков.
    static var appVersion: String? {
        let s = ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : String(s.prefix(20))
    }

    /// CFBundleVersion числом; не число — nil.
    static var appBuild: Int? {
        let s = ((Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let b = Int(s), b > 0 else { return nil }
        return b
    }

    /// Параметры GET api/v1/app-version (кроме app и platform).
    static var versionQuery: [String: String] {
        var q: [String: String] = [:]
        if let v = appVersion { q["version"] = v }
        if let b = appBuild { q["build"] = String(b) }
        if let d = deviceId { q["device_id"] = d }
        if let m = deviceModel { q["device_model"] = m }
        if let o = osVersion { q["os_version"] = o }
        return q
    }
}
