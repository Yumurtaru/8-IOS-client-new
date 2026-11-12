import SwiftUI

//  OftenBoughtRow.swift
//  П-72 п.6: блок «Вы часто берёте» на главной - recommendations.often_bought
//  (формат как popular: >= 2 заказа за 180 дней, <= 10, гостю пусто).
//  Кнопка «+» кладёт товар в корзину сразу, если у него нет добавок; иначе открывает
//  карточку (обязательные модификаторы выбираются там - проверка на клиенте).

struct OftenBoughtRow: View {
    let items: [CatalogItem]
    let onOpen: (Int) -> Void

    @State private var busyId: Int?

    var body: some View {
        if !items.isEmpty {
            VStack(spacing: 0) {
                SectionHeader(title: "Вы часто берёте", actionTitle: nil, action: nil)
                    .padding(.top, 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.md) {
                        ForEach(items, id: \.uid) { item in
                            card(item)
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, 4)
                }
            }
        }
    }

    private func card(_ item: CatalogItem) -> some View {
        Button {
            Haptics.light(); onOpen(item.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                PhotoPlaceholder(url: API.imageURL(item.photo), label: "ФОТО", radius: YMRadius.card, tone: item.id, fit: true)
                    .frame(width: 146, height: 104)
                    .overlay(alignment: .bottomTrailing) {
                        Button {
                            Task { await quickAdd(item) }
                        } label: {
                            ZStack {
                                Circle().fill(YMColor.accent)
                                if busyId == item.id {
                                    ProgressView().tint(YMColor.onAccent).scaleEffect(0.7)
                                } else {
                                    Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(YMColor.onAccent)
                                }
                            }
                            .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .padding(7)
                        .disabled(busyId != nil)
                        .accessibilityLabel("Добавить в корзину: \(item.name ?? "товар")")
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name ?? "—")
                        .ymFont(14, weight: .bold).foregroundStyle(YMColor.text).lineLimit(1)
                    if let tag = item.category ?? item.shopName, !tag.isEmpty {
                        Text(tag).ymFont(12).foregroundStyle(YMColor.muted).lineLimit(1)
                    }
                    Text(Money.format(Money.dec(item.price)))
                        .ymFont(13, weight: .bold).foregroundStyle(YMColor.accent).lineLimit(1)
                }
            }
            .frame(width: 146, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    @MainActor
    private func quickAdd(_ item: CatalogItem) async {
        guard busyId == nil else { return }
        busyId = item.id
        defer { busyId = nil }
        guard let d: ProductDetail = try? await API.shared.get("api/v1/products/\(item.id)", fresh: true),
              (d.modifierGroups ?? []).isEmpty,
              d.stopped != true, d.outOfStock != true, d.categoryOff != true,
              let shopId = d.shopId, shopId > 0 else {
            onOpen(item.id)   // добавки/стоп-лист/нет сети - решает карточка товара
            return
        }
        if Cart.shared.add(product: d, modifierIds: [], options: [], shopId: shopId, shopName: d.shopName) {
            Haptics.success()
        } else {
            // Корзина заблокирована оформлением или собрана в другом заведении -
            // карточка товара сама объяснит и предложит сменить магазин.
            Haptics.warning()
            onOpen(item.id)
        }
    }
}
