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
//  Эффекты (Sources/DesignSystem/Effects.swift, YMSuccessBadge): разовый взрыв конфетти
//  (Canvas на ~2,2 с), ударная волна, свечение, галочка рисуется линией.
//  При Reduce Motion — статичный экран без анимации (хаптика остаётся). Токены — YM*.
//
//  API: экран ничего не запрашивает — принимает готовый OrderCreateResult.
//  ETA берётся из TODO(API): в OrderCreateResult нет поля eta — показываем
//  типовой диапазон-плейсхолдер (реальный ETA приходит на экране трекинга).
//

struct SuccessView: View {
    let order: OrderCreateResult
    var onTrack: () -> Void = {}
    var onHome: () -> Void = {}


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
    static func preorderText(_ raw: String) -> String {
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

            VStack(spacing: 0) {
                Spacer()

                // Золотой круг 110×110: поп, галочка линией, ударная волна, свечение, взрыв конфетти.
                YMSuccessBadge()

                Text("Заказ оформлен!")
                    .ymFont(26, weight: .heavy)
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

                // AT-3: повтор вернул заказ, созданный по прошлому нажатию (duplicate):
                // правки формы после обрыва связи в него не попали — говорим прямо.
                if order.duplicate == true {
                    Text("Этот заказ уже был оформлен по прошлому нажатию — второй не создан. Проверьте в нём адрес, оплату и время.")
                        .font(YMFont.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(YMColor.statusCancel)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, YMSpace.md)
                        .padding(.horizontal, YMSpace.xxl)
                }

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
        .onAppear { Haptics.success() }
    }
}
