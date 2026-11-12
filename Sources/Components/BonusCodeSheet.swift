import SwiftUI

/*
 Лист «Код для бонусов» (редизайн, этап 11, ТЗ 5.12).

 Две страницы кода одной и той же строки: QR (уровень коррекции H, в центре наш знак ≤ 20 %
 стороны) и Code128. Листание — собственный DragGesture-пейджер: виден край соседней
 страницы, уходящая гаснет; снизу точки. Одноразовый код (TOTP) — та же логика, что и
 раньше (Core/CardSecret.swift: CardCodeModel / CardSecretMaterial), здесь только вид.
 Нет одноразового кода (старый сервер, 503, нет сети и секрета) — прежний EAN-13 с подписью.
 Яркость экрана на максимум, пока лист открыт; возвращается при закрытии и сворачивании.
*/

struct BonusCodeSheet: View {
    /// 13-значный код клиента (запасной EAN-13).
    let code: String
    /// Баланс бонусов из профиля (если пришёл).
    let balance: Decimal?

    @StateObject private var model = CardCodeModel()
    @State private var confirmRotate = false
    @State private var page = 0
    @GestureState private var drag: CGFloat = 0

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var savedBrightness: CGFloat?
    @State private var onScreen = false

    private let gap: CGFloat = 16

