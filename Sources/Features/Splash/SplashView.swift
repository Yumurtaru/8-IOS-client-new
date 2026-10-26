import SwiftUI
import UIKit

// ============================================================================
//  Анимация запуска: «жидкий желток пишет логотип».
// ----------------------------------------------------------------------------
//  Скорлупа трескается, шесть осколков разлетаются, желток падает, разбивается
//  о невидимый пол и ~400 капель стекаются в буквы Yumurta. Поверх жидких букв
//  проявляется чёткая типографика, жидкость стекает, фон переходит в фон
//  приложения.
//
//  Физика перенесена 1:1 из макета (variant h): тот же сеяный LCG, те же
//  коэффициенты гравитации, отскока и пружин. Kotlin-версия в Android-клиенте
//  считает ровно те же числа — анимация на обеих платформах одна и та же.
//
//  Жидкость — настоящие метаболы: каждая капля кладёт гауссово пятно, пятна
//  складываются (.plusLighter), слой режется порогом по альфе. Где капли
//  рядом — сливаются в жидкую форму, одиночная капля порога не достигает.
//
//  Композиция считается в фиксированном холсте 320x660 и масштабируется под
//  экран: на любом устройстве одна картинка и одно число капель.
// ============================================================================

/// Рубильник. false — приложение стартует сразу, как до анимации.
let splashEnabled = true

// Цвет текста задаётся через Text.foregroundColor, а не foregroundStyle:
// вариант foregroundStyle, возвращающий Text (он нужен для GraphicsContext.resolve),
// появился только в iOS 17, а цель сборки — iOS 16.0.
private let wordmarkText = "Yumurta"
private let taglineText = "МАРКЕТПЛЕЙС ТВОЕГО ГОРОДА"

private enum Tune {
    /// Виртуальный холст: вся геометрия ниже — в этих единицах.
    static let vw: CGFloat = 320
    static let vh: CGFloat = 660
    /// Сколько идёт анимация, мс. Единственная ручка скорости: сцена внутри
    /// живёт в собственном времени длиной `sceneMs`, а сюда просто растягивается.
    static let duration: Double = 5400
    /// Длительность сцены в её собственном времени — под неё считана вся физика.
    static let sceneMs: Double = 3400
    /// Во столько раз реальное время медленнее сценического.
    static var timeScale: Double { duration / sceneMs }
    /// Опорный кадр 60 Гц: к нему приводятся покадровые затухания.
    static let frameMs: Double = 1000.0 / 60.0

    // Жидкость
    static let sigma: CGFloat = 2.4        // ширина гауссова пятна одной капли
    static let blobSupport: CGFloat = 3.2  // радиус пятна = sigma * blobSupport
    static let threshold: Double = 0.6     // порог по альфе (как 16a - 9.6 на Android)
    static let sampleStep = 3              // шаг выборки пикселей логотипа
    static let logoPad: CGFloat = 36       // отступ слова от краёв холста
}

// MARK: - Кривые

private struct Bezier {
    private let ax, bx, cx, ay, by, cy: Double
    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1; bx = 3 * (x2 - x1) - cx; ax = 1 - cx - bx
        cy = 3 * y1; by = 3 * (y2 - y1) - cy; ay = 1 - cy - by
    }
    func callAsFunction(_ x: Double) -> Double {
        var t = x
        for _ in 0..<6 {
            let err = ((ax * t + bx) * t + cx) * t - x
            if abs(err) < 1e-6 { break }
            let d = (3 * ax * t + 2 * bx) * t + cx
            if abs(d) < 1e-6 { break }
            t -= err / d
        }
        t = min(1, max(0, t))
        return ((ay * t + by) * t + cy) * t
    }
}

private let easeInOut = Bezier(0.42, 0, 0.58, 1)
private let land = Bezier(0.62, 0, 0.2, 1)
private let fly = Bezier(0.15, 0.85, 0.25, 1)

private func lerp(_ a: Double, _ b: Double, _ k: Double) -> Double { a + (b - a) * k }

/// Отрезок таймлайна: 0 до `from`, 1 после `to`, между — по кривой.
private func seg(_ p: Double, _ from: Double, _ to: Double, _ curve: Bezier? = nil) -> Double {
    if p <= from { return 0 }
    if p >= to { return 1 }
    let k = (p - from) / (to - from)
    return curve?(k) ?? k
}

