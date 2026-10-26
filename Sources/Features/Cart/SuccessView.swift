import SwiftUI

//
//  SuccessView.swift — экран успеха (screen: success). Дизайн 1:1 с CheckoutPhone.dc.html.
//
//  ПУБЛИЧНАЯ INIT-СИГНАТУРА (для централизованной навигации):
//    SuccessView(order: OrderCreateResult, onTrack: () -> Void, onHome: () -> Void)
//      order   — результат создания заказа (номер для показа).
//      onTrack — «Следить за заказом» (родитель открывает трекинг).
//      onHome  — «На главную».
//
//  Конфетти — падающие частицы (золото/зелёный/белый) через TimelineView + Canvas,
//  с учётом Reduce Motion (при включённом — статичный экран без анимации).
//  Золотой круг 110×110 с ✓ и pop-анимацией. Токены — YM*.
//
//  API: экран ничего не запрашивает — принимает готовый OrderCreateResult.
//  ETA берётся из TODO(API): в OrderCreateResult нет поля eta — показываем
//  типовой диапазон-плейсхолдер (реальный ETA приходит на экране трекинга).
//

struct SuccessView: View {
    let order: OrderCreateResult
    var onTrack: () -> Void = {}
    var onHome: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var checkPopped = false
    /// Конфетти крутилось без конца (TimelineView .animation — перерисовка каждый
    /// кадр), пока экран открыт: батарея и нагрев. Гасим через несколько секунд.
    @State private var confettiOn = true

    // Номер заказа: dailyNumber (виден клиенту) → id → 0.
    // Сервер отдаёт номер заказа в order_id, а не в id: без daily_number было «№0».
    private var orderNumber: Int { order.dailyNumber ?? order.resolvedId ?? 0 }

    /// П-22.2: срок от сервера. Предзаказ — его время; оба eta nil (старый
    /// сервер, повтор duplicate) — ничего; равны — «~N мин»; иначе «N–M мин».
    private var etaLine: String? {
        if let p = order.preorderAt {
            return "Предзаказ на \(SuccessView.preorderText(p))"
        }
        let lo = order.etaMin.flatMap { $0 > 0 ? $0 : nil }
        let hi = order.etaMax.flatMap { $0 > 0 ? $0 : nil }
        let span: String
        switch (lo, hi) {
        case (let a?, let b?) where a == b: span = "~\(a) мин"
        case (let a?, let b?):          span = "\(min(a, b))–\(max(a, b)) мин"
        case (let a?, nil):             span = "~\(a) мин"
        case (nil, let b?):             span = "~\(b) мин"
        default:                        return nil
        }
        switch order.deliveryType {
        case "delivery":           return "Ожидаемая доставка: \(span)"
        // «примерно через ~15 мин» — двойное «примерно»: тильду здесь убираем.
        case "pickup", "dine_in":
            let plain = span.hasPrefix("~") ? String(span.dropFirst()) : span
            return "Будет готов примерно через \(plain)"
        default:                   return "Ориентировочно: \(span)"
        }
    }

