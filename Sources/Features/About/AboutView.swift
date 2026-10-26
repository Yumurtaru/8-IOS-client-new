//
//  AboutView.swift — «О Yumurta»: описание маркетплейса и его возможностей.
//  Открывается по тапу на промо-баннер Главной. Статический контент, без сети.
//  Токены — только YM. Light + dark. Русские литералы.
//

import SwiftUI

struct AboutView: View {
    private struct Feature: Identifiable {
        // Ключ — заголовок, а не UUID(): список пересоздаётся при каждой сборке
        // экрана, и новые UUID заставляли SwiftUI считать все строки новыми.
        var id: String { title }
        let icon: String; let title: String; let text: String
    }

    private let features: [Feature] = [
        Feature(icon: "bag.fill",            title: "Магазины, рестораны и услуги",
                text: "Все организации вашего города в одном приложении: продукты и товары, кафе и рестораны, услуги и запись на приём."),
        Feature(icon: "cart.fill",           title: "Заказы и доставка",
                text: "Собирайте корзину, оформляйте заказ, платите онлайн или при получении. Доставка и самовывоз — на выбор."),
        Feature(icon: "location.fill",       title: "Отслеживание в реальном времени",
                text: "Статусы заказа и путь курьера на карте — от подтверждения до вручения."),
        Feature(icon: "bubble.left.and.bubble.right.fill", title: "Чат с заведением",
                text: "Пишите продавцу прямо по заказу — текст и фото, со статусами прочтения."),
        Feature(icon: "calendar",            title: "Запись на услуги",
                text: "Выбирайте свободное время и записывайтесь к специалистам — парикмахерские, сервисы и другое."),
        Feature(icon: "star.fill",           title: "Бонусы и Yumurta Plus",
                text: "Копите баллы за заказы, применяйте промокоды и подписку Plus с расширенными привилегиями."),
        Feature(icon: "gift.fill",           title: "Рефералы и подарочные карты",
                text: "Приглашайте друзей и дарите подарочные карты — выгодно и удобно."),
        Feature(icon: "storefront.fill",     title: "Стать продавцом",
                text: "Свой магазин, ресторан или услуги? Подайте заявку прямо в приложении — без визита на сайт."),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.xl) {
                header

                VStack(alignment: .leading, spacing: YMSpace.md) {
                    ForEach(features) { f in
                        HStack(alignment: .top, spacing: YMSpace.md) {
                            Image(systemName: f.icon)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(YMColor.accent)
                                .frame(width: 40, height: 40)
                                .background(YMColor.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(f.title).font(YMFont.headline).foregroundStyle(YMColor.text)
                                Text(f.text).font(YMFont.callout).foregroundStyle(YMColor.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Text("Yumurta объединяет бизнес и покупателей вашего города в одном месте — быстро, удобно и с заботой о каждом заказе.")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, YMSpace.xs)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.md)
            .padding(.bottom, YMSpace.xxxl)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("О Yumurta")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(Color(hex: "#17171A"))
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(RadialGradient(colors: [YMPalette.gold.opacity(0.28), .clear], center: .topTrailing, startRadius: 8, endRadius: 260))
                VStack(alignment: .leading, spacing: 6) {
                    Text("YUMURTA")
                        .font(.system(size: 26, weight: .black)).tracking(2)
                        .foregroundStyle(Color(hex: "#F5EEDE"))
                    Text("Самый большой маркетплейс организаций вашего города")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(YMPalette.gold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))

            Text("Магазины, рестораны и услуги — заказы, доставка, запись и оплата в одном приложении.")
                .font(YMFont.body).foregroundStyle(YMColor.text)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, YMSpace.xs)
        }
    }
}
