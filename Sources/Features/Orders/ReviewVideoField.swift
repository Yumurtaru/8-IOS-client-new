import SwiftUI
import PhotosUI
import AVFoundation
import AVKit
import UniformTypeIdentifiers

//  ReviewVideoField.swift
//  П-72 п.5: видео к отзыву и «понравилось / не понравилось» по блюдам.
//    POST api/v1/reviews/media (multipart, поле file; mp4/mov, <= 30 с, <= 50 МБ)
//         -> {media_id, kind:"video", url, poster|null, duration}
//    POST api/v1/reviews + media_ids:[int] (<= 3) + items:[{product_id, liked}] (только отмеченные)
//  Видео загружается сразу после выбора (media_id привязывается к отзыву при отправке).

/// Ответ POST api/v1/reviews/media.
struct ReviewMediaUploaded: Decodable {
    @LenientInt var mediaId: Int?
    let kind: String?
    let url: String?
    let poster: String?
    @LenientInt var duration: Int?
}

/// Элемент `items` отзыва. camelCase -> snake_case через API.encoder.
struct ReviewLikeItem: Encodable {
    let productId: Int
    let liked: Bool
}

/// Файл, выбранный в PhotosPicker (копия во временную папку приложения).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let dst = FileManager.default.temporaryDirectory
                .appendingPathComponent("review-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: received.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

@MainActor
final class ReviewExtras: ObservableObject {
    static let maxVideos = 3
    static let maxBytes = 50 * 1024 * 1024
    static let maxSeconds = 30.0

    struct Video: Identifiable {
        let id = UUID()
        var mediaId: Int?
        var thumb: UIImage?
        var uploading = true
    }

    @Published var videos: [Video] = []
    @Published var liked: [Int: Bool] = [:]
    @Published var error: String?

    var uploading: Bool { videos.contains { $0.uploading } }
    var mediaIds: [Int] { videos.compactMap { $0.mediaId } }
    /// Только отмеченные блюда.
    var likeItems: [ReviewLikeItem] {
        liked.keys.sorted().compactMap { pid in liked[pid].map { ReviewLikeItem(productId: pid, liked: $0) } }
    }

    func toggleLike(_ productId: Int, _ value: Bool) {
        Haptics.light()
        if liked[productId] == value { liked[productId] = nil } else { liked[productId] = value }
    }

    private var uploads: [UUID: Task<ReviewMediaUploaded, Error>] = [:]

    /// Крестик у видео: идущая загрузка отменяется, видео убирается.
    func remove(_ v: Video) {
        uploads[v.id]?.cancel()
        uploads[v.id] = nil
        videos.removeAll { $0.id == v.id }
    }

    func add(_ item: PhotosPickerItem) async {
        error = nil
        guard videos.count < Self.maxVideos else { error = "Не больше 3 видео"; return }
        guard let movie = try? await item.loadTransferable(type: PickedMovie.self) else {
            error = "Видео не удалось прочитать"; return
        }
        defer { try? FileManager.default.removeItem(at: movie.url) }
        let size = (try? FileManager.default.attributesOfItem(atPath: movie.url.path)[.size] as? Int) ?? 0
        if size > Self.maxBytes { error = "Видео больше 50 МБ"; return }
        if size <= 0 { error = "Видео не удалось прочитать"; return }
        let asset = AVURLAsset(url: movie.url)
        let seconds = ((try? await asset.load(.duration))?.seconds) ?? 0
        if seconds.isFinite, seconds > Self.maxSeconds + 0.5 { error = "Видео длиннее 30 секунд"; return }
        var thumb: UIImage?
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 360)
        if let cg = try? await gen.image(at: .zero).image { thumb = UIImage(cgImage: cg) }

        let entry = Video(mediaId: nil, thumb: thumb, uploading: true)
        videos.append(entry)
        let url = movie.url
        let task = Task { try await API.shared.uploadReviewMedia(fileURL: url) }
        uploads[entry.id] = task
        defer { uploads[entry.id] = nil }
        do {
            let r = try await task.value
            if let i = videos.firstIndex(where: { $0.id == entry.id }) {
                if let mid = r.mediaId, mid > 0 {
                    videos[i].mediaId = mid
                    videos[i].uploading = false
                } else {
                    videos.remove(at: i); error = "Сервер не принял видео"
                }
            }
        } catch is CancellationError {
            videos.removeAll { $0.id == entry.id }
        } catch {
            videos.removeAll { $0.id == entry.id }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить видео"
        }
    }
}

