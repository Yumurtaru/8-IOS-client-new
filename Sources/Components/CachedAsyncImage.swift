import SwiftUI
import UIKit

/// Загрузка картинок вместо системного AsyncImage.
///
/// Почему не AsyncImage. Он качает через URLSession.shared, а там на один сервер
/// не больше 6 соединений, если сервер не говорит по HTTP/2. После переезда
/// сайта картинки встали в очередь: список организаций и товаров — это сотня
/// фото, и фото в открытой карточке товара ждало, пока докачается весь список
/// (жалоба владельца 2026-10-09: «фото появляется через 15 секунд»; в браузере
/// при этом всё сразу — он грузит только видимое).
///
/// Здесь — своя сессия: до 16 соединений на сервер, свой кэш на диске
/// (картинки сервер отдаёт с кэшем на год), кэш готовых картинок в памяти,
/// раскодирование не на главном потоке. Ушла ячейка с экрана — её загрузка
/// отменяется и не занимает очередь.
///
/// Интерфейс тот же, что у AsyncImage(url:content:): замена — одно слово.
struct CachedAsyncImage<Content: View>: View {
    private let url: URL?
    private let content: (AsyncImagePhase) -> Content

    @State private var phase: AsyncImagePhase
    @State private var shownURL: URL?
    @ObservedObject private var net = NetworkMonitor.shared

    init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
        self.url = url
        self.content = content
        // Уже в памяти — показываем сразу, без мигания заглушкой при прокрутке.
        if let url, let img = ImagePipeline.memoryImage(for: url) {
            _phase = State(initialValue: .success(Image(uiImage: img)))
            _shownURL = State(initialValue: url)
        } else {
            _phase = State(initialValue: .empty)
            _shownURL = State(initialValue: nil)
        }
    }

    var body: some View {
        // Пустая фаза у вызывающих часто не рисует ничего; .task на «ничего» не
        // срабатывает, поэтому загрузку держит невидимая точка нулевого размера.
        ZStack {
            content(phase)
            Color.clear
                .frame(width: 0, height: 0)
                // Связь вернулась — несостоявшиеся загрузки повторяются сами:
                // раньше фото, не скачанные без сети, оставались заглушками, пока
                // карточку не прокрутят с экрана и обратно. Скачанные не трогаем
                // (load() выходит сразу при показанной картинке).
                .task(id: ImageLoadKey(url: url, online: net.online)) { await load() }
        }
    }

    @MainActor
    private func load() async {
        guard let url else {
            phase = .empty
            shownURL = nil
            return
        }
        if shownURL == url, case .success = phase { return }
        if let img = ImagePipeline.memoryImage(for: url) {
            phase = .success(Image(uiImage: img))
            shownURL = url
            return
        }
        // Другой адрес (переиспользованная ячейка) — старую картинку не держим.
        if shownURL != url {
            phase = .empty
            shownURL = nil
        }
        do {
            let img = try await ImagePipeline.load(url)
            if Task.isCancelled { return }
            phase = .success(Image(uiImage: img))
            shownURL = url
        } catch {
            // Отмена — ячейка ушла с экрана; это не ошибка, заглушку не ставим.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            phase = .failure(error)
        }
    }
}

/// Ключ загрузки картинки: адрес и наличие сети (см. CachedAsyncImage.body).
private struct ImageLoadKey: Hashable {
    let url: URL?
    let online: Bool
}

/// Сессия, кэши и раскодирование картинок — общие для всего приложения.
enum ImagePipeline {
    private static let memory: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 400
        c.totalCostLimit = 96 * 1024 * 1024   // байты раскодированных картинок
        return c
    }()

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // Главное: без HTTP/2 по умолчанию 6 соединений — отсюда была очередь.
        cfg.httpMaximumConnectionsPerHost = 16
        cfg.requestCachePolicy = .useProtocolCachePolicy
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("yumurta-images", isDirectory: true)
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                diskCapacity: 300 * 1024 * 1024,
                                directory: dir)
        return URLSession(configuration: cfg)
    }()

    static func memoryImage(for url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async throws -> UIImage {
        if let img = memoryImage(for: url) { return img }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        guard let raw = UIImage(data: data) else { throw URLError(.cannotDecodeContentData) }
        // Раскодировать заранее, не на главном потоке — иначе подтормаживает прокрутка.
        // Большой снимок (4000×3000 в отзыве или объявлении) раскрывался целиком —
        // около 48 МБ на одну картинку, и несколько таких фото подряд выбивали
        // приложение по памяти. Экрану телефона хватает 2000 точек по большей стороне.
        let maxPixel: CGFloat = 2000
        let longest = max(raw.size.width * raw.scale, raw.size.height * raw.scale)
        var prepared: UIImage?
        if longest > maxPixel, longest > 0 {
            let k = maxPixel / longest
            let target = CGSize(width: (raw.size.width * k).rounded(), height: (raw.size.height * k).rounded())
            prepared = await raw.byPreparingThumbnail(ofSize: target)
        }
        if prepared == nil { prepared = await raw.byPreparingForDisplay() }
        let img = prepared ?? raw
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        memory.setObject(img, forKey: url as NSURL, cost: cost)
        return img
    }
}