// MARK: - Симуляция

/// Тот же LCG, что в макете и в Android-клиенте: одинаковая анимация при каждом запуске.
private final class SeededRandom {
    private var seed: UInt64 = 20_260_916
    func next() -> Double {
        seed = (seed &* 1_664_525 &+ 1_013_904_223) & 0xFFFF_FFFF
        return Double(seed) / 4_294_967_296.0
    }
}

/// Одна капля желтка. Координаты — в виртуальном холсте.
private final class Droplet {
    var x, y, vx, vy, r: Double
    let splashR, tx, ty, releaseAt, drainAt, s: Double
    var kicked = false
    init(x: Double, y: Double, r: Double, splashR: Double, tx: Double, ty: Double,
         releaseAt: Double, drainAt: Double, s: Double) {
        self.x = x; self.y = y; self.vx = 0; self.vy = 0; self.r = r
        self.splashR = splashR; self.tx = tx; self.ty = ty
        self.releaseAt = releaseAt; self.drainAt = drainAt; self.s = s
    }
}

private final class YolkFluid {
    /// До этого момента желток падает и разбивается, после — стекается в буквы.
    private static let splashEnd: Double = 1000
    private static let spring: Double = 0.00024
    private static let damping: Double = 0.885
    private static let settledR: Double = 3.2
    private static let scatter: Double = 11
    private static let floorY = Double(Tune.vh) * 0.56

    let droplets: [Droplet]

    init(targets: [CGPoint]) {
        let rnd = SeededRandom()
        let w = Double(Tune.vw), h = Double(Tune.vh)
        droplets = targets.map { p in
            let a = rnd.next() * 6.2832
            let rad = rnd.next() * YolkFluid.scatter
            return Droplet(
                x: w / 2 + cos(a) * rad * 0.7,
                y: h * 0.40 + sin(a) * rad,
                r: 2.6 + rnd.next() * 1.8,
                splashR: 5.4 + rnd.next() * 3.2,
                tx: Double(p.x),
                ty: h * 0.44 + Double(p.y),
                releaseAt: 470 + rnd.next() * 110,
                drainAt: 2420 + (Double(p.x) / w) * 280 + rnd.next() * 90,
                s: rnd.next()
            )
        }
    }

    /// Шаг симуляции. `t` и `dt` — в СЦЕНИЧЕСКОМ времени, не в реальном.
    ///
    /// Коэффициенты вида «умножить на 0.885 за кадр» переведены в «за dt»:
    /// иначе на экране 120 Гц сцена считалась бы вдвое чаще и выглядела бы
    /// иначе, чем на 60 Гц, а растянуть время было бы нельзя вовсе.
    func step(t: Double, dt: Double) {
        let w = Double(Tune.vw)
        let frames = dt / Tune.frameMs
        let damp = pow(YolkFluid.damping, frames)
        func approach(_ rate: Double) -> Double { 1 - pow(1 - rate, frames) }
        for p in droplets {
            if t < p.releaseAt {
                // Дрожит внутри целого яйца.
                p.x += sin(t * 0.006 + p.s * 6.3) * 0.07 * frames
                p.y += cos(t * 0.005 + p.s * 6.3) * 0.06 * frames
                p.r += (3.4 - p.r) * approach(0.04)
            } else if t < YolkFluid.splashEnd {
                // Падает и разбивается о невидимый пол.
                if !p.kicked {
                    p.kicked = true
                    let a = -1.5708 + (p.s - 0.5) * 2.4
                    p.vx = cos(a) * (0.05 + p.s * 0.14)
                    p.vy = -0.03 + p.s * 0.07
                }
                p.vy += 0.0019 * dt
                p.x += p.vx * dt
                p.y += p.vy * dt
                if p.y > YolkFluid.floorY {
                    p.y = YolkFluid.floorY - (p.y - YolkFluid.floorY) * 0.28
                    p.vy = -p.vy * 0.34
                    p.vx = p.vx * 0.9 + (p.x - w / 2) * 0.0016 + (p.s - 0.5) * 0.06
                }
                p.r += (p.splashR - p.r) * approach(0.06)
            } else if t < p.drainAt {
                // Стекается в свою точку логотипа.
                let k = YolkFluid.spring * dt
                p.vx += (p.tx - p.x) * k
                p.vy += (p.ty - p.y) * k
                p.vx *= damp
                p.vy *= damp
                p.x += p.vx * dt
                p.y += p.vy * dt
                p.r += (YolkFluid.settledR - p.r) * approach(0.05)
            } else {
                // Стекает вниз.
                p.vy += 0.0027 * dt
                p.vx *= pow(0.94, frames)
                p.x += p.vx * dt
                p.y += p.vy * dt
                p.r *= pow(0.996, frames)
            }
        }
    }
}