    /// «2026-10-12 14:30:00» (время Москвы) → «12 октября, 14:30». Не разобрали — как есть.
    private static func preorderText(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "T", with: " ")
        let inF = DateFormatter()
        inF.locale = Locale(identifier: "en_US_POSIX")
        inF.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        for fmt in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm"] {
            inF.dateFormat = fmt
            if let d = inF.date(from: String(s.prefix(fmt == "yyyy-MM-dd HH:mm" ? 16 : 19))) {
                let outF = DateFormatter()
                outF.locale = Locale(identifier: "ru_RU")
                outF.timeZone = inF.timeZone   // время заведения (Москва), а не пояса телефона
                outF.dateFormat = "d MMMM, HH:mm"
                return outF.string(from: d)
            }
        }
        return s
    }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()

            if !reduceMotion && confettiOn {
                ConfettiView().ignoresSafeArea().allowsHitTesting(false)
                    .transition(.opacity)
            }

            VStack(spacing: 0) {
                Spacer()

                // Золотой круг 110×110 с pop-анимацией.
                ZStack {
                    Circle()
                        .fill(YMColor.accent)
                        .frame(width: 110, height: 110)
                        .shadow(color: YMPalette.gold.opacity(0.6), radius: 50, y: 20)
                    Image(systemName: "checkmark")
                        .font(.system(size: 46, weight: .bold))
                        .foregroundStyle(YMColor.onAccent)
                }
                .scaleEffect(checkPopped ? 1 : (reduceMotion ? 1 : 0.4))
                .opacity(checkPopped || reduceMotion ? 1 : 0)

                Text("Заказ оформлен!")
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(YMColor.text)
                    .padding(.top, YMSpace.xxl)

                // Заказ только что создан: заведение его ещё не приняло, а у
                // самовывоза и заказа за столиком курьера нет вовсе. Раньше здесь
                // было «уже приняло… курьер будет в пути» и выдуманная плашка
                // «Ожидаемая доставка · 25–35 мин» (сервер срок не присылает) —
                // человек ждал курьера к самовывозу. Точный статус — в «Следить за заказом».
                // Номера в ответе нет (старый сервер) — без «№0».
                Text((orderNumber > 0 ? "Заказ №\(orderNumber)" : "Заказ") + " передан в заведение.\nМы сообщим, когда его примут.")
                    .font(YMFont.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, YMSpace.sm)
                    .padding(.horizontal, YMSpace.xxl)

                // П-22.2: срок/время предзаказа — только если сервер их прислал.
                if let eta = etaLine {
                    Text(eta)
                        .font(YMFont.headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(YMColor.text)
                        .padding(.top, YMSpace.md)
                        .padding(.horizontal, YMSpace.xxl)
                }

                Spacer()

                VStack(spacing: YMSpace.md) {
                    Button(action: { Haptics.light(); onTrack() }) {
                        Text("Следить за заказом")
                    }
                    .buttonStyle(YMPrimaryButtonStyle())

                    Button(action: { Haptics.light(); onHome() }) {
                        Text("На главную")
                    }
                    .buttonStyle(YMGhostButtonStyle())
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.bottom, YMSpace.xxl)
            }
        }
        .navigationBarHidden(true)
        .onAppear {
            Haptics.success()
            if reduceMotion {
                checkPopped = true
            } else {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) { checkPopped = true }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                withAnimation(.easeOut(duration: 0.6)) { confettiOn = false }
            }
        }
    }
}

// MARK: - Конфетти (падающие частицы, TimelineView + Canvas)

/// Частицы золото/зелёный/белый падают сверху с вращением. Рендер — Canvas в
/// TimelineView (эффективно, без per-particle View). Вызывается только при
/// выключенном Reduce Motion (родитель это проверяет).
private struct ConfettiView: View {
    private struct Particle {
        let x: CGFloat          // 0..1 по ширине
        let size: CGFloat
        let color: Color
        let delay: Double
        let duration: Double
        let spin: Double        // оборотов за падение
    }

    private let particles: [Particle]

    init() {
        let colors: [Color] = [
            YMPalette.gold, YMPalette.goldBright,
            YMColor.statusDone, YMPalette.inkLight, YMPalette.goldDeep
        ]
        self.particles = (0..<24).map { i in
            Particle(
                x: CGFloat(Double.random(in: 0.04...0.96)),
                size: CGFloat.random(in: 6...11),
                color: colors[i % colors.count],
                delay: Double.random(in: 0...1.4),
                duration: Double.random(in: 2.2...3.6),
                spin: Double.random(in: 1.2...3.0)
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                for p in particles {
                    // Прогресс падения в цикле (учёт задержки).
                    let t = (now - p.delay).truncatingRemainder(dividingBy: p.duration)
                    guard t >= 0 else { continue }
                    let progress = t / p.duration
                    let y = -20 + CGFloat(progress) * (size.height + 40)
                    let x = p.x * size.width
                    // Плавный fade-in / fade-out.
                    let alpha: Double = progress < 0.2 ? progress / 0.2
                                       : progress > 0.85 ? max(0, (1 - progress) / 0.15) : 1
                    let angle = Angle(degrees: progress * 360 * p.spin)

                    var rect = Path(roundedRect: CGRect(x: -p.size / 2, y: -p.size / 2, width: p.size, height: p.size * 0.6),
                                    cornerRadius: 1.5)
                    rect = rect.applying(CGAffineTransform(rotationAngle: CGFloat(angle.radians)))
                    rect = rect.applying(CGAffineTransform(translationX: x, y: y))
                    ctx.fill(rect, with: .color(p.color.opacity(alpha)))
                }
            }
        }
    }
}
