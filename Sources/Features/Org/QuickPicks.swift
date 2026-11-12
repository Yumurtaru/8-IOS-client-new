import SwiftUI
import AVKit

//  QuickPicks.swift
//  Редизайн, этап 12 (ТЗ 5.3/5.5): быстрые подборки заведения и видео-обложка.
//  Только внешний вид: данные берутся из уже загруженного меню, запросов нет.

// MARK: - Подборка

enum QuickPick: String, CaseIterable, Identifiable {
    case hit, new, sugarFree, spicy, meatFree, halal, available
    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .hit: return "🔥"
        case .new: return "✨"
        case .sugarFree: return "🍃"
        case .spicy: return "🌶️"
        case .meatFree: return "🥗"
        case .halal: return "☪️"
        case .available: return "🛒"
        }
    }

    var title: String {
        switch self {
        case .hit: return "Хит"
        case .new: return "Новинка"
        case .sugarFree: return "Без сахара"
        case .spicy: return "Острое"
        case .meatFree: return "Без мяса"
        case .halal: return "Халяль"
        case .available: return "Можно заказать"
        }
    }

    /// Подходит ли позиция. Теги продавца сравниваем без регистра.
    func matches(_ p: Product) -> Bool {
        let tags = (p.tags ?? []).map { $0.lowercased() }
        func has(_ parts: String...) -> Bool {
            tags.contains { t in parts.contains { t.contains($0) } }
        }
        switch self {
        case .hit: return has("хит")
        case .new: return has("новинк", "новое")
        case .sugarFree: return has("без сахара")
        case .spicy: return has("остр")
        case .meatFree: return has("без мяса", "вегетариан", "веган")
        case .halal: return p.isHalal == true || has("халял")
        case .available: return p.stopped != true
        }
    }

    /// Только подборки, в которых есть хотя бы одна позиция.
    static func present(in products: [Product]) -> [QuickPick] {
        // «Можно заказать» — только когда часть меню недоступна (иначе дублирует всё меню).
        let someStopped = products.contains { $0.stopped == true }
        return allCases.filter { pick in
            if pick == .available && !someStopped { return false }
            return products.contains { pick.matches($0) }
        }
    }
}

// MARK: - Ряд карточек + лист

/// Ряд квадратных карточек «эмодзи + подпись». Тап открывает лист с плитками меню.
/// `.sheet` висит на самом ряду — на OrgView уже есть свой лист входа.
struct QuickPicksRow<Tile: View>: View {
    let products: [Product]
    @Binding var active: QuickPick?
    let tile: (Product) -> Tile

    var body: some View {
        let picks = QuickPick.present(in: products)
        if !picks.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: YMForm.cardGap) {
                    ForEach(picks) { pick in
                        Button {
                            Haptics.light()
                            active = pick
                        } label: {
                            VStack(spacing: 6) {
                                Text(pick.emoji).font(.system(size: 30))
                                Text(pick.title)
                                    .ymText(YMText.cardTitle)
                                    .foregroundStyle(YMUi.text)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .minimumScaleFactor(0.8)
                            }
                            .padding(6)
                            .frame(width: 88, height: 88)
                            .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMForm.cardRadius, style: .continuous))
                        }
                        .buttonStyle(CardPressStyle())
                        .accessibilityLabel("Подборка: \(pick.title)")
                    }
                }
                .padding(.vertical, 2)
            }
            .sheet(item: $active) { pick in
                pickSheet(pick)
            }
        }
    }

    private func pickSheet(_ pick: QuickPick) -> some View {
        let items = products.filter { pick.matches($0) }
        let rows: [[Product]] = stride(from: 0, to: items.count, by: 2).map { Array(items[$0..<min($0 + 2, items.count)]) }
        return ScrollView {
            VStack(spacing: YMForm.cardGap) {
                Text(pick.emoji).font(.system(size: 56)).padding(.top, 36)
                Text(pick.title)
                    .ymText(YMText.screenTitle)
                    .foregroundStyle(YMUi.text)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 8)
                ForEach(rows, id: \.first?.id) { row in
                    HStack(alignment: .top, spacing: YMForm.cardGap) {
                        ForEach(row) { p in
                            tile(p).frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if row.count == 1 { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, YMForm.screenPadding)
            .padding(.bottom, 24)
        }
        .background(YMUi.screenBg.ignoresSafeArea())
        .ymSheetChrome(onClose: { active = nil })
    }
}

// MARK: - Видео-обложка

/// Беззвучное видео по кругу. Пауза при уходе с экрана, при Reduce Motion не запускаем.
struct CoverVideoView: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        Group {
            if let player {
                CoverPlayerLayer(player: player)
            } else {
                Color.clear
            }
        }
        .onAppear {
            if player == nil {
                let item = AVPlayerItem(url: url)
                let q = AVQueuePlayer()
                q.isMuted = true
                looper = AVPlayerLooper(player: q, templateItem: item)
                player = q
            }
            player?.play()
        }
        .onDisappear { player?.pause() }
    }
}

private struct CoverPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspectFill
        return v
    }
    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        uiView.playerLayer.player = player
    }
    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
