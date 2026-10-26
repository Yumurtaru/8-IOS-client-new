import SwiftUI

// Карточки организаций и позиций для Главной.
// Строго на дизайн-токенах (YMColor/YMFont/YMSpace/YMRadius), light + dark.
// Фото — PhotoPlaceholder (внутри сам грузит реальное изображение через AsyncImage,
// если передан url). Деньги форматируются через Money.format(Decimal).

// MARK: - OrgCard (крупная карточка организации: ресторан/магазин/услуга)

/// Крупная карточка организации по макету Home «Рестораны»:
/// фото 150pt, бейдж статуса «Открыто» (зелёный), ♡ 32×32 на blur,
/// время доставки на blur, название 17/heavy, ★рейтинг, кухня/тег,
/// цена золотом · «Доставка бесплатно».
struct OrgCard: View {
    let shop: Shop
    /// Индекс для детерминированного тона плейсхолдера (карусель/список разнообразны).
    var tone: Int = 0
    @Binding var isFav: Bool
    var onTap: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    // Фото: cover → banner → logo (как в старом клиенте).
    private var photoURL: URL? { API.imageURL(shop.cover ?? shop.banner ?? shop.logo) }

    private var isOpen: Bool { shop.isOpen ?? true }

    // Цена «от N ₽» — минимальная сумма/чек, если есть. У Shop нет прямого поля,
    // поэтому показываем корректный fallback без выдумывания несуществующих данных.
    private var priceLine: String? {
        // TODO(API): в модели Shop нет поля «средний чек / от N ₽» на выдаче списка.
        // Если сервер начнёт отдавать avg_price/price_from — добавить сюда (аддитивно).
        nil
    }

    // Способы получения приходят с сервера готовой строкой: «Доставка и самовывоз»,
    // «Только самовывоз», у услуг — «На месте и с выездом». Раньше здесь стояло
    // жёстко зашитое «Доставка уточняется» — для заведения, работающего только
    // на вынос, это была неправда, а для салона — бессмыслица.
    private var fulfillmentText: String? {
        guard let t = shop.fulfillmentLabel, !t.isEmpty else { return nil }
        return t
    }

    /// Паритет с Android: delivery_time сервер не отдаёт, время приготовления
    /// приходит в avg_cook_time — бейдж «N мин» на фото, как на Android.
    private var timeText: String? {
        if let t = shop.deliveryTime, !t.isEmpty { return t }
        guard let m = shop.avgCookTime, m > 0 else { return nil }
        return "\(m) мин"
    }

    /// Паритет с Android: category в списках сервер не отдаёт — под названием
    /// показываем адрес заведения (так делает Android).
    private var subtitleText: String? {
        if let c = shop.category, !c.isEmpty { return c }
        if let a = shop.address, !a.isEmpty { return a }
        return nil
    }

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 0) {
                // ── Фото + оверлеи ──
                PhotoPlaceholder(url: photoURL, label: "ОБЛОЖКА", radius: 0, tone: tone)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .clipped()
                    // Закрытую организацию приглушаем (фото). Клик/сердечко остаются активны.
                    .opacity(isOpen ? 1 : 0.55)
                    .overlay(alignment: .topLeading) {
                        StatusPill(text: isOpen ? "Открыто" : "Закрыто",
                                   kind: isOpen ? .open : .cancel, solid: true)
                            .padding(12)
                    }
                    .overlay(alignment: .topTrailing) {
                        // В избранном → залитое красное сердечко.
                        HeartButton(isFav: $isFav, size: 32, favColor: YMColor.statusCancel).padding(11)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        if let t = timeText {
                            BlurInfoBadge(text: t).padding(12)
                        }
                    }
                    // Платное продвижение обязано быть помечено — этого на iOS
                    // не было вовсе: сервер отдаёт is_promoted, а бейджа не
                    // рисовал никто (на Android и на сайте он есть).
                    .overlay(alignment: .bottomLeading) {
                        if (shop.isPromoted ?? 0) == 1 {
                            Text("Реклама")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.black.opacity(0.55), in: Capsule())
                                .padding(12)
                        }
                    }

                // ── Текстовый блок ──
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(shop.name ?? "—")
                            .font(.system(size: 17, weight: .heavy))
                            .foregroundStyle(YMColor.text)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let r = shop.rating, r > 0 {
                            HStack(spacing: 4) {
                                Text("★").foregroundStyle(YMColor.accent)
                                Text(String(format: "%.1f", r)).foregroundStyle(YMColor.text)
                            }
                            .font(.system(size: 13.5, weight: .bold))
                        }
                    }
                    if let cuisine = subtitleText {
                        Text(cuisine)
                            .font(.system(size: 13))
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        if let price = priceLine {
                            Text(price)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(YMColor.accent)
                            Circle().fill(YMColor.muted).frame(width: 3, height: 3)
                        }
                        if let fulfillment = fulfillmentText {
                            Text(fulfillment)
                                .font(.system(size: 12.5))
                                .foregroundStyle(YMColor.muted)
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 15)
                .padding(.top, 13)
                .padding(.bottom, 15)
                .opacity(isOpen ? 1 : 0.55)   // текст закрытой организации тоже тусклый
            }
        }
        .buttonStyle(CardPressStyle())
        .ymCard(radius: YMRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(shop.name ?? "Организация"), \(isOpen ? "открыто" : "закрыто")")
    }
}

// MARK: - PopularCard (компактная карточка «Популярное в городе»)

/// Компактная карточка карусели «Популярное в городе» (146pt):
/// фото 104pt, бейдж рейтинга на blur, ♡, название/тег.
struct PopularCard: View {
    let title: String
    var tag: String? = nil
    var rating: Double? = nil
    var photoURL: URL? = nil
    var tone: Int = 0
    /// Паритет с Android: цена товара под названием (золотом). nil — без строки.
    var priceText: String? = nil
    @Binding var isFav: Bool
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: { Haptics.light(); onTap() }) {
            VStack(alignment: .leading, spacing: 8) {
                // Подпись видна без фото: «· БЛЮДО» из макета неверно у товаров магазина.
                PhotoPlaceholder(url: photoURL, label: "ФОТО", radius: YMRadius.card, tone: tone)
                    .frame(width: 146, height: 104)
                    .overlay(alignment: .topLeading) {
                        if let r = rating, r > 0 {
                            RatingBadge(rating: r).padding(8)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        // В избранном → залитое красное сердечко.
                        HeartButton(isFav: $isFav, size: 26, favColor: YMColor.statusCancel).padding(7)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(YMColor.text)
                        .lineLimit(1)
                    if let tag, !tag.isEmpty {
                        Text(tag)
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                            .lineLimit(1)
                    }
                    if let priceText, !priceText.isEmpty {
                        Text(priceText)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(YMColor.accent)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: 146, alignment: .leading)
        }
        .buttonStyle(CardPressStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

// MARK: - Press style (scale, уважает Reduce Motion)

/// Мягкое нажатие карточки (scale). Отдельно от кнопок действий,
/// чтобы вся карточка реагировала как единый tap-таргет.
struct CardPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(YMMotion.adaptive(YMMotion.snappy, reduceMotion: reduceMotion),
                       value: configuration.isPressed)
    }
}
