import SwiftUI
import PhotosUI
import UIKit

//  ReviewFormExtras.swift
//  Форма отзыва о заказе: раздельные оценки и фото (до 5). Паритет с Android
//  (ui/screens/orders/ReviewPhotos.kt + ReviewBlock). Контракт не менялся:
//  POST api/v1/reviews {order_id, rating, rating_food?, rating_delivery?, rating_service?, text?, photos?[]}.

/// Фото к отзыву: JPEG (длинная сторона ≤ 1600 px, качество 80 %, EXIF-поворот «впечён») + миниатюра.
struct ReviewPhoto: Identifiable {
    static let maxCount = 5
    let id = UUID()
    let jpeg: Data
    let thumb: UIImage

    /// Вызывать вне главного потока. nil — файл не прочитался.
    static func make(from raw: Data) -> ReviewPhoto? {
        guard let j = ImageUpload.jpeg(from: raw, maxSide: 1600, quality: 0.8), j.count >= 200,
              let full = UIImage(data: j) else { return nil }
        let t = full.preparingThumbnail(of: CGSize(width: 216, height: 216)) ?? full
        return ReviewPhoto(jpeg: j, thumb: t)
    }
}

/// Ряд звёзд 1–5. clearable: повторное нажатие на выбранную снимает оценку (0).
struct ReviewStarsRow: View {
    let label: String
    @Binding var value: Int
    var size: CGFloat = 24
    var clearable = true
    var disabled = false

    var body: some View {
        HStack(spacing: YMSpace.sm) {
            ForEach(1...5, id: \.self) { i in
                Button {
                    Haptics.light()
                    value = (clearable && value == i) ? 0 : i
                } label: {
                    Image(systemName: i <= value ? "star.fill" : "star")
                        .font(.system(size: size))
                        .foregroundStyle(i <= value ? YMColor.accent : YMColor.hairline)
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel("\(label): \(i) из 5")
                .accessibilityAddTraits(i == value ? .isSelected : [])
            }
        }
    }
}

/// Выбор фото (PhotosPicker, iOS 16+) + миниатюры с крестиком + счётчик «3 из 5».
struct ReviewPhotosField: View {
    @Binding var photos: [ReviewPhoto]
    var busy: Bool
    var onUnreadable: () -> Void

    @State private var picked: [PhotosPickerItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.sm) {
                        ForEach(Array(photos.enumerated()), id: \.element.id) { idx, p in
                            ZStack(alignment: .topTrailing) {
                                Image(uiImage: p.thumb)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    .accessibilityHidden(true)
                                Button {
                                    Haptics.light()
                                    photos.removeAll { $0.id == p.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white, Color.black.opacity(0.7))
                                        .padding(2)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy)
                                .accessibilityLabel("Фото \(idx + 1), удалить")
                            }
                        }
                    }
                }
            }
            HStack(spacing: YMSpace.md) {
                PhotosPicker(selection: $picked,
                             maxSelectionCount: max(1, ReviewPhoto.maxCount - photos.count),
                             matching: .images) {
                    Label("Добавить фото", systemImage: "camera")
                        .font(YMFont.callout)
                }
                .disabled(busy || photos.count >= ReviewPhoto.maxCount)
                Text("\(photos.count) из \(ReviewPhoto.maxCount)")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
        }
        .onChange(of: picked) { items in
            guard !items.isEmpty else { return }
            Task { await add(items) }
        }
    }

    private func add(_ items: [PhotosPickerItem]) async {
        var unreadable = false
        for item in items {
            if photos.count >= ReviewPhoto.maxCount { break }
            guard let raw = try? await item.loadTransferable(type: Data.self) else { unreadable = true; continue }
            let made = await Task.detached(priority: .userInitiated) { ReviewPhoto.make(from: raw) }.value
            // Повторная проверка: пока фото грузилось, могли добавить другие (второй выбор в picker).
            if let made { if photos.count < ReviewPhoto.maxCount { photos.append(made) } } else { unreadable = true }
        }
        picked = []
        if unreadable { onUnreadable() }
    }
}
