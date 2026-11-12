import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

//
//  Effects.swift — «живые» эффекты интерфейса (разовые, без бесконечных анимаций).
//
//  • YMTouchTracker / YMTouchRecognizer — глобальный трекер последнего касания.
//  • View.ymCartFlight — золотой шарик из точки касания к вкладке «Корзина».
//  • YMBurst — разовый взрыв частиц (конфетти, искры); один Canvas, после конца
//    эффекта view рисует Color.clear (кадры не перерисовываются).
//  • YMSuccessBadge — круг с галочкой для экрана «Заказ оформлен».
//  • View.ymNumeric — «барабан» цифр при смене суммы.
//  • View.ymBumpGloss — bump масштаба + блик на плавающей кнопке.
//
//  Все декоративные эффекты выключены при accessibilityReduceMotion.
//

// MARK: - Числа-«барабаны»

private struct YMNumericModifier<V: Equatable>: ViewModifier {
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : YMMotion.spring, value: value)
    }
}

extension View {
    /// Текст с числом: цифры «перекатываются» при смене `value`.
    func ymNumeric<V: Equatable>(_ value: V) -> some View { modifier(YMNumericModifier(value: value)) }
}

// MARK: - Bump + блик

private struct YMBumpGlossModifier<V: Equatable>: ViewModifier {
    let trigger: V
    let radius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scale: CGFloat = 1
    @State private var glossOn = false
    @State private var sweep: CGFloat = 0
    @State private var gen = 0

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .overlay(
                GeometryReader { geo in
                    if glossOn {
                        LinearGradient(
                            colors: [Color.white.opacity(0), Color.white.opacity(0.55), Color.white.opacity(0)],
                            startPoint: .leading, endPoint: .trailing)
                            .frame(width: geo.size.width * 0.35)
                            .offset(x: -geo.size.width * 0.35 + geo.size.width * 1.35 * sweep)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .allowsHitTesting(false)
            )
            .onChange(of: trigger) { _ in play() }
    }

    private func play() {
        guard !reduceMotion else { return }
        gen += 1
        let g = gen
        withAnimation(.spring(response: 0.16, dampingFraction: 0.6)) { scale = 1.04 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { scale = 1 }
        }
        sweep = 0
        glossOn = true
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.45)) { sweep = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if g == gen { glossOn = false } }
    }
}

extension View {
    /// При смене `trigger`: масштаб 1 → 1.04 → 1 и один проход золотого блика по форме кнопки.
    func ymBumpGloss<V: Equatable>(trigger: V, radius: CGFloat) -> some View {
        modifier(YMBumpGlossModifier(trigger: trigger, radius: radius))
    }
}

// MARK: - Глобальный трекер последнего касания

/// Распознаватель-«наблюдатель»: запоминает точку касания и сразу переходит в .failed,
/// поэтому никому не мешает (касания проходят дальше, ничего не откладывается).
final class YMTouchRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first, let v = view {
            YMTouchTracker.record(t.location(in: v))
        }
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }
}

enum YMTouchTracker {
    private static var lastPoint: CGPoint?
    private static var lastTime: CFTimeInterval = 0

    static func record(_ p: CGPoint) {
        lastPoint = p
        lastTime = CACurrentMediaTime()
    }

    /// Точка касания (в координатах окна), если оно было не раньше `maxAge` секунд назад.
    static func recent(maxAge: CFTimeInterval = 1.2) -> CGPoint? {
        guard let p = lastPoint, CACurrentMediaTime() - lastTime <= maxAge else { return nil }
        return p
    }

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let pool = (active.isEmpty ? scenes : active).flatMap { $0.windows }
        return pool.first(where: { $0.isKeyWindow }) ?? pool.first
    }

    /// Ставит распознаватель на key window (один раз). Если окна ещё нет — повторяет попытку.
    static func install(attempt: Int = 0) {
        if let w = keyWindow() {
            let has = w.gestureRecognizers?.contains(where: { $0 is YMTouchRecognizer }) ?? false
            if !has { w.addGestureRecognizer(YMTouchRecognizer(target: nil, action: nil)) }
        } else if attempt < 10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { install(attempt: attempt + 1) }
        }
    }
}

// MARK: - Полёт в корзину

/// Шарик по квадратичной Безье + хвост + кольцо в точке прибытия. Один Canvas.
struct YMFlightView: View {
    let from: CGPoint
    let to: CGPoint
    let start: Date

    static let flightDuration: Double = 0.52
    static let ringDuration: Double = 0.4
    static var totalDuration: Double { flightDuration + ringDuration }

    private var control: CGPoint {
        CGPoint(x: (from.x + to.x) / 2, y: min(from.y, to.y) - 140)
    }

