import SwiftUI

/// Дизайнерская заглушка фото: градиентный прямоугольник с монопометкой «ФОТО»/«ОБЛОЖКА».
/// Реальные изображения приходят из API (см. API.imageURL). Если url есть — грузим через
/// AsyncImage поверх плейсхолдера; placeholder виден во время загрузки и при ошибке.
struct PhotoPlaceholder: View {
    var url: URL? = nil
    var label: String = "ФОТО"
    var radius: CGFloat = YMRadius.card
    /// Индекс для детерминированного выбора тона градиента (карусель выглядит разнообразно).
    var tone: Int = 0

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            gradient
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.white.opacity(0.45))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(10)
        }
        .overlay {
            if let url {
                CachedAsyncImage(url: url) { phase in
                    if case let .success(image) = phase {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // КРИТИЧНО. Картинка внутри — .scaledToFill(), то есть её РЕАЛЬНЫЙ размер
        // заметно больше рамки: квадратное фото товара в полосе 120pt по высоте
        // вылезает больше чем на сотню точек вверх и вниз. clipShape и clipped()
        // обрезают только РИСОВАНИЕ — область нажатия остаётся по полному размеру
        // картинки. Из-за этого карточка «ловила» тапы далеко за своими границами:
        // нажатие на сегмент «Организации» над списком попадало в первую карточку
        // товара и открывало её вместо переключения вкладки.
        // contentShape задаёт область нажатия ровно по видимому прямоугольнику.
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    // Палитры — один раз на приложение: раньше 16 цветов разбирались из hex
    // (Scanner на каждый) при КАЖДОЙ перерисовке каждой карточки со фото —
    // в длинных списках это заметная доля работы на главном потоке.
    private static let darkTones: [[Color]] = [
        [Color(hex: "#33302B"), Color(hex: "#2E322E")],
        [Color(hex: "#3A342A"), Color(hex: "#342E30")],
        [Color(hex: "#2E322E"), Color(hex: "#302F36")],
        [Color(hex: "#342E30"), Color(hex: "#33302B")]
    ]
    private static let lightTones: [[Color]] = [
        [Color(hex: "#EBE3D2"), Color(hex: "#E4E8DE")],
        [Color(hex: "#E9DFC9"), Color(hex: "#EFE6DC")],
        [Color(hex: "#E4E8DE"), Color(hex: "#E6E7EE")],
        [Color(hex: "#EFE6DC"), Color(hex: "#EBE3D2")]
    ]

    private var gradient: LinearGradient {
        let pool = scheme == .dark ? Self.darkTones : Self.lightTones
        // abs: отрицательный tone (id-заглушка) давал индекс < 0 — вылет.
        let pair = pool[abs(tone % pool.count)]
        return LinearGradient(colors: pair, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
