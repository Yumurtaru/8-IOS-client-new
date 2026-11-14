import SwiftUI
import AVKit
import Network

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

/// Когда видео-обложку НЕ запускаем: «Энергосбережение», «Экономия данных» (сеть constrained),
/// «Уменьшить движение». Тогда остаётся постер/картинка. Паритет с Android.
@MainActor
final class CoverVideoPolicy {
    static let shared = CoverVideoPolicy()
    private(set) var dataSaver = false
    /// false, пока NWPathMonitor не дал первый путь: «неизвестно» - не играем.
    private(set) var known = false
    /// Вызывается один раз после первого пути - плееры, ждавшие, запускаются.
    var onKnown: [() -> Void] = []
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Как Android: «Экономия данных» или лимитная (мобильная/хотспот) сеть - видео не качаем.
            let constrained = path.isConstrained || path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.dataSaver = constrained
                if !self.known {
                    self.known = true
                    let cbs = self.onKnown
                    self.onKnown = []
                    cbs.forEach { $0() }
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "ru.marketplace.client.covervideo.path"))
    }
    var canPlay: Bool {
        known
            && !ProcessInfo.processInfo.isLowPowerModeEnabled
            && !UIAccessibility.isReduceMotionEnabled
            && !dataSaver
    }
}

/// Беззвучное видео по кругу (`cover_video`). Пока грузится, при ошибке и при запрете политики
/// (см. CoverVideoPolicy) показывается `poster` (cover_video_poster или прежняя картинка).
/// Пауза при уходе с экрана. Аудиосессию не захватываем: категория .ambient + mixWithOthers.
struct CoverVideoView<Poster: View>: View {
    let url: URL
    let poster: Poster
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?
    @State private var ready = false
    @State private var watch: Task<Void, Never>?
    @State private var visible = false

    init(url: URL, @ViewBuilder poster: () -> Poster) {
        self.url = url
        self.poster = poster()
    }

    var body: some View {
        ZStack {
            if let player {
                CoverPlayerLayer(player: player)
            }
            if !ready { poster }
        }
        .accessibilityHidden(true)   // декоративная обложка: VoiceOver её не читает
        .onAppear { visible = true; start() }
        .onDisappear {
            visible = false
            watch?.cancel()
            player?.pause()
        }
    }

    private func start() {
        guard visible else { return }   // ждал первого пути сети, а экран уже закрыли
        let policy = CoverVideoPolicy.shared
        if !policy.known {
            policy.onKnown.append { start() }
            return
        }
        guard policy.canPlay else { return }
        if player == nil {
            try? AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            let item = AVPlayerItem(url: url)
            let q = AVQueuePlayer()
            q.isMuted = true
            looper = AVPlayerLooper(player: q, templateItem: item)
            player = q
        }
        guard let q = player else { return }
        q.play()
        watch?.cancel()
        watch = Task { @MainActor in
            // Постер снимаем, когда пошёл кадр; ошибка/таймаут 20 с - постер остаётся.
            for _ in 0..<80 {
                if Task.isCancelled { return }
                if q.timeControlStatus == .playing { ready = true; return }
                if q.currentItem?.status == .failed { break }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            // Ошибка или таймаут: остановить и отпустить, чтобы невидимое видео не качало трафик.
            if !Task.isCancelled && !ready {
                q.pause()
                q.removeAllItems()
                looper = nil
            }
        }
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