    private func raiseBrightness() {
        if savedBrightness == nil {
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
        }
    }
    private func restoreBrightness() {
        if let b = savedBrightness {
            UIScreen.main.brightness = b
            savedBrightness = nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                balancePill
                Text("Ваш личный код для бонусов")
                    .ymText(YMText.sectionTitle)
                    .foregroundStyle(YMUi.text)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                Text("Покажите код на кассе для начисления и списания бонусов")
                    .ymText(YMText.description)
                    .foregroundStyle(YMUi.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, YMForm.screenPadding)
                switch model.state {
                case .ready(let m): totpPager(m)
                case .loading, .fallback: eanCard
                }
                if case .ready = model.state {
                    Button(model.rotating ? "Обновляем…" : "Обновить код карты") { confirmRotate = true }
                        .ymText(YMText.button)
                        .foregroundStyle(YMColor.accent)
                        .disabled(model.rotating)
                        .padding(.top, 4)
                    if let e = model.rotateError {
                        Text(e).ymText(YMText.caption).foregroundStyle(YMColor.statusCancel)
                    }
                }
            }
            .padding(.top, 28)
            .padding(.bottom, 24)
            .ymReadableWidth()
        }
        .ymSheetChrome()
        .onAppear { onScreen = true; raiseBrightness() }
        .onDisappear { onScreen = false; restoreBrightness() }
        .task { await model.load() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if onScreen { raiseBrightness() }
                Task { await model.load() }   // перечитать секрет и поправку времени
            } else { restoreBrightness() }
        }
        .alert("Обновить код карты?", isPresented: $confirmRotate) {
            Button("Отмена", role: .cancel) {}
            Button("Обновить") { Task { await model.rotate() } }
        } message: {
            Text("Прежний код перестанет действовать. Делайте это, если кто-то мог увидеть вашу карту.")
        }
    }

    // MARK: - Плашка баланса

    @ViewBuilder private var balancePill: some View {
        if let b = balance {
            HStack(spacing: 6) {
                Image(systemName: "star.circle.fill").ymIcon(16, weight: .semibold)
                Text("\(Int(truncating: b as NSDecimalNumber)) бонусов")
                    .ymText(YMText.button)
            }
            .foregroundStyle(YMPalette.goldInk)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(YMUi.accentFill, in: Capsule())
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Одноразовый код: две страницы

    private func totpPager(_ m: CardSecretMaterial) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            let str = m.string(at: ctx.date)
            let left = m.secondsLeft(at: ctx.date)
            VStack(spacing: 12) {
                pager(str)
                dots
                Text("Код обновится через \(left) с")
                    .ymText(YMText.caption)
                    .foregroundStyle(YMUi.textSecondary)
            }
        }
    }

    private func pager(_ str: String) -> some View {
        GeometryReader { geo in
            let w = max(240, geo.size.width - 2 * 40)       // ширина страницы; по краям виден сосед
            let step = w + gap
            let side = (geo.size.width - w) / 2
            // Непрерывная позиция пейджера 0...1 (палец ведёт страницы).
            let pos = min(1, max(0, CGFloat(page) - drag / step))
            HStack(spacing: gap) {
                qrCard(str, width: w)
                    .opacity(1 - 0.65 * pos)
                    .frame(width: w)
                codeCard(str, width: w)
                    .opacity(0.35 + 0.65 * pos)
                    .frame(width: w)
            }
            .offset(x: side - CGFloat(page) * step + drag)
            .frame(width: geo.size.width, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .updating($drag) { v, state, _ in
                        // На краях тянется с сопротивлением.
                        let t = v.translation.width
                        state = (page == 0 && t > 0) || (page == 1 && t < 0) ? t / 4 : t
                    }
                    .onEnded { v in
                        let t = v.predictedEndTranslation.width
                        var next = page
                        if t < -step / 3 { next = 1 } else if t > step / 3 { next = 0 }
                        setPage(next)
                    }
            )
        }
        .frame(height: 340)
    }

    private func setPage(_ p: Int) {
        guard p != page else { return }
        Haptics.selection()
        if reduceMotion { page = p } else { withAnimation(.easeOut(duration: YMDur.tabSwitch)) { page = p } }
    }

    private var dots: some View {
        HStack(spacing: 8) {
            ForEach(0..<2, id: \.self) { i in
                Circle()
                    .fill(i == page ? YMUi.text : YMUi.disabledBg)
                    .frame(width: 8, height: 8)
                    .contentShape(Rectangle().inset(by: -8))
                    .onTapGesture { setPage(i) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(page == 0 ? "QR-код, страница 1 из 2" : "Штрихкод, страница 2 из 2")
        .accessibilityAdjustableAction { dir in
            setPage(dir == .increment ? 1 : 0)
        }
    }

    private func qrCard(_ str: String, width: CGFloat) -> some View {
        let side = width - 40
        return ZStack {
            if let qr = CardBarcode.qr(str, level: "H") {
                Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                    .frame(width: side, height: side)
                // Знак по центру: белый скруглённый квадрат ≤ 20 % стороны (уровень H переживает ~30 %).
                ZStack {
                    RoundedRectangle(cornerRadius: side * 0.04, style: .continuous).fill(Color.white)
                    Circle().fill(YMUi.accentFill).padding(side * 0.02)
                    Text("Y").font(.custom("Unbounded-Bold", fixedSize: side * 0.09))
                        .foregroundStyle(YMPalette.goldInk)
                }
                .frame(width: side * 0.19, height: side * 0.19)
            }
        }
        .frame(width: width, height: width)
        .background(Color.white, in: RoundedRectangle(cornerRadius: YMForm.cardRadius + 4, style: .continuous))
        .accessibilityLabel("QR-код для бонусов")
    }

    private func codeCard(_ str: String, width: CGFloat) -> some View {
        VStack(spacing: 14) {
            if let bc = CardBarcode.code128(str) {
                Image(uiImage: bc).interpolation(.none).resizable()
                    .frame(maxWidth: .infinity).frame(height: 110)
            }
            Text(str)
                .ymFont(15, weight: .semibold)
                .foregroundStyle(Color.black)
        }
        .padding(.horizontal, 16)
        .frame(width: width, height: width)
        .background(Color.white, in: RoundedRectangle(cornerRadius: YMForm.cardRadius + 4, style: .continuous))
        .accessibilityLabel("Штрихкод для бонусов \(str)")
    }

    // MARK: - Запасной EAN-13 (прежний вид)

    @ViewBuilder private var eanCard: some View {
        if let modules = EAN13.modules(code) {
            VStack(spacing: 10) {
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        // Ширину модуля округляем вниз до целого пикселя, остаток делим по краям:
                        // дробная ширина размывает границы полос, камерные сканеры читают хуже.
                        let scale = UIScreen.main.scale
                        let raw = geo.size.width / CGFloat(modules.count)
                        let mw = max(1 / scale, (raw * scale).rounded(.down) / scale)
                        let pad = (geo.size.width - mw * CGFloat(modules.count)) / 2
                        Path { path in
                            for (i, on) in modules.enumerated() where on {
                                path.addRect(CGRect(x: pad + CGFloat(i) * mw, y: 0,
                                                    width: mw, height: geo.size.height))
                            }
                        }
                        .fill(Color.black)
                    }
                    .frame(height: 96)
                    Text(EAN13.pretty(code))
                        .ymFont(15, weight: .semibold)
                        .foregroundStyle(Color.black)
                }
                .padding(.horizontal, 14).padding(.vertical, 18)
                .background(Color.white, in: RoundedRectangle(cornerRadius: YMForm.cardRadius + 4, style: .continuous))
                Text("Списание баллов по этому коду может потребовать подтверждения")
                    .ymText(YMText.caption)
                    .foregroundStyle(YMUi.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, YMForm.screenPadding)
        }
    }
}
