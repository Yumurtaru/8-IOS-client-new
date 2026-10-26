//
//  AdDetailView.swift — карточка объявления
//
//  Телефон показывается ПО НАЖАТИЮ (POST api/v1/ads/{id}/contact): владелец
//  видит реальное число обращений, а номер не достаётся тем, кто просто листал.
//  Если владелец спрятал номер, в карточке его нет вовсе — только кнопка.
//

import SwiftUI

private let adReportReasons: [(String, String)] = [
    ("fraud", "Мошенничество"),
    ("prohibited", "Запрещённый товар"),
    ("spam", "Спам или реклама"),
    ("wrong_category", "Не та категория"),
    ("sold", "Уже продано"),
    ("other", "Другое"),
]

@MainActor
final class AdDetailViewModel: ObservableObject {
    @Published var ad: AdDetail?
    @Published var loading = true
    @Published var error: String?
    @Published var phone: String?
    @Published var favorite = false
    @Published var toast: String?

    func load(_ id: Int) async {
        do {
            let r = try await API.shared.ad(id)
            ad = r.ad
            favorite = r.ad?.favorite ?? false
            phone = r.ad?.contactPhone?.isEmpty == false ? r.ad?.contactPhone : nil
            error = nil
        } catch is CancellationError {
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Объявление не найдено"
        }
        loading = false
    }

    /// Запросы в полёте. Двойной тап «Показать телефон» засчитывал владельцу два
    /// обращения (сервер считает каждое), а двойной тап сердечка переключал
    /// избранное туда и обратно — в итоге ничего не менялось.
    private var phoneBusy = false
    private var favBusy = false

    func showPhone(_ id: Int) async {
        guard !phoneBusy else { return }
        phoneBusy = true
        defer { phoneBusy = false }
        // Причина отказа словами (нет связи, лимит 429, объявление снято): раньше
        // любой сбой показывался как «Телефон недоступен», и человек не повторял.
        do {
            let r = try await API.shared.adContact(id)
            if let p = r.phone, !p.isEmpty { phone = p } else { toast = "Телефон недоступен" }
        } catch is CancellationError {
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? "Телефон недоступен"
        }
    }

    func toggleFavorite(_ id: Int) async {
        guard !favBusy else { return }
        favBusy = true
        defer { favBusy = false }
        // Текст сервера/сети вместо одного общего «Не удалось…».
        do {
            let r = try await API.shared.adFavorite(id)
            favorite = r.favorite ?? favorite
        } catch is CancellationError {
        } catch {
            toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось изменить избранное"
        }
    }

    func report(_ id: Int, reason: String) async {
        do { try await API.shared.adReport(id, reason: reason, comment: nil); toast = "Жалоба отправлена, спасибо" }
        // Текст сервера («Вы уже жаловались…», лимит, сессия) вместо одного общего.
        catch { toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить жалобу" }
    }
}

struct AdDetailView: View {
    let adId: Int
    @StateObject private var vm = AdDetailViewModel()
    @State private var bigPhoto: String?
    @State private var showReport = false
    @State private var reason = adReportReasons[0].0
    @Environment(\.openURL) private var openURL
    /// Телефон, избранное и жалоба требуют входа (сервер отвечает 401). Гость
    /// раньше видел «Телефон недоступен» / «Не удалось…» и не знал, что надо войти.
    @State private var showAuth = false
    private func needsAuth() -> Bool {
        if Session.shared.isLoggedIn { return false }
        showAuth = true
        return true
    }