// MARK: - Выборка точек логотипа

/// Рисует слово во вспомогательный буфер и вытаскивает точки, куда должны
/// стечься капли: жидкие буквы гарантированно совпадают с тем шрифтом, которым
/// потом рисуется чёткий логотип.
private func sampleWordmark() -> (points: [CGPoint], fontSize: CGFloat) {
    func attributes(_ size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: UIFont.systemFont(ofSize: size, weight: .heavy),
            .kern: -0.02 * size,
            .foregroundColor: UIColor.white,
        ]
    }

    let probe = max((wordmarkText as NSString).size(withAttributes: attributes(50)).width, 1)
    let fontSize = max(26, (50 * min(1, (Tune.vw - Tune.logoPad) / probe)).rounded())

    let w = Int(Tune.vw.rounded())
    let h = max(1, Int((fontSize * 2).rounded()))
    var buffer = [UInt8](repeating: 0, count: w * h)

    buffer.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress,
              let cg = CGContext(data: base, width: w, height: h,
                                 bitsPerComponent: 8, bytesPerRow: w,
                                 space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return }
        cg.setFillColor(UIColor.black.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext считает y снизу, UIKit — сверху: переворачиваем, чтобы
        // NSAttributedString.draw рисовал как обычно.
        cg.translateBy(x: 0, y: CGFloat(h))
        cg.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(cg)
        let string = NSAttributedString(string: wordmarkText, attributes: attributes(fontSize))
        let bounds = string.size()
        string.draw(at: CGPoint(x: (CGFloat(w) - bounds.width) / 2,
                                y: (CGFloat(h) - bounds.height) / 2))
        UIGraphicsPopContext()
    }

    var points: [CGPoint] = []
    points.reserveCapacity(512)
    var y = 0
    while y < h {
        var x = 0
        while x < w {
            if buffer[y * w + x] > 140 {
                points.append(CGPoint(x: CGFloat(x), y: CGFloat(y) - CGFloat(h) / 2))
            }
            x += Tune.sampleStep
        }
        y += Tune.sampleStep
    }
    return (points, fontSize)
}