    private func ease(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    private func point(_ e: CGFloat) -> CGPoint {
        let u = 1 - e
        return CGPoint(
            x: u * u * from.x + 2 * u * e * control.x + e * e * to.x,
            y: u * u * from.y + 2 * u * e * control.y + e * e * to.y)
    }

    var body: some View {
        TimelineView(.animation) { tl in
            Canvas { ctx, _ in
                let el = tl.date.timeIntervalSince(start)
                if el < 0 { return }
                if el < Self.flightDuration {
                    let t = CGFloat(el / Self.flightDuration)
                    for i in (0...4).reversed() {
                        let tt = t - CGFloat(i) * 0.04
                        if tt <= 0 { continue }
                        let e = ease(tt)
                        let p = point(e)
                        let k: Double = i == 0 ? 1 : 0.5 * (1 - Double(i) / 5)
                        let r = 11 * (1 - 0.55 * e) * (i == 0 ? 1 : 0.85)
                        let glowR = r * 2.2
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: p.x - glowR, y: p.y - glowR, width: glowR * 2, height: glowR * 2)),
                            with: .radialGradient(
                                Gradient(colors: [YMPalette.gold.opacity(0.55 * k), YMPalette.gold.opacity(0)]),
                                center: p, startRadius: 0, endRadius: glowR))
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                            with: .radialGradient(
                                Gradient(colors: [YMPalette.goldBright.opacity(k), YMPalette.gold.opacity(k)]),
                                center: p, startRadius: 0, endRadius: r))
                    }
                } else {
                    let rt = CGFloat(min(1, (el - Self.flightDuration) / Self.ringDuration))
                    let eo = 1 - pow(1 - rt, 3)
                    let r = 8 + 20 * eo
                    let ring = Path(ellipseIn: CGRect(x: to.x - r, y: to.y - r, width: r * 2, height: r * 2))
                    ctx.stroke(ring, with: .color(YMPalette.gold.opacity(Double(1 - rt))), lineWidth: 2.5)
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Показывает полёт отдельным слоем поверх всего окна (видно и над шторками/обложками).
enum YMFlightHost {
    static let cartTabIndex = 2
    static let tabCount = 5
    /// Центр плавающей корзины-пилюли (координаты окна), пока она на экране; иначе nil.
    static var cartPillCenter: CGPoint?

    static func fly(from: CGPoint) {
        guard let window = YMTouchTracker.keyWindow() else { return }
        // На iPad (regular) таб-бар может быть сверху — геометрию не угадываем.
        if window.traitCollection.horizontalSizeClass == .regular { return }
        let b = window.bounds
        let tab = (CGFloat(cartTabIndex) + 0.5) / CGFloat(tabCount)
        let target = cartPillCenter
            ?? CGPoint(x: b.width * tab, y: b.height - window.safeAreaInsets.bottom - 29)
        let host = UIHostingController(rootView: YMFlightView(from: from, to: target, start: Date()))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.frame = b
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        window.addSubview(host.view)
        DispatchQueue.main.asyncAfter(deadline: .now() + YMFlightView.totalDuration + 0.1) {
            host.view.removeFromSuperview()
        }
    }
}

private struct YMCartFlightModifier: ViewModifier {
    let count: Int
    let suppressed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var prev: Int?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if prev == nil { prev = count }
                YMTouchTracker.install()
            }
            .onChange(of: count) { new in
                let old = prev ?? new
                prev = new
                guard new > old, !suppressed else { return }
                // Рост без недавнего касания (подтяжка с сервера, восстановление) — тихо.
                guard let p = YMTouchTracker.recent() else { return }
                Haptics.lightIfQuiet()
                guard !reduceMotion else { return }
                YMFlightHost.fly(from: p)
            }
    }
}

extension View {
    /// Когда `count` растёт и корзина не на экране (`suppressed == false`) — шарик летит к вкладке «Корзина».
    func ymCartFlight(count: Int, suppressed: Bool) -> some View {
        modifier(YMCartFlightModifier(count: count, suppressed: suppressed))
    }
}

// MARK: - Взрыв частиц

struct YMBurstConfig {
    var count: Int = 70
    var colors: [Color] = [YMPalette.gold, YMPalette.goldBright, YMColor.statusDone, YMPalette.inkLight, YMPalette.goldDeep]
    var speed: ClosedRange<CGFloat> = 350...900
    var gravity: CGFloat = 900
    var drag: CGFloat = 2.2
    var duration: Double = 2.2
    var size: ClosedRange<CGFloat> = 6...11
    var evenAngles = false
    var upwardBias: CGFloat = 0.55
    var mixShapes = true
    var delay: Double = 0

    static var confetti: YMBurstConfig { YMBurstConfig() }

    static func sparks(size: CGFloat, colors: [Color]) -> YMBurstConfig {
        var c = YMBurstConfig()
        c.count = 7
        c.colors = colors
        c.speed = (size * 3.0)...(size * 3.4)
        c.gravity = 0
        c.drag = 4
        c.duration = 0.5
        c.size = 2.5...3.5
        c.evenAngles = true
        c.upwardBias = 0
        c.mixShapes = false
        return c
    }
}

struct YMBurst: View {
    private struct Particle {
        let vx: CGFloat
        let vy: CGFloat
        let size: CGFloat
        let color: Color
        let isCircle: Bool
        let rot0: Double
        let spin: Double
        let tumble: Double
    }

    private let config: YMBurstConfig
    private let origin: UnitPoint

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var particles: [Particle]
    @State private var start = Date()
    @State private var done = false

