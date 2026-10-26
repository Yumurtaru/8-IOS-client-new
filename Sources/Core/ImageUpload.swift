import UIKit
import ImageIO

/// Подготовка фото к отправке на сервер.
///
/// `PhotosPickerItem.loadTransferable(type: Data.self)` отдаёт исходные байты
/// снимка, а камера iPhone по умолчанию снимает в HEIC. Сервер принимает только
/// JPEG/PNG/WebP/GIF (core/Image.php), поэтому большинство фото с камеры
/// отклонялось с «Недопустимый формат изображения». Перекодируем в JPEG и
/// заодно уменьшаем до 2048 px по большей стороне — быстрее грузится по сети.
enum ImageUpload {
    static func jpeg(from data: Data, maxSide: CGFloat = 2048, quality: CGFloat = 0.85) -> Data? {
        if let out = downsampledJPEG(data, maxSide: maxSide, quality: quality) { return out }
        // Запасной путь (ImageIO не справился) — прежняя перерисовка через UIKit.
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let longest = max(size.width, size.height)
        var target = image
        if longest > maxSide, longest > 0 {
            let scale = maxSide / longest
            let newSize = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
            target = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        }
        return target.jpegData(compressionQuality: quality)
    }

    /// Уменьшение средствами ImageIO: картинка декодируется сразу в нужном
    /// размере. Прежний путь через UIImage сначала раскрывал снимок целиком
    /// (48 Мп ≈ 190 МБ в памяти) — на старых iPhone при нескольких фото
    /// объявления система закрывала приложение. Заодно поворот из EXIF
    /// «впекается» в пиксели всегда, а не только при уменьшении: сервер
    /// метаданные не читает, и небольшие повёрнутые фото уходили боком.
    private static func downsampledJPEG(_ data: Data, maxSide: CGFloat, quality: CGFloat) -> Data? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxSide),
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return flattened(cg).jpegData(compressionQuality: quality)
    }

    /// Прозрачный PNG в JPEG без подложки выходил на чёрном фоне — кладём на белый.
    private static func flattened(_ cg: CGImage) -> UIImage {
        let img = UIImage(cgImage: cg)
        switch cg.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return img
        default: break
        }
        let size = CGSize(width: cg.width, height: cg.height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