/// Гауссово пятно одной капли. Готовится один раз на масштаб экрана:
/// 400 отрисовок картинки за кадр дешевле, чем 400 градиентных заливок.
private func makeBlob(radius: Int, sigma: CGFloat) -> CGImage? {
    let d = radius * 2
    var bytes = [UInt8](repeating: 0, count: d * d * 4)
    for y in 0..<d {
        for x in 0..<d {
            let dx = CGFloat(x) - CGFloat(radius) + 0.5
            let dy = CGFloat(y) - CGFloat(radius) + 0.5
            let a = exp(-(dx * dx + dy * dy) / (2 * sigma * sigma))
            let v = UInt8(max(0, min(255, (a * 255).rounded())))
            let i = (y * d + x) * 4
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v; bytes[i + 3] = v
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(width: d, height: d, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: d * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true,
                   intent: .defaultIntent)
}

// MARK: - Осколки скорлупы

private struct Shard {
    let left, top, right, bottom: CGFloat
    let flyX, flyY, spin: CGFloat
}

/// Овал режется на шесть частей; доли — из макета.
private let shards: [Shard] = [
    Shard(left: 0, top: 0, right: 0.5, bottom: 0.42, flyX: -94, flyY: -142, spin: -158),
    Shard(left: 0.5, top: 0, right: 1, bottom: 0.44, flyX: 98, flyY: -126, spin: 146),
    Shard(left: 0, top: 0.42, right: 0.5, bottom: 0.72, flyX: -122, flyY: -26, spin: -124),
    Shard(left: 0.5, top: 0.44, right: 1, bottom: 0.74, flyX: 124, flyY: -10, spin: 132),
    Shard(left: 0, top: 0.72, right: 0.5, bottom: 1, flyX: -86, flyY: 116, spin: 114),
    Shard(left: 0.5, top: 0.74, right: 1, bottom: 1, flyX: 92, flyY: 128, spin: -146),
]

private let shellLight = Color(hex: "#FFFFFF")
private let shellMid = Color(hex: "#F1E7D4")
private let shellDeep = Color(hex: "#D8CAB2")

// MARK: - Тактильные удары

/// Сцена отдаётся в руку: трещина, взрыв скорлупы, удар желтка о пол, сбор
/// капель в буквы, проявление логотипа и «готово» в конце. Генераторы
/// создаются здесь же, внутри main-actor задачи вьюхи, и заранее прогреваются —
/// иначе первый толчок приходит с заметным опозданием.
private enum SplashHaptics {
    enum Kind {
        case soft(Double), light(Double), medium(Double), heavy, success
    }

    /// Доли таймлайна, на которых бьём. Совпадают с ключевыми кадрами сцены.
    private static let beats: [(at: Double, kind: Kind)] = [
        (0.045, .soft(0.45)),    // по скорлупе пошла трещина
        (0.115, .heavy),         // скорлупа лопнула
        (0.240, .medium(0.75)),  // желток ударился о пол
        (0.500, .soft(0.60)),    // капли собрались в буквы
        (0.670, .light(0.50)),   // проявился логотип
        (0.900, .success),       // передача приложению
    ]

    /// Проигрывает толчки и досыпает до конца анимации — отсюда же берётся
    /// момент, когда сплэш пора убирать.
    ///
    /// @MainActor обязателен: UIImpactFeedbackGenerator и
    /// UINotificationFeedbackGenerator изолированы главным актором, и вызов их
    /// из неизолированного кода в Swift 5 давал шесть предупреждений, а в
    /// режиме Swift 6 стал бы ошибкой. Ждать это не мешает: await внутри
    /// @MainActor-функции отпускает актор, интерфейс не подвисает. Вызов и так
    /// идёт из .task вьюхи, то есть с главного актора, — поведение не меняется.
    @MainActor
    static func run() async {
        let light = UIImpactFeedbackGenerator(style: .light)
        let medium = UIImpactFeedbackGenerator(style: .medium)
        let heavy = UIImpactFeedbackGenerator(style: .heavy)
        let soft = UIImpactFeedbackGenerator(style: .soft)
        let done = UINotificationFeedbackGenerator()
        light.prepare(); medium.prepare(); heavy.prepare(); soft.prepare(); done.prepare()

        var previous: Double = 0
        for beat in beats {
            let wait = (beat.at - previous) * Tune.duration
            previous = beat.at
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000)) }
            if Task.isCancelled { return }
            switch beat.kind {
            case .soft(let i):   soft.impactOccurred(intensity: i)
            case .light(let i):  light.impactOccurred(intensity: i)
            case .medium(let i): medium.impactOccurred(intensity: i)
            case .heavy:         heavy.impactOccurred()
            case .success:       done.notificationOccurred(.success)
            }
        }
        let tail = (1 - previous) * Tune.duration
        if tail > 0 { try? await Task.sleep(nanoseconds: UInt64(tail * 1_000_000)) }
    }
}

// MARK: - Состояние сцены

/// Держит симуляцию и часы. Класс, а не структура: TimelineView пересобирает
/// body на каждом кадре, а капли должны продолжать движение, а не рождаться заново.
/// ObservableObject — ради @StateObject (см. SplashView.scene); публикуемых полей нет.
private final class SplashScene: ObservableObject {
    let fluid: YolkFluid
    let fontSize: CGFloat
    private var startedAt: Date?
    private var lastAt: Date?
    private var blob: CGImage?
    private var blobRadius = 0

    init() {
        let sampled = sampleWordmark()
        fluid = YolkFluid(targets: sampled.points)
        fontSize = sampled.fontSize
    }

