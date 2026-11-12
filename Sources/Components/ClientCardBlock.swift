import SwiftUI

/*
 Плашка «Карта клиента» в профиле: штрихкод EAN-13 (см. Core/EAN13.swift) и
 номер под ним. Показывается кассиру в магазине.

 Фон штрихкода белый даже в тёмной теме — инверсию кассовые сканеры не читают.
 На время показа поднимаем яркость экрана: на приглушённом экране скан обычно
 не проходит. Прежняя яркость возвращается, когда экран уходит.
*/

struct ClientCardBlock: View {
    let code: String

    @State private var savedBrightness: CGFloat?
    /// Яркость, выставленная приложением, держится и после сворачивания (до
    /// блокировки телефона): с открытым профилем свернули приложение — экран
    /// оставался на 100 % и садил батарею. Возвращаем при уходе в фон и
    /// поднимаем снова при возврате, если карта всё ещё на экране.
    @Environment(\.scenePhase) private var scenePhase
    @State private var onScreen = false

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

    @StateObject private var model = CardCodeModel()
    @State private var confirmRotate = false

    var body: some View {
        Group {
            switch model.state {
            case .ready(let m): totpCard(m)
            case .loading, .fallback: eanCard
            }
        }
        .onAppear { onScreen = true; raiseBrightness() }
        .onDisappear { onScreen = false; restoreBrightness() }
        .task { await model.load() }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                if onScreen { raiseBrightness() }
                Task { await model.load() }   // перечитать секрет и поправку времени
            } else { restoreBrightness() }
        }
    }

    /// Одноразовый QR (К-57): client_code + TOTP = 19 цифр; QR и Code128 той же строки, смена каждые 30 с.
    private func totpCard(_ m: CardSecretMaterial) -> some View {
        TimelineView(.periodic(from: Date(), by: 1)) { ctx in
            let str = m.string(at: ctx.date)
            let left = m.secondsLeft(at: ctx.date)
            VStack(spacing: 8) {
                Text("Карта клиента")
                    .ymFont(13, weight: .semibold)
                    .foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 10) {
                    if let qr = CardBarcode.qr(str) {
                        Image(uiImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 180, height: 180)
                    }
                    if let bc = CardBarcode.code128(str) {
                        Image(uiImage: bc).interpolation(.none).resizable()
                            .frame(maxWidth: .infinity).frame(height: 56)
                    }
                    Text(str)
                        .ymFont(15, weight: .semibold)
                        .foregroundStyle(Color.black)
                    Text("Код обновится через \(left) с")
                        .ymFont(12).foregroundStyle(Color.gray)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Покажите этот код кассиру — покупка учтётся в бонусах. Код одноразовый и меняется каждые 30 секунд")
                    .ymFont(12)
                    .foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
                Button(model.rotating ? "Обновляем…" : "Обновить код карты") { confirmRotate = true }
                    .ymFont(13, weight: .semibold)
                    .disabled(model.rotating)
                if let e = model.rotateError {
                    Text(e).ymFont(12).foregroundStyle(YMColor.statusCancel)
                }
            }
            .padding(YMSpace.lg)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.lg)
        }
        .alert("Обновить код карты?", isPresented: $confirmRotate) {
            Button("Отмена", role: .cancel) {}
            Button("Обновить") { Task { await model.rotate() } }
        } message: {
            Text("Прежний код перестанет действовать. Делайте это, если кто-то мог увидеть вашу карту.")
        }
    }

    /// Прежняя карта: EAN-13 (старый сервер, 503 card_unavailable, нет сети и сохранённого секрета).
    @ViewBuilder private var eanCard: some View {
        if let modules = EAN13.modules(code) {
            VStack(spacing: 8) {
                Text("Карта клиента")
                    .ymFont(13, weight: .semibold)
                    .foregroundStyle(YMColor.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: 6) {
                    GeometryReader { geo in
                        // Ширину модуля округляем вниз до целого пикселя, а остаток
                        // делим поровну по краям: дробная ширина размывает границы
                        // полос антиалиасингом, и камерные сканеры читают хуже.
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
                    .frame(height: 76)
                    Text(EAN13.pretty(code))
                        .ymFont(15, weight: .semibold)
                        .foregroundStyle(Color.black)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Покажите этот код кассиру — покупка учтётся в бонусах. Списание баллов по этому коду может потребовать подтверждения")
                    .ymFont(12)
                    .foregroundStyle(YMColor.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(YMSpace.lg)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.lg)
        }
    }
}
