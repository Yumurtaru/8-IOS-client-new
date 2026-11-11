import UserNotifications

//  Расширение YumurtaNotificationService: подкладывает фото в push.
//  Сервер шлёт aps.mutable-content = 1 и поле "image" (https-ссылка) рядом
//  с обычными ключами (type, order_id...). Нет картинки или ошибка - push
//  показывается как обычно.

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private let lock = NSLock()
    private var delivered = false

    /// Лимит системы на вложение-картинку - 10 МБ.
    private let maxBytes: Int64 = 10 * 1024 * 1024

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = request.content.mutableCopy() as? UNMutableNotificationContent
        bestAttempt = content
        guard let content = content, let url = imageURL(content.userInfo) else {
            deliver(request.content)
            return
        }
        download(url) { [weak self] attachment in
            guard let self = self else { return }
            if let attachment = attachment { content.attachments = [attachment] }
            self.deliver(content)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        if let content = bestAttempt { deliver(content) }
    }

    // MARK: - Внутреннее

    private func deliver(_ content: UNNotificationContent) {
        lock.lock()
        let already = delivered
        delivered = true
        lock.unlock()
        guard !already else { return }
        contentHandler?(content)
    }

    /// https-ссылка из ключа image (или data.image).
    private func imageURL(_ userInfo: [AnyHashable: Any]) -> URL? {
        var raw = userInfo["image"] as? String
        if raw == nil, let data = userInfo["data"] as? [String: Any] { raw = data["image"] as? String }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.count <= 2000,
              let url = URL(string: text), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    private func download(_ url: URL, completion: @escaping (UNNotificationAttachment?) -> Void) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 25
        let session = URLSession(configuration: config)
        let limit = maxBytes
        let task = session.downloadTask(with: url) { location, response, error in
            defer { session.finishTasksAndInvalidate() }
            guard error == nil, let location = location else { completion(nil); return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: location.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0, size <= limit else { completion(nil); return }
            let ext = NotificationService.fileExtension(mime: response?.mimeType, url: url)
            let target = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString + "." + ext)
            do {
                try FileManager.default.moveItem(at: location, to: target)
                completion(try UNNotificationAttachment(identifier: "image", url: target, options: nil))
            } catch {
                completion(nil)
            }
        }
        task.resume()
    }

    private static func fileExtension(mime: String?, url: URL) -> String {
        switch (mime ?? "").lowercased() {
        case "image/png":               return "png"
        case "image/gif":               return "gif"
        case "image/jpeg", "image/jpg": return "jpg"
        default:
            let e = url.pathExtension.lowercased()
            return ["png", "gif", "jpg", "jpeg"].contains(e) ? e : "jpg"
        }
    }
}
