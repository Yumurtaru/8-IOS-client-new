import SwiftUI

//
//  OrderDoorInfo.swift — П-83 пп. 7, 9 в карточке заказа:
//  «Оставить у двери», «Получатель: имя, телефон», фото доставки (превью, тап — на весь экран).
//  Все поля необязательные: на старом сервере карточка не появляется.
//

enum OrderDoorInfo {
    /// Строки: «Оставить у двери» и «Получатель: имя, телефон» — только заданные.
    static func lines(leave: Bool?, name: String?, phone: String?) -> [String] {
        var out: [String] = []
        if leave == true { out.append("Оставить у двери") }
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let p = (phone ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [n, p].filter { !$0.isEmpty }
        if !parts.isEmpty { out.append("Получатель: " + parts.joined(separator: ", ")) }
        return out
    }
}

/// Карточка с пометками доставки и фото. Своя вью: полноэкранный показ фото не делит
/// модификатор с .sheet экрана заказа.
struct OrderDoorInfoCard: View {
    let order: OrderDetail
    @State private var fullPhoto = false

    private var lines: [String] {
        OrderDoorInfo.lines(leave: order.leaveAtDoor, name: order.recipientName, phone: order.recipientPhone)
    }
    private var photoURL: URL? {
        let raw = (order.deliveryPhotoUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : API.imageURL(raw)
    }

    var body: some View {
        if !lines.isEmpty || photoURL != nil {
            VStack(alignment: .leading, spacing: YMSpace.sm) {
                ForEach(lines, id: \.self) { l in
                    Text(l).font(YMFont.body).foregroundStyle(YMColor.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let url = photoURL {
                    Text("Фото доставки").font(YMFont.caption).foregroundStyle(YMColor.muted)
                    Button { fullPhoto = true } label: {
                        CachedAsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().scaledToFill()
                            case .failure:          ZStack { Color(.secondarySystemBackground); Image(systemName: "photo").foregroundStyle(YMColor.muted) }
                            default:                ZStack { Color(.secondarySystemBackground); ProgressView() }
                            }
                        }
                        .frame(maxWidth: .infinity).frame(height: 180)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Фото доставки, открыть на весь экран")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.lg)
            .ymCard(radius: YMForm.cardRadius)
            .fullScreenCover(isPresented: $fullPhoto) {
                if let url = photoURL { DeliveryPhotoFullScreen(url: url) { fullPhoto = false } }
            }
        }
    }
}

private struct DeliveryPhotoFullScreen: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            CachedAsyncImage(url: url) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure:          Image(systemName: "photo").foregroundStyle(Color.white)
                default:                ProgressView().tint(Color.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onTapGesture { onClose() }
            Button { onClose() } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 30))
                    .foregroundStyle(Color.white.opacity(0.9)).padding(16)
            }
            .accessibilityLabel("Закрыть")
        }
    }
}