    /// Подводит симуляцию к моменту `date` и возвращает время от старта, мс.
    func advance(to date: Date) -> Double {
        guard let start = startedAt else {
            startedAt = date
            lastAt = date
            return 0
        }
        let t = date.timeIntervalSince(start) * 1000
        let dt = min(34, max(6, date.timeIntervalSince(lastAt ?? date) * 1000))
        lastAt = date
        fluid.step(t: t / Tune.timeScale, dt: dt / Tune.timeScale)
        return t
    }

    func blobImage(radius: Int, sigma: CGFloat) -> CGImage? {
        if let cached = blob, blobRadius == radius { return cached }
        let created = makeBlob(radius: radius, sigma: sigma)
        blob = created
        blobRadius = radius
        return created
    }
}

// MARK: - Экран

/// Накладывается поверх приложения и убирается сама, вызвав `onFinished`.
/// Приложение под ней уже смонтировано и грузит данные — сплэш не задерживает старт.
struct SplashView: View {
    let onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // @StateObject, а не @State: начальное значение @State вычисляется при
    // КАЖДОЙ пересборке SplashView. Корень приложения пересобирается при любом
    // изменении сессии, корзины или сети — и каждый раз заново рисовалось слово
    // в буфер и раскладывались 400 капель на главном потоке (и тут же
    // выбрасывались) — как раз в первые секунды запуска. @StateObject создаёт
    // сцену один раз.
    @StateObject private var scene = SplashScene()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                if reduceMotion {
                    drawReduced(context: context, size: size)
                } else {
                    draw(context: context, size: size, timeMs: scene.advance(to: timeline.date))
                }
            }
        }
        .ignoresSafeArea()
        // Пока сплэш на экране, касания до приложения не доходят.
        .contentShape(Rectangle())
        .onTapGesture {}
        .task {
            if reduceMotion {
                try? await Task.sleep(nanoseconds: 420_000_000)
                onFinished()
                return
            }
            // Толчки и отсчёт до конца анимации — одна и та же задача:
            // так они не могут разъехаться между собой.
            await SplashHaptics.run()
            onFinished()
        }
    }

    private var appBackground: Color {
        colorScheme == .dark ? YMPalette.graphite900 : YMPalette.cream50
    }

    private var appText: Color {
        colorScheme == .dark ? YMPalette.inkLight : YMPalette.inkDark
    }

    /// Системное «уменьшить движение»: статичный логотип на фоне приложения
    /// вместо сцены. Разбивать яйцо человеку, который просил не двигать
    /// картинку, — плохая идея.
    private func drawReduced(context: GraphicsContext, size: CGSize) {
        let ctx = context
        let full = CGRect(origin: .zero, size: size)
        ctx.fill(Path(full), with: .color(appBackground))
        let scale = min(size.width / Tune.vw, size.height / Tune.vh)
        let px = scene.fontSize * scale
        ctx.draw(
            ctx.resolve(
                Text(wordmarkText)
                    .font(.system(size: px, weight: .heavy))
                    .tracking(-0.02 * px)
                    .foregroundColor(appText)
            ),
            at: CGPoint(x: size.width / 2, y: size.height * 0.44),
            anchor: .center
        )
    }

    private func draw(context: GraphicsContext, size: CGSize, timeMs: Double) {
        var ctx = context
        let p = min(1, max(0, timeMs / Tune.duration))

        // Последние 140 мс сплэш растворяется, открывая уже готовое приложение.
        ctx.opacity = 1 - seg(p, 0.96, 1)

        let scale = min(size.width / Tune.vw, size.height / Tune.vh)
        let ox = (size.width - Tune.vw * scale) / 2
        let oy = (size.height - Tune.vh * scale) / 2
        let full = CGRect(origin: .zero, size: size)
        let eggC = CGPoint(x: ox + Tune.vw / 2 * scale, y: oy + Tune.vh * 0.40 * scale)

        // 1. Фон сплэша — всегда графит: это брендовый момент, а не экран приложения.
        ctx.fill(Path(full), with: .color(YMPalette.graphite900))

        // 2. Подложка с фоном приложения. Идёт ПОД жидкостью и логотипом,
        //    иначе закрасила бы их в самом конце.
        let warm = seg(p, 0.72, 0.90, land)
        if warm > 0.002 {
            var layer = ctx
            layer.opacity = ctx.opacity * warm
            layer.fill(Path(full), with: .color(appBackground))
        }
        let dim = 1 - warm

        // 3. Тёплое свечение под желтком.
        var glow: Double
        if p < 0.14 { glow = lerp(0.12, 0.45, seg(p, 0, 0.14, easeInOut)) }
        else if p < 0.62 { glow = lerp(0.45, 0.85, seg(p, 0.14, 0.62, easeInOut)) }
        else if p < 0.80 { glow = lerp(0.85, 0.25, seg(p, 0.62, 0.80)) }
        else if p < 0.92 { glow = lerp(0.25, 0, seg(p, 0.80, 0.92)) }
        else { glow = 0 }
        glow *= dim
        if glow > 0.002 {
            let r = 230 * scale
            var layer = ctx
            layer.opacity = ctx.opacity * glow
            layer.blendMode = .plusLighter
            layer.fill(
                Path(ellipseIn: CGRect(x: eggC.x - r, y: eggC.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: YMPalette.gold.opacity(0.50), location: 0),
                        .init(color: YMPalette.gold.opacity(0.16), location: 0.42),
                        .init(color: YMPalette.gold.opacity(0), location: 0.68),
                        .init(color: YMPalette.gold.opacity(0), location: 1),
                    ]),
                    center: eggC, startRadius: 0, endRadius: r
                )
            )
        }

        // 4. Жидкость: гауссовы пятна складываются, слой режется порогом по альфе.
        drawGoo(ctx: ctx, size: size, scale: scale, ox: ox, oy: oy)

        // 5. Блики поверх жидкости — обычным рисованием, без порога.
        let sceneMs = timeMs / Tune.timeScale
        let highlight = sceneMs > 2380 ? max(0, 1 - (sceneMs - 2380) / 620) : 1
        if highlight > 0.002 {
            var layer = ctx
            layer.opacity = ctx.opacity * 0.42 * highlight
            var i = 0
            while i < scene.fluid.droplets.count {
                let d = scene.fluid.droplets[i]
                let r = max(0.5, CGFloat(d.r) * 0.3) * scale
                let cx = ox + CGFloat(d.x - d.r * 0.3) * scale
                let cy = oy + CGFloat(d.y - d.r * 0.36) * scale
                layer.fill(
                    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)),
                    with: .color(YMPalette.goldBright)
                )
                i += 2
            }
        }

        // 6. Яйцо и осколки.
        if p < 0.46 { drawEgg(ctx: ctx, center: eggC, scale: scale, p: p) }

        // 7. Вспышка в момент раскола.
        var flash: Double
        if p < 0.115 { flash = 0 }
        else if p < 0.14 { flash = seg(p, 0.115, 0.14) }
        else { flash = max(0, 1 - seg(p, 0.14, 0.25)) }
        if flash > 0.002 {
            let r = 150 * scale * CGFloat(lerp(0.6, 1.6, seg(p, 0.115, 0.25)))
            var layer = ctx
            layer.opacity = ctx.opacity * flash
            layer.blendMode = .plusLighter
            layer.fill(
                Path(ellipseIn: CGRect(x: eggC.x - r, y: eggC.y - r, width: r * 2, height: r * 2)),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.9), location: 0),
                        .init(color: Color(hex: "#FFE296").opacity(0.35), location: 0.38),
                        .init(color: Color(hex: "#FFE296").opacity(0), location: 0.66),
                        .init(color: Color(hex: "#FFE296").opacity(0), location: 1),
                    ]),
                    center: eggC, startRadius: 0, endRadius: r
                )
            )
        }

        // 8. Чёткий логотип поверх жидких букв.
        let logoAlpha = seg(p, 0.59, 0.67)
        if logoAlpha > 0.002 {
            let shrink = seg(p, 0.86, 0.96, land)
            let px = CGFloat(lerp(Double(scene.fontSize), 28, shrink)) * scale
            let cy = oy + CGFloat(lerp(Double(Tune.vh) * 0.44, Double(Tune.vh) * 0.40, shrink)) * scale
            var layer = ctx
            layer.opacity = ctx.opacity * logoAlpha
            let color = mix(YMPalette.inkLight, appText, shrink)
            layer.draw(
                layer.resolve(
                    Text(wordmarkText)
                        .font(.system(size: px, weight: .heavy))
                        .tracking(-0.02 * px)
                        .foregroundColor(color)
                ),
                at: CGPoint(x: ox + Tune.vw / 2 * scale, y: cy),
                anchor: .center
            )
        }

        // 9. Подпись под логотипом.
        let taglineAlpha = min(seg(p, 0.63, 0.70, land), 1 - seg(p, 0.78, 0.85))
        if taglineAlpha > 0.002 {
            let px = 10 * scale
            let rise = CGFloat(lerp(8, 0, seg(p, 0.63, 0.70, land))) * scale
            var layer = ctx
            layer.opacity = ctx.opacity * taglineAlpha
            layer.draw(
                layer.resolve(
                    Text(taglineText)
                        .font(.system(size: px, weight: .semibold))
                        .tracking(0.26 * px)
                        .foregroundColor(Color(hex: "#EFD49B"))
                ),
                at: CGPoint(
                    x: ox + Tune.vw / 2 * scale,
                    y: oy + (Tune.vh * 0.44 + scene.fontSize * 0.9) * scale + rise
                ),
                anchor: .top
            )
        }

        // 10. Виньетка — гаснет вместе с подложкой.
        if dim > 0.002 {
            var layer = ctx
            layer.opacity = ctx.opacity * dim
            layer.fill(
                Path(full),
                with: .radialGradient(
                    Gradient(stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.5), location: 1),
                    ]),
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    startRadius: size.height * 0.22,
                    endRadius: size.height * 0.62
                )
            )
        }
    }

    private func drawGoo(ctx: GraphicsContext, size: CGSize, scale: CGFloat, ox: CGFloat, oy: CGFloat) {
        let radius = max(2, Int(ceil(Tune.sigma * Tune.blobSupport * scale)))
        guard let blob = scene.blobImage(radius: radius, sigma: Tune.sigma * scale) else { return }
        let r = CGFloat(radius)

        var goo = ctx
        // Порядок важен: фильтр, добавленный позже, применяется ближе к содержимому.
        // Сначала порог по накопленной альфе, затем лёгкое размытие — оно сглаживает
        // край, который порог делает ступенчатым.
        goo.addFilter(.blur(radius: 0.7))
        goo.addFilter(.alphaThreshold(min: Tune.threshold, color: YMPalette.gold))
        goo.drawLayer { layer in
            layer.withCGContext { cg in
                cg.setBlendMode(.plusLighter)
                for d in scene.fluid.droplets {
                    let amp = min(1.0, (d.r * d.r) / (2 * Double(Tune.sigma) * Double(Tune.sigma)))
                    if amp <= 0.004 { continue }
                    cg.setAlpha(CGFloat(amp))
                    let cx = ox + CGFloat(d.x) * scale
                    let cy = oy + CGFloat(d.y) * scale
                    cg.draw(blob, in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                }
            }
        }
    }

    /// Контур яйца. Не овал: верх выше низа — ровно как border-radius
    /// 50% / 62% 62% 38% 38% в макете. Сверху половина эллипса с ry = 0.62h,
    /// снизу — с ry = 0.38h. Габарит по вертикали остаётся ровно [top, top + h],
    /// поэтому полосы, на которые режутся осколки, накрывают фигуру целиком —
    /// раньше овал был сдвинут вверх и у яйца срезало верхушку.
    private func eggPath(left: CGFloat, top: CGFloat, w: CGFloat, h: CGFloat) -> Path {
        let rx = w / 2
        let ryTop = h * 0.62
        let ryBottom = h * 0.38
        let cx = left + rx
        let cy = top + ryTop
        let k: CGFloat = 0.5523
        var path = Path()
        path.move(to: CGPoint(x: cx - rx, y: cy))
        path.addCurve(to: CGPoint(x: cx, y: cy - ryTop),
                      control1: CGPoint(x: cx - rx, y: cy - ryTop * k),
                      control2: CGPoint(x: cx - rx * k, y: cy - ryTop))
        path.addCurve(to: CGPoint(x: cx + rx, y: cy),
                      control1: CGPoint(x: cx + rx * k, y: cy - ryTop),
                      control2: CGPoint(x: cx + rx, y: cy - ryTop * k))
        path.addCurve(to: CGPoint(x: cx, y: cy + ryBottom),
                      control1: CGPoint(x: cx + rx, y: cy + ryBottom * k),
                      control2: CGPoint(x: cx + rx * k, y: cy + ryBottom))
        path.addCurve(to: CGPoint(x: cx - rx, y: cy),
                      control1: CGPoint(x: cx - rx * k, y: cy + ryBottom),
                      control2: CGPoint(x: cx - rx, y: cy + ryBottom * k))
        path.closeSubpath()
        return path
    }

    private func drawEgg(ctx: GraphicsContext, center: CGPoint, scale: CGFloat, p: Double) {
        let w = 116 * scale
        let h = 152 * scale
        let left = center.x - w / 2
        let top = center.y - h / 2
        let wobble = p < 0.12 ? sin(p / 0.12 * .pi * 3) * 4 * (1 - p / 0.12) : 0
        let flyK = seg(p, 0.115, 0.44, fly)
        let alpha = p < 0.115 ? 1 : max(0, 1 - seg(p, 0.2, 0.44))
        if alpha <= 0.002 { return }

        let shell = eggPath(left: left, top: top, w: w, h: h)
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: [
                .init(color: shellLight, location: 0),
                .init(color: shellMid, location: 0.58),
                .init(color: shellDeep, location: 1),
            ]),
            startPoint: CGPoint(x: left, y: top),
            endPoint: CGPoint(x: left + w, y: top + h)
        )

        for s in shards {
            var layer = ctx
            layer.opacity = ctx.opacity * alpha
            layer.translateBy(x: center.x, y: center.y)
            layer.rotate(by: .degrees(wobble + Double(s.spin) * flyK))
            layer.translateBy(x: s.flyX * CGFloat(flyK) * scale, y: s.flyY * CGFloat(flyK) * scale)
            let k = CGFloat(1 - 0.25 * flyK)
            layer.scaleBy(x: k, y: k)
            layer.translateBy(x: -center.x, y: -center.y)
            layer.clip(to: Path(CGRect(
                x: left + s.left * w, y: top + s.top * h,
                width: (s.right - s.left) * w, height: (s.bottom - s.top) * h
            )))
            layer.fill(shell, with: shading)
        }

        // Зубчатая трещина по шву — там, где сходятся верхняя и нижняя половины.
        var crack: Double
        if p < 0.045 { crack = 0 }
        else if p < 0.10 { crack = seg(p, 0.045, 0.10) }
        else if p < 0.125 { crack = 1 }
        else { crack = max(0, 1 - seg(p, 0.125, 0.135)) }
        if crack > 0.002 {
            let grow = CGFloat(max(0.1, seg(p, 0.045, 0.10, land)))
            let yc = top + h * 0.62
            let half = w / 2 * grow
            var path = Path()
            for i in 0...8 {
                let x = center.x - half + 2 * half * CGFloat(i) / 8
                let y = yc + (i % 2 == 1 ? 6 * scale : -6 * scale)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            var layer = ctx
            layer.opacity = ctx.opacity * crack
            layer.stroke(path, with: .color(YMPalette.graphite900), lineWidth: 3.4 * scale)
        }
    }
}

/// Линейная смесь двух цветов — для перекраски логотипа в конце анимации.
private func mix(_ a: Color, _ b: Color, _ k: Double) -> Color {
    let ca = UIColor(a).cgColor.components ?? [0, 0, 0, 1]
    let cb = UIColor(b).cgColor.components ?? [0, 0, 0, 1]
    guard ca.count >= 3, cb.count >= 3 else { return a }
    return Color(
        .sRGB,
        red: Double(ca[0]) + (Double(cb[0]) - Double(ca[0])) * k,
        green: Double(ca[1]) + (Double(cb[1]) - Double(ca[1])) * k,
        blue: Double(ca[2]) + (Double(cb[2]) - Double(ca[2])) * k,
        opacity: 1
    )
}