    init(config: YMBurstConfig = .confetti, origin: UnitPoint = .center) {
        self.config = config
        self.origin = origin
        var list: [Particle] = []
        let n = max(1, config.count)
        for i in 0..<n {
            let a: Double = config.evenAngles
                ? Double(i) / Double(n) * 2 * Double.pi
                : Double.random(in: 0..<(2 * Double.pi))
            let s = CGFloat.random(in: config.speed)
            list.append(Particle(
                vx: CGFloat(cos(a)) * s,
                vy: CGFloat(sin(a)) * s - config.upwardBias * s,
                size: CGFloat.random(in: config.size),
                color: config.colors.isEmpty ? Color.yellow : config.colors[i % config.colors.count],
                isCircle: config.mixShapes ? (i % 3 == 0) : true,
                rot0: Double.random(in: 0..<(2 * Double.pi)),
                spin: Double.random(in: -12...12),
                tumble: Double.random(in: 4...10)))
        }
        _particles = State(initialValue: list)
    }

    var body: some View {
        Group {
            if reduceMotion || done {
                Color.clear
            } else {
                TimelineView(.animation) { tl in
                    Canvas { ctx, size in
                        let t = tl.date.timeIntervalSince(start) - config.delay
                        if t < 0 || t > config.duration { return }
                        let k = Double(config.drag)
                        let g = Double(config.gravity)
                        let e = exp(-k * t)
                        let u = t / config.duration
                        let alpha: Double = u < 0.65 ? 1.0 : max(0, (1 - u) / 0.35)
                        let ox = Double(size.width * origin.x)
                        let oy = Double(size.height * origin.y)
                        for p in particles {
                            let x = ox + Double(p.vx) / k * (1 - e)
                            let y = oy + (Double(p.vy) - g / k) / k * (1 - e) + g * t / k
                            var c = ctx
                            c.translateBy(x: CGFloat(x), y: CGFloat(y))
                            if p.isCircle {
                                let r = p.size / 2
                                c.fill(Path(ellipseIn: CGRect(x: -r, y: -r, width: r * 2, height: r * 2)),
                                       with: .color(p.color.opacity(alpha)))
                            } else {
                                c.rotate(by: .radians(p.rot0 + p.spin * t))
                                let flip = CGFloat(abs(cos(p.tumble * t)))
                                c.scaleBy(x: 1, y: max(0.15, flip))
                                c.fill(Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size * 0.3, width: p.size, height: p.size * 0.6),
                                            cornerRadius: 1.5),
                                       with: .color(p.color.opacity(alpha)))
                            }
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .task {
            let secs = config.duration + config.delay + 0.1
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            done = true
        }
    }
}

// MARK: - Галочка «Заказ оформлен»

private struct YMCheckShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.minY + rect.height * 0.52))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.minY + rect.height * 0.72))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.78, y: rect.minY + rect.height * 0.30))
        return p
    }
}

/// Золотой круг 110×110: поп → галочка рисуется линией; ударная волна, свечение, взрыв конфетти.
struct YMSuccessBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var popped = false
    @State private var checkProgress: CGFloat = 0
    @State private var ringOn = false
    @State private var glow: Double = 0
    @State private var glowScale: CGFloat = 0.6
    @State private var burst = false

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(RadialGradient(colors: [YMPalette.gold.opacity(0.55), YMPalette.gold.opacity(0)],
                                         center: .center, startRadius: 0, endRadius: 120))
                    .frame(width: 240, height: 240)
                    .scaleEffect(glowScale)
                    .opacity(glow)
                Circle()
                    .stroke(YMPalette.gold, lineWidth: ringOn ? 1 : 5)
                    .frame(width: 110, height: 110)
                    .scaleEffect(ringOn ? 2.6 : 1)
                    .opacity(ringOn ? 0 : 0.9)
            }
            Circle()
                .fill(YMColor.accent)
                .frame(width: 110, height: 110)
                .shadow(color: YMPalette.gold.opacity(0.6), radius: 50, y: 20)
                .scaleEffect(popped || reduceMotion ? 1 : 0.4)
                .opacity(popped || reduceMotion ? 1 : 0)
            YMCheckShape()
                .trim(from: 0, to: reduceMotion ? 1 : checkProgress)
                .stroke(YMColor.onAccent, style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round))
                .frame(width: 50, height: 50)
        }
        .frame(width: 110, height: 110)
        .overlay(
            Group {
                if burst {
                    YMBurst(config: .confetti)
                        .frame(width: 700, height: 1000)
                }
            }
            .allowsHitTesting(false)
        )
        .zIndex(1)
        .accessibilityHidden(true)
        .onAppear { play() }
    }

    private func play() {
        guard !reduceMotion else { return }
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { popped = true }
        withAnimation(.easeOut(duration: 0.35).delay(0.25)) { checkProgress = 1 }
        withAnimation(.easeOut(duration: 0.7).delay(0.15)) { ringOn = true }
        withAnimation(.easeOut(duration: 0.5).delay(0.1)) { glow = 0.7; glowScale = 1.1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) {
            withAnimation(.easeInOut(duration: 1.2)) { glow = 0.3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { burst = true }
    }
}