/// Блок формы отзыва: «Добавить видео» + «понравилось» по блюдам.
struct ReviewExtrasField: View {
    @ObservedObject var extras: ReviewExtras
    /// Блюда заказа: (product_id, название).
    let dishes: [(id: Int, name: String)]
    var busy: Bool

    @State private var picked: PhotosPickerItem?

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            if !dishes.isEmpty {
                Text("Что понравилось?").font(YMFont.callout).foregroundStyle(YMColor.text)
                ForEach(dishes, id: \.id) { d in
                    HStack(spacing: YMSpace.md) {
                        Text(d.name).font(YMFont.body).foregroundStyle(YMColor.text).lineLimit(2)
                        Spacer(minLength: 8)
                        Button { extras.toggleLike(d.id, true) } label: {
                            Image(systemName: extras.liked[d.id] == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .foregroundStyle(extras.liked[d.id] == true ? YMColor.accent : YMColor.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Понравилось: \(d.name)")
                        Button { extras.toggleLike(d.id, false) } label: {
                            Image(systemName: extras.liked[d.id] == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .foregroundStyle(extras.liked[d.id] == false ? YMColor.statusCancel : YMColor.muted)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Не понравилось: \(d.name)")
                    }
                    .disabled(busy)
                }
            }
            if !extras.videos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: YMSpace.sm) {
                        ForEach(extras.videos) { v in
                            ZStack(alignment: .topTrailing) {
                                ZStack {
                                    if let t = v.thumb {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else {
                                        YMColor.surface2
                                    }
                                    if v.uploading {
                                        ProgressView().tint(.white)
                                    } else {
                                        Image(systemName: "play.circle.fill")
                                            .font(.system(size: 26)).foregroundStyle(.white)
                                    }
                                }
                                .frame(width: 72, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                Button { extras.remove(v) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.white, Color.black.opacity(0.7))
                                        .padding(2)
                                }
                                .buttonStyle(.plain)
                                .disabled(busy && !v.uploading)
                                .accessibilityLabel(v.uploading ? "Отменить загрузку видео" : "Видео, удалить")
                            }
                        }
                    }
                }
            }
            HStack(spacing: YMSpace.md) {
                PhotosPicker(selection: $picked, matching: .videos) {
                    Label("Добавить видео", systemImage: "video")
                        .font(YMFont.callout)
                }
                .disabled(busy || extras.videos.count >= ReviewExtras.maxVideos)
                Text("\(extras.videos.count) из \(ReviewExtras.maxVideos) · до 30 с, до 50 МБ")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            if let e = extras.error {
                Text(e).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
            }
        }
        .onChange(of: picked) { item in
            guard let item else { return }
            Task { await extras.add(item); picked = nil }
        }
    }
}

// MARK: - Показ медиа отзыва

/// Видео из `media` отзыва: постер + ▶, тап открывает плеер. Фото (kind "photo") не повторяем —
/// они уже показываются в ленте `photos`.
struct ReviewMediaStrip: View {
    let media: [ReviewMedia]
    @State private var playing: URL?

    var body: some View {
        let videos = media.filter { $0.kind == "video" && !($0.url ?? "").isEmpty }
        if !videos.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(videos.enumerated()), id: \.offset) { _, m in
                        Button {
                            if let u = API.imageURL(m.url) { playing = u }
                        } label: {
                            ZStack {
                                PhotoPlaceholder(url: API.imageURL(m.poster), label: "ВИДЕО", radius: 12, tone: 1)
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 30)).foregroundStyle(.white)
                                    .shadow(radius: 2)
                            }
                            .frame(width: 84, height: 84)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Видео отзыва")
                    }
                }
            }
            .padding(.top, 10)
            .fullScreenCover(item: Binding(get: { playing.map { PlayableURL(url: $0) } },
                                           set: { if $0 == nil { playing = nil } })) { p in
                ZStack(alignment: .topTrailing) {
                    VideoPlayer(player: AVPlayer(url: p.url)).ignoresSafeArea()
                    Button { playing = nil } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 30)).foregroundStyle(.white, Color.black.opacity(0.6))
                            .padding()
                    }
                    .accessibilityLabel("Закрыть")
                }
            }
        }
    }
}

private struct PlayableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// «92 % рекомендуют» по `likes_percent` (nil — меньше 5 оценок, ничего не показываем).
enum LikesText {
    static func recommend(_ percent: Int?) -> String? {
        guard let p = percent, (0...100).contains(p) else { return nil }
        return "\(p) % рекомендуют"
    }
}