    var body: some View {
        Group {
            if vm.loading {
                AdsSkeletonView()
            } else if let a = vm.ad {
                content(a)
            } else {
                ErrorRetryView(message: vm.error ?? "Объявление не найдено") {
                    Task { vm.loading = true; await vm.load(adId) }
                }
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Объявление")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(adId) }
        .overlay(alignment: .bottom) {
            if let t = vm.toast {
                Text(t)
                    .font(YMFont.caption).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(YMColor.text.opacity(0.9), in: Capsule())
                    .padding(.bottom, YMSpace.lg)
                    // Свой таймер у каждого сообщения: таймер прежнего тоста гасил новый раньше срока.
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 2_500_000_000)
                        if !Task.isCancelled { vm.toast = nil }
                    }
            }
        }
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                // После входа перечитываем объявление: у гостя «В избранном»
                // всегда false, и первое нажатие сердечка снимало уже избранное.
                AuthView(onAuthed: { showAuth = false; Task { await vm.load(adId) } })
            }
            .environmentObject(Session.shared)
        }
        .confirmationDialog("Пожаловаться", isPresented: $showReport, titleVisibility: .visible) {
            ForEach(adReportReasons, id: \.0) { value, label in
                Button(label) { Task { await vm.report(adId, reason: value) } }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private func content(_ a: AdDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.md) {
                if (a.status ?? "active") != "active" {
                    Text("Это объявление сейчас не показывается в общей ленте.")
                        .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        .padding(YMSpace.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
                }

                let photos = a.photos ?? []
                ZStack {
                    Rectangle().fill(YMColor.surface2)
                    let shown = bigPhoto ?? photos.first?.full ?? photos.first?.card
                    if let u = API.imageURL(shown) {
                        CachedAsyncImage(url: u) { phase in
                            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fit) }
                            // П-19.2: файла нет (404) — заглушка, а не вечная крутилка.
                            else if case .failure = phase {
                                Image(systemName: "photo").font(.system(size: 44)).foregroundStyle(YMColor.muted)
                            }
                            else { ProgressView() }
                        }
                    } else {
                        Image(systemName: "photo").font(.system(size: 44)).foregroundStyle(YMColor.muted)
                    }
                }
                .frame(height: 280)
                .clipShape(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))

                if photos.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: YMSpace.sm) {
                            ForEach(photos) { p in
                                if let u = API.imageURL(p.thumb ?? p.card) {
                                    CachedAsyncImage(url: u) { phase in
                                        if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                        else { Rectangle().fill(YMColor.surface2) }
                                    }
                                    .frame(width: 64, height: 64)
                                    .clipShape(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                                    .onTapGesture { bigPhoto = p.full ?? p.card }
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(a.priceText ?? "").font(YMFont.largeTitle).foregroundStyle(YMColor.text)
                    Text(a.title ?? "").font(YMFont.title3).foregroundStyle(YMColor.text)
                    Text([
                        // Склонение: «1 просмотр», «3 просмотра» — раньше всегда «просмотров».
                        a.categoryName, a.city, LodgingDate.plural(a.viewsCount ?? 0, "просмотр", "просмотра", "просмотров"),
                    ].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "))
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }

                if let p = vm.phone {
                    Button {
                        let digits = p.filter { $0.isNumber || $0 == "+" }
                        if let u = URL(string: "tel://\(digits)") { openURL(u) }
                    } label: {
                        Label("Позвонить: \(p)", systemImage: "phone.fill")
                            .font(YMFont.headline).foregroundStyle(YMColor.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(YMColor.accent, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    }
                } else {
                    Button {
                        if needsAuth() { return }
                        Task { await vm.showPhone(adId) }
                    } label: {
                        Label("Показать телефон", systemImage: "phone.fill")
                            .font(YMFont.headline).foregroundStyle(YMColor.onAccent)
                            .frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(YMColor.accent, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                    }
                }

                HStack(spacing: YMSpace.md) {
                    Button {
                        if needsAuth() { return }
                        Task { await vm.toggleFavorite(adId) }
                    } label: {
                        Label(vm.favorite ? "В избранном" : "В избранное",
                              systemImage: vm.favorite ? "heart.fill" : "heart")
                            .font(YMFont.callout).foregroundStyle(YMColor.accent)
                    }
                    // На своё объявление сервер жалобу не заводит, но отвечает
                    // «отправлено» (routes/ads.php) — человек видел ложное «спасибо».
                    if a.isMine != true {
                        Button { if !needsAuth() { showReport = true } } label: {
                            Label("Пожаловаться", systemImage: "flag")
                                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        }
                    } else {
                        // Паритет с Android: у своего объявления — переход к управлению
                        // (продлить, снять, изменить), как «Управление» в Android.
                        NavigationLink { MyAdsView() } label: {
                            Text("Управление").font(YMFont.callout).foregroundStyle(YMColor.accent)
                        }
                    }
                    Spacer()
                }

                if let cond = a.conditionNew {
                    Text("Состояние: \(cond ? "новое" : "б/у")").font(YMFont.body).foregroundStyle(YMColor.text)
                }
                if let addr = a.address, !addr.isEmpty {
                    Text("Адрес: \(addr)").font(YMFont.body).foregroundStyle(YMColor.text)
                }

                Text("Описание").font(YMFont.title3).foregroundStyle(YMColor.text).padding(.top, YMSpace.sm)
                Text(a.description ?? "").font(YMFont.body).foregroundStyle(YMColor.text)

                Text("Продавец: \(a.author?.name?.isEmpty == false ? (a.author?.name ?? "") : "частное лицо")")
                    .font(YMFont.callout).foregroundStyle(YMColor.muted)
                    .padding(.top, YMSpace.sm)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.xxxl)
        }
    }
}
