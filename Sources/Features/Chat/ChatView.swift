import SwiftUI
import PhotosUI

//  ChatView.swift
//  Yumurta — premium iOS-клиент. Экран 7 — Чаты (list) и Переписка (chat).
//
//  Init-сигнатуры:
//    ChatView(list)              — экран списка чатов «Чаты».
//    ChatView(orderId: Int)      — переписка по конкретному заказу.
//
//  ВАЖНО: чат в этом API привязан к заказу (как в старом TrackView):
//    GET  api/v1/orders/{id}/chat[?after_id=N]  → [ChatMessage]  (инкрементально)
//    POST api/v1/orders/{id}/chat  body ["message": text]
//  Отдельного «списка всех чатов» сервер пока не отдаёт → список строим из активных заказов
//  (GET api/v1/orders) — 1:1 по данным, без выдуманных полей. TODO(API) помечены ниже.
//
//  Signature-язык: золото сквозное — бейдж непрочитанных, мои пузыри, кнопка отправки,
//  плашка привязки к заказу «№… · В пути» со статусной точкой.

// MARK: - Точка входа

extension ChatView {
    /// Экран списка чатов.
    static var list: ChatView { ChatView(mode: .list) }
}

struct ChatView: View {
    enum Mode: Equatable { case list; case chat(orderId: Int) }
    let mode: Mode

    /// Список чатов: ChatView(list) через static, либо ChatView(mode: .list).
    init(mode: Mode) { self.mode = mode }
    /// Переписка по заказу: ChatView(orderId:).
    init(orderId: Int) { self.mode = .chat(orderId: orderId) }

    var body: some View {
        switch mode {
        case .list:                 ChatListScreen()
        case .chat(let orderId):    ChatThreadScreen(orderId: orderId)
        }
    }
}

// MARK: - Список чатов (screen: list)

@MainActor
private final class ChatListViewModel: ObservableObject {
    @Published var dialogs: [ChatDialog] = []
    @Published var loading = true
    /// Не загрузилось — раньше без сети писали «Чатов пока нет».
    @Published var failed = false
    private var didLoad = false

    /// Первый вход — со скелетоном; возврат из переписки — тихое обновление:
    /// раньше список грузился один раз, и бейдж непрочитанных у только что
    /// прочитанного чата висел, пока шторку не закроют.
    func firstLoad() async {
        guard !didLoad else { await load(); return }
        didLoad = true; await load()
    }
    func load() async {
        loading = true
        // Реальный список диалогов: заказы с перепиской + последнее сообщение + непрочитанные.
        do {
            dialogs = try await API.shared.list("api/v1/chats")
            failed = false
        } catch is CancellationError {
        } catch {
            failed = true
        }
        loading = false
    }
}

private struct ChatListScreen: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = ChatListViewModel()
    @State private var query = ""

    private var filtered: [ChatDialog] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return vm.dialogs }
        let q = query.lowercased()
        // Паритет с Android: ищем и по номеру заказа («12» или «№12»), он виден в строке.
        var num = query.trimmingCharacters(in: .whitespaces)
        if num.hasPrefix("№") { num.removeFirst() }
        let numQ = num
        return vm.dialogs.filter { d in
            if (d.shopName ?? "").lowercased().contains(q) { return true }
            if numQ.isEmpty { return false }
            let shown = d.dailyNumber ?? d.orderId ?? 0
            return String(shown) == numQ
        }
    }

    // Без своего NavigationStack: список показывается в шторке, которая уже
    // обёрнута в NavigationStack (RootTabView). Стек в стеке ломал переход в
    // переписку и раздваивал панель навигации.
    var body: some View {
            ScrollView {
                VStack(spacing: YMSpace.md) {
                    SearchField(placeholder: "Поиск по чатам", text: $query, active: !query.isEmpty)
                        .padding(.horizontal, YMSpace.xl)
                        .padding(.top, YMSpace.xs)

                    content
                }
                .padding(.bottom, YMSpace.xxxl)
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Чаты")
            .navigationBarTitleDisplayMode(.large)
            // Гость: обновление жестом слало запрос без входа (401).
            .refreshable { if session.isLoggedIn { await vm.load() } }
            .task { if session.isLoggedIn { await vm.firstLoad() } }
            // Вошли прямо отсюда — список грузим сразу, а не после переоткрытия.
            .onChange(of: session.isLoggedIn) { logged in
                if logged { Task { await vm.firstLoad() } }
                // Сессия кончилась при открытом списке: диалоги прежнего аккаунта
                // оставались в памяти и показывались вошедшему следом, пока
                // грузился его собственный список.
                else { vm.dialogs = []; vm.failed = false }
            }
            .navigationDestination(for: Int.self) { ChatThreadScreen(orderId: $0) }
    }

    @ViewBuilder private var content: some View {
        if !session.isLoggedIn {
            // Раньше — тупик: «Войдите в аккаунт» без кнопки входа (гость
            // попадает сюда по 💬 в карточке заведения).
            VStack(spacing: YMSpace.lg) {
                emptyState(icon: "person.crop.circle.badge.questionmark",
                           title: "Войдите в аккаунт",
                           hint: "Чтобы переписываться с заведениями по заказам.")
                NavigationLink { AuthView() } label: { Text("Войти") }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .padding(.horizontal, YMSpace.xxxl)
            }
        } else if vm.loading && vm.dialogs.isEmpty {
            VStack(spacing: YMSpace.sm) {
                ForEach(0..<4, id: \.self) { _ in SkeletonBox().frame(height: 72) }
            }
            .padding(.horizontal, YMSpace.xl)
        } else if vm.failed && vm.dialogs.isEmpty {
            emptyState(icon: "wifi.exclamationmark",
                       title: "Не удалось загрузить чаты",
                       hint: "Проверьте интернет и потяните список вниз, чтобы обновить.")
        } else if filtered.isEmpty {
            emptyState(icon: "bubble.left.and.bubble.right",
                       title: query.isEmpty ? "Чатов пока нет" : "Ничего не найдено",
                       hint: query.isEmpty
                            ? "Оформите заказ — здесь появится переписка с заведением."
                            : "Попробуйте другой запрос.")
        } else {
            // Обновление не прошло, а список уже есть — раньше сбой был незаметен,
            // и непрочитанные/новые чаты просто не появлялись.
            if vm.failed && !vm.loading {
                Text("Не удалось обновить чаты. Потяните вниз, чтобы повторить.")
                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, YMSpace.xl)
            }
            VStack(spacing: 0) {
                ForEach(filtered) { dialog in
                    // Диалог без заказа открывал чат «заказа 0» и опрашивал 404.
                    if let oid = dialog.orderId, oid > 0 {
                        NavigationLink(value: oid) {
                            ChatListRow(dialog: dialog)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ChatListRow(dialog: dialog)
                    }
                    if dialog.id != filtered.last?.id {
                        Divider().overlay(YMColor.hairline).padding(.leading, 82)
                    }
                }
            }
            .padding(.vertical, YMSpace.xs)
            .ymCard(radius: YMRadius.card)
            .padding(.horizontal, YMSpace.xl)
        }
    }

    private func emptyState(icon: String, title: String, hint: String) -> some View {
        VStack(spacing: YMSpace.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                    .fill(YMColor.surface2).frame(width: 96, height: 96)
                Image(systemName: icon).font(.system(size: 38, weight: .semibold))
                    .foregroundStyle(YMColor.accent)
            }
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(hint).font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center).padding(.horizontal, YMSpace.xxxl)
        }
        .frame(maxWidth: .infinity).padding(.top, 64)
    }
}

/// Строка чата: лого 52, название, время последнего сообщения, превью, золотой бейдж непрочитанных.
private struct ChatListRow: View {
    let dialog: ChatDialog

    private var unread: Int { dialog.unreadCount ?? 0 }
    /// Превью: последнее сообщение, либо «📷 Фото» для вложения, либо заглушка.
    private var preview: String {
        if let m = dialog.lastMessage, !m.isEmpty { return m }
        if !((dialog.lastAttachment ?? "").isEmpty) { return "📷 Фото" }
        return "Нет сообщений"
    }

    var body: some View {
        HStack(spacing: YMSpace.md) {
            LogoBadge(url: API.imageURL(dialog.shopLogo),
                      letter: (dialog.shopName ?? "?").prefix(1).uppercased(),
                      size: 52)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(dialog.shopName ?? "Заведение")
                        .font(.system(size: 15.5, weight: .bold)).foregroundStyle(YMColor.text)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    // Паритет с Android: номер заказа — два заказа в одном заведении
                    // давали две одинаковые строки, и было не понять, какой чат о каком.
                    if let n = dialog.dailyNumber ?? dialog.orderId, n > 0 {
                        Text("№\(n)")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    }
                    // Не только время: «14:05» у переписки недельной давности читалось как сегодня.
                    Text(DateFmt.listTime(dialog.lastAt))
                        .font(YMFont.caption).foregroundStyle(unread > 0 ? YMColor.accent : YMColor.muted)
                }
                HStack(spacing: YMSpace.sm) {
                    Text(preview)
                        .font(.system(size: 13, weight: unread > 0 ? .semibold : .regular))
                        .foregroundStyle(unread > 0 ? YMColor.text : YMColor.muted)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if unread > 0 {
                        Text("\(unread)")
                            .font(.system(size: 11, weight: .heavy)).foregroundStyle(YMColor.onAccent)
                            .frame(minWidth: 20, minHeight: 20).padding(.horizontal, 5)
                            .background(YMColor.accent, in: Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.md)
        .contentShape(Rectangle())
    }
}

// MARK: - Переписка (screen: chat)

@MainActor
private final class ChatThreadViewModel: ObservableObject {
    let orderId: Int
    @Published var order: OrderDetail?
    @Published var track: TrackData?
    @Published var messages: [ChatMessage] = []
    @Published var loading = true
    @Published var sending = false
    @Published var sendError: String?
    /// История не загрузилась. Раньше сбой сети выглядел как пустой чат
    /// («Напишите первое сообщение»), хотя переписка была.
    @Published var historyFailed = false

    private var lastChatId = 0
    private var pollTimer: Timer?

    init(orderId: Int) { self.orderId = orderId }

    func initialLoad() async {
        loading = true
        // Трек курьера экран чата не показывает — лишний запрос на каждое
        // открытие переписки убран (track остаётся пустым, как и был не нужен).
        async let o: OrderDetail? = try? await API.shared.get("api/v1/orders/\(orderId)")
        // Повторный показ (возврат со входа) при сбое не стирает уже известный заказ.
        if let fresh = await o { order = fresh }
        await fetchNew()
        loading = false
    }

    /// Инкрементальная подгрузка: первый запрос — вся история, дальше только after_id=N.
    /// false — запрос не прошёл (флаг historyFailed выставлен).
    /// Запрос истории в полёте — опрос не ставит следующий поверх (см. startPolling).
    private var fetching = false

    @discardableResult
    func fetchNew() async -> Bool {
        fetching = true
        defer { fetching = false }
        let path = lastChatId > 0
            ? "api/v1/orders/\(orderId)/chat?after_id=\(lastChatId)"
            : "api/v1/orders/\(orderId)/chat"
        let batch: [ChatMessage]
        do { batch = try await API.shared.list(path) }
        catch is CancellationError { return false }
        catch {
            if lastChatId == 0 { historyFailed = true }
            return false
        }
        historyFailed = false
        guard !batch.isEmpty else { return true }
        if lastChatId == 0 {
            // Локальные фото «отправляется/ошибка» не стираем первой порцией
            // истории — раньше неудачное фото пропадало без следа.
            messages = batch + messages.filter { $0.localState != nil }
        } else {
            // Опрос раз в 6 с и дозапрос после отправки могут уйти с одним и тем
            // же after_id — без фильтра сообщение задваивалось (и одинаковые id
            // ломали ForEach). Так уже сделано в Android-клиенте и iOS-продавце.
            let known = Set(messages.compactMap { $0.id })
            messages.append(contentsOf: batch.filter { m in m.id.map { !known.contains($0) } ?? true })
        }
        lastChatId = max(lastChatId, batch.compactMap { $0.id }.max() ?? 0)
        return true
    }

    func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // На медленной сети запрос (с повторами) длится дольше 6 с: раньше
                // каждый тик ставил ещё один, и они копились десятками.
                guard let self, !self.fetching else { return }
                await self.fetchNew()
            }
        }
    }
    func stopPolling() { pollTimer?.invalidate(); pollTimer = nil }

    /// true — отправлено. Раньше ошибка (сеть, лимит, 404) глушилась try?,
    /// а текст уже был стёрт из поля — сообщение пропадало без следа.
    @discardableResult
    func send(_ text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        sending = true; defer { sending = false }
        do {
            try await API.shared.postVoid("api/v1/orders/\(orderId)/chat", body: ["message": trimmed])
        } catch {
            sendError = (error as? LocalizedError)?.errorDescription ?? "Сообщение не отправлено"
            return false
        }
        sendError = nil
        await fetchNew()
        return true
    }

    /// Отправка фото с оптимистичным превью (localImage) + статусом «отправляется/ошибка».
    func sendPhoto(_ data: Data) async {
        let tempStamp = "local-\(UUID().uuidString)"
        let temp = ChatMessage(id: nil, message: nil, sender: "client", createdAt: tempStamp,
                               mine: true, attachment: nil, read: false, senderName: nil,
                               localState: "sending", localImage: data)
        messages.append(temp)
        sending = true; defer { sending = false }
        do {
            _ = try await API.shared.uploadChatPhoto(orderId: orderId, jpeg: data)
            messages.removeAll { $0.stableId == temp.stableId }
            await fetchNew()
        } catch {
            if let i = messages.firstIndex(where: { $0.stableId == temp.stableId }) {
                messages[i].localState = "failed"
            }
            // Причину говорим словами: раньше был только красный значок у фото,
            // и было непонятно — большой файл, нет связи или кончилась сессия.
            if !(error is CancellationError) {
                sendError = "Фото не отправлено: " + ((error as? LocalizedError)?.errorDescription ?? "попробуйте ещё раз")
            }
        }
    }
}

private struct ChatThreadScreen: View {
    let orderId: Int
    @EnvironmentObject private var session: Session
    @StateObject private var vm: ChatThreadViewModel
    @State private var draft = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @Environment(\.scenePhase) private var scenePhase
    /// Переписка на экране (для паузы опроса в фоне).
    @State private var visible = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(orderId: Int) {
        self.orderId = orderId
        _vm = StateObject(wrappedValue: ChatThreadViewModel(orderId: orderId))
    }

    var body: some View {
        Group {
            // Без входа (push о чате после выхода, сессия кончилась посреди
            // переписки) история отвечала 401: экран писал «Проверьте связь»,
            // а опрос раз в 6 с продолжал слать запросы. Теперь — вход;
            // после него переписка грузится заново, набранный текст остаётся.
            if session.isLoggedIn {
                VStack(spacing: 0) {
                    orderLinkPlate
                    Divider().overlay(YMColor.hairline)
                    messagesList
                    inputBar
                }
                .task { await vm.initialLoad(); if !Task.isCancelled { vm.startPolling() } }   // экран успели закрыть — опрос не запускаем
                .onAppear { visible = true }
                .onDisappear { visible = false; vm.stopPolling() }
            } else {
                VStack(spacing: YMSpace.lg) {
                    Text("Войдите, чтобы переписываться с заведением по заказу.")
                        .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        .multilineTextAlignment(.center)
                    NavigationLink { AuthView() } label: { Text("Войти") }
                        .buttonStyle(YMPrimaryButtonStyle())
                        .padding(.horizontal, YMSpace.xxxl)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, YMSpace.xl)
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .principal) { headerTitle } }
        // Чат открыт шторкой: долистал историю до верха, потянул ещё — шторка
        // закрывалась вместе с набранным сообщением. Пока в поле есть текст,
        // закрываем только кнопкой «Закрыть».
        .interactiveDismissDisabled(!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Свернули приложение — опрос не нужен; вернулись — сразу дозапрашиваем
        // новые сообщения, а не ждём до 6 с следующего тика.
        .onChange(of: scenePhase) { phase in
            guard visible, session.isLoggedIn else { return }
            if phase == .active {
                vm.startPolling()
                Task { await vm.fetchNew() }
            } else if phase == .background {
                vm.stopPolling()
            }
        }
        // Push о новом сообщении по ЭТОМУ заказу при открытой переписке:
        // дозапрашиваем сразу, а не ждём до 6 с следующего тика опроса.
        .onReceive(NotificationCenter.default.publisher(for: .ymOrderPushed)) { n in
            guard (n.object as? Int) == orderId, visible, session.isLoggedIn else { return }
            Task { await vm.fetchNew() }
        }
        // Ссылки в сообщениях: заведение yumurta.ru/shop/… — экран в приложении,
        // остальное — браузер/система (раньше ссылки в чате не нажимались вовсе).
        .environment(\.openURL, OpenURLAction { url in ChatLinks.open(url) })
    }

    // Шапка: лого + «● онлайн · обычно отвечает за 2 мин»
    private var headerTitle: some View {
        HStack(spacing: YMSpace.sm) {
            LogoBadge(url: API.imageURL(vm.order?.shopName == nil ? nil : nil),
                      letter: (vm.order?.shopName ?? "?").prefix(1).uppercased(),
                      size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(vm.order?.shopName ?? "Чат")
                    .font(.system(size: 15.5, weight: .bold)).foregroundStyle(YMColor.text)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("●").font(.system(size: 9)).foregroundStyle(YMColor.statusDone)
                    Text("онлайн · обычно отвечает за 2 мин")
                        .font(.system(size: 11)).foregroundStyle(YMColor.muted)
                }
            }
        }
    }

    // Плашка привязки к заказу «№… · В пути» + состав·сумма
    private var orderLinkPlate: some View {
        HStack(spacing: YMSpace.sm) {
            StatusDot(color: OrderFlow.color(vm.order?.status),
                      pulsing: OrderFlow.isEnRoute(vm.order?.status), size: 6)
            VStack(alignment: .leading, spacing: 1) {
                // Подпись сервера (status_title) — для кодов, которых нет в словаре:
                // раньше здесь мог показаться код латиницей (как в списке и детали — уже нет).
                Text("Заказ №\(vm.order?.dailyNumber ?? orderId) · \(OrderStatus.label(vm.order?.status, shopType: vm.order?.shopType, title: vm.order?.statusTitle))")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(YMColor.text)
                if let o = vm.order {
                    Text("\(o.items?.count ?? 0) поз. · \(Money.format(Money.parse(o.total)))")
                        .font(.system(size: 11.5)).foregroundStyle(YMColor.muted)
                }
            }
            Spacer()
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.md)
        .background(YMColor.surface)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: YMSpace.sm) {
                    if vm.loading && vm.messages.isEmpty {
                        ForEach(0..<3, id: \.self) { _ in SkeletonBox().frame(height: 40) }
                            .padding(.horizontal, YMSpace.lg)
                    } else if vm.messages.isEmpty && vm.historyFailed {
                        VStack(spacing: YMSpace.sm) {
                            Text("Не удалось загрузить переписку. Проверьте связь.")
                                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                                .multilineTextAlignment(.center)
                            Button("Повторить") { Task { await vm.fetchNew() } }
                                .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                        }
                        .padding(.top, 48)
                    } else if vm.messages.isEmpty {
                        Text("Напишите первое сообщение заведению")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted)
                            .padding(.top, 48)
                    } else {
                        ForEach(Array(vm.messages.enumerated()), id: \.element.stableId) { idx, m in
                            if let sep = daySeparator(before: idx) { dateChip(sep) }
                            ChatBubble(message: m).id(m.stableId)
                        }
                    }
                }
                .padding(.horizontal, YMSpace.lg)
                .padding(.vertical, YMSpace.md)
            }
            // Поле многострочное: «Ввод» — это новая строка, и клавиатуру было
            // не убрать вовсе — она закрывала половину переписки. Теперь жестом.
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: vm.messages.count) { _ in
                guard let last = vm.messages.last else { return }
                withAnimation(YMMotion.adaptive(YMMotion.spring, reduceMotion: reduceMotion)) {
                    proxy.scrollTo(last.stableId, anchor: .bottom)
                }
            }
        }
    }

    // Поле ввода + вложение (+фото) + золотая кнопка отправки
    private var inputBar: some View {
        HStack(spacing: YMSpace.sm) {
            PhotosPicker(selection: $photoItems, maxSelectionCount: 1, matching: .images) {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold)).foregroundStyle(YMColor.muted)
                    .frame(width: 40, height: 40)
                    .background(YMColor.surface2, in: Circle())
            }
            .accessibilityLabel("Прикрепить фото")

            HStack {
                TextField("Сообщение…", text: $draft, axis: .vertical)
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                    .lineLimit(1...4)
                    // Сервер молча обрезает сообщение до 1000 символов
                    // (POST orders/{id}/chat, api_v1.php) — хвост пропадал без следа.
                    .ymMaxLength($draft, 1000)
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))

            Button {
                let text = draft; draft = ""
                // Не отправилось — возвращаем текст в поле. Если человек уже начал
                // новое сообщение, не затираем его, а ставим неотправленное перед ним.
                Task { if !(await vm.send(text)) { draft = draft.isEmpty ? text : text + "\n" + draft } }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 18, weight: .heavy)).foregroundStyle(YMColor.onAccent)
                    .frame(width: 40, height: 40)
                    .background(YMColor.accent, in: Circle())
                    .shadow(color: YMPalette.gold.opacity(0.5), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.sending)
            .opacity(draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
            .accessibilityLabel("Отправить")
        }
        .padding(.horizontal, YMSpace.lg)
        .padding(.vertical, YMSpace.sm)
        .background(.ultraThinMaterial)
        .alert(vm.sendError ?? "", isPresented: Binding(
            get: { vm.sendError != nil },
            set: { if !$0 { vm.sendError = nil } }
        // «Понятно», как в остальных окнах приложения, а не английское «OK».
        )) { Button("Понятно", role: .cancel) {} }
        .onChange(of: photoItems) { _ in
            guard let item = photoItems.first else { return }
            Task {
                if let raw = try? await item.loadTransferable(type: Data.self) {
                    // HEIC с камеры сервер не принимает — отправляем JPEG.
                    // Перекодирование — не на главном потоке (экран замирал).
                    let jpeg = await Task.detached(priority: .userInitiated) { ImageUpload.jpeg(from: raw) ?? raw }.value
                    await vm.sendPhoto(jpeg)
                } else {
                    // Фото не открылось (iCloud без сети, недоступный формат) —
                    // раньше выбор просто молча пропадал.
                    vm.sendError = "Не удалось открыть фото. Попробуйте ещё раз или выберите другое."
                }
                photoItems = []
            }
        }
    }

    // MARK: Разделители дат

    /// Метка-разделитель перед сообщением idx, если день отличается от предыдущего.
    private func daySeparator(before idx: Int) -> String? {
        guard idx < vm.messages.count, let d = chatDate(vm.messages[idx].createdAt) else { return nil }
        if idx == 0 { return dayLabel(d) }
        guard let prev = chatDate(vm.messages[idx - 1].createdAt) else { return dayLabel(d) }
        return Calendar.current.isDate(d, inSameDayAs: prev) ? nil : dayLabel(d)
    }

    private func dateChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(YMColor.muted)
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(YMColor.surface2, in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
    }

    /// Парсинг серверного времени: MySQL datetime "yyyy-MM-dd HH:mm:ss" или ISO8601.
    private func chatDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty, !s.hasPrefix("local-") else { return nil }
        return ChatFmt.server.date(from: s) ?? ChatFmt.iso.date(from: s)
    }

    private func dayLabel(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Сегодня" }
        if cal.isDateInYesterday(date) { return "Вчера" }
        let f = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? ChatFmt.day : ChatFmt.dayYear
        return f.string(from: date)
    }
}

/// Форматтеры чата — один раз на приложение: раньше каждый пузырь при каждой
/// перерисовке создавал по два-три DateFormatter (это дорого), лента дёргалась.
private enum ChatFmt {
    static let server: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Moscow")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    static let iso = ISO8601DateFormatter()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .autoupdatingCurrent; f.dateFormat = "d MMMM"; return f
    }()
    static let dayYear: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU")
        f.timeZone = .autoupdatingCurrent; f.dateFormat = "d MMMM yyyy"; return f
    }()
}

// MARK: - Ссылки в сообщениях

/// Ссылки в тексте чата. Раньше текст был простым Text: ссылку от заведения
/// (меню, оплата, страница на yumurta.ru) нельзя было открыть — только
/// перепечатать вручную.
private enum ChatLinks {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Текст сообщения с нажимаемыми ссылками (подчёркнуты).
    static func linked(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        guard let detector, text.contains(".") else { return out }
        let all = NSRange(text.startIndex..., in: text)
        for m in detector.matches(in: text, options: [], range: all) {
            // Только веб-ссылки: mailto:, tg: и прочие схемы детектор тоже
            // находит, а открывать их из чата не нужно.
            guard let url = m.url, ["http", "https"].contains((url.scheme ?? "").lowercased()),
                  let sr = Range(m.range, in: text),
                  let ar = Range<AttributedString.Index>(sr, in: out) else { continue }
            out[ar][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
            out[ar][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
        }
        return out
    }

    /// Заведение на yumurta.ru (или yumurta://shop/…) — экран в приложении,
    /// как по ссылке снаружи; прочие http(s) — браузер, другие схемы — нет.
    static func open(_ url: URL) -> OpenURLAction.Result {
        if isOwnShopLink(url), DeepLinkRouter.shared.handle(url: url) { return .handled }
        let scheme = (url.scheme ?? "").lowercased()
        return scheme == "http" || scheme == "https" ? .systemAction : .discarded
    }

    /// Только свой домен: DeepLinkRouter хост не проверяет, и чужая ссылка
    /// вида …/shop/x открыла бы «заведение x» вместо сайта.
    private static func isOwnShopLink(_ url: URL) -> Bool {
        let scheme = (url.scheme ?? "").lowercased()
        let host = (url.host ?? "").lowercased()
        if scheme == "yumurta" { return host == "shop" }
        guard scheme == "https" || scheme == "http",
              host == "yumurta.ru" || host == "www.yumurta.ru" else { return false }
        let parts = url.pathComponents.filter { $0 != "/" }
        return parts.count >= 2 && parts[0] == "shop"
    }
}

// MARK: - ChatBubble (пузырь сообщения)

/// Пузырь сообщения. Мои — золотые (радиус 16/16/4/16, тики ✓✓), их — surface.
/// Появление — ym-in (fade + slide), деградирует при Reduce Motion.
private struct ChatBubble: View {
    let message: ChatMessage

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    /// «Моё» сообщение — из серверного поля mine (fallback на строку sender для совместимости).
    private var mine: Bool {
        if let m = message.mine { return m }
        let s = (message.sender ?? "").lowercased()
        return s == "client" || s == "customer" || s == "me" || s == "user"
    }
    private var hasText: Bool { !((message.message ?? "").isEmpty) }
    private var hasImage: Bool { message.localImage != nil || !((message.attachment ?? "").isEmpty) }

    // Асимметричные углы: мои 16/16/4/16, их 16/16/16/4.
    private var corners: RoundedCorner {
        mine ? RoundedCorner(tl: 16, tr: 16, bl: 16, br: 4)
             : RoundedCorner(tl: 16, tr: 16, bl: 4, br: 16)
    }

    var body: some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                VStack(alignment: .leading, spacing: 6) {
                    if hasImage { bubbleImage }
                    if hasText {
                        // Ссылки в тексте нажимаются (подчёркнуты, цвет — tint).
                        Text(ChatLinks.linked(message.message ?? ""))
                            .font(YMFont.body)
                            .foregroundStyle(mine ? YMColor.onAccent : YMColor.text)
                            .tint(mine ? YMColor.onAccent : YMColor.accent)
                    }
                }
                .padding(hasImage ? 4 : 9)
                .padding(.horizontal, hasImage ? 0 : 4)
                .background(mine ? YMColor.accent : YMColor.surface)
                .clipShape(corners)
                .overlay(mine ? nil : corners.strokeBorder(YMColor.hairline, lineWidth: 1))

                HStack(spacing: 4) {
                    if mine, message.localState == "failed" {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10)).foregroundStyle(YMColor.statusCancel)
                    }
                    Text(DateFmt.time(message.createdAt))
                        .font(.system(size: 10.5)).foregroundStyle(YMColor.muted)
                    if mine, message.localState == "sending" {
                        Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(YMColor.muted)
                    } else if mine, message.localState == nil {
                        Text(message.read == true ? "✓✓" : "✓")
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(message.read == true ? YMColor.accent : YMColor.muted)
                    }
                }
            }
            if !mine { Spacer(minLength: 40) }
        }
        .opacity(appeared || reduceMotion ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 8)
        .onAppear {
            guard !reduceMotion else { appeared = true; return }
            withAnimation(.easeOut(duration: 0.28)) { appeared = true }
        }
    }

    /// Фото в пузыре: локальное превью (при отправке) или загрузка по URL.
    @ViewBuilder private var bubbleImage: some View {
        Group {
            if let data = message.localImage, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else if let url = API.imageURL(message.attachment) {
                CachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    case .failure:          ZStack { Color(.secondarySystemBackground); Image(systemName: "photo").foregroundStyle(YMColor.muted) }
                    default:                ZStack { Color(.secondarySystemBackground); ProgressView() }
                    }
                }
            }
        }
        .frame(width: 220, height: 220)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        // Та же причина, что и в PhotoPlaceholder: обрезка не сужает область
        // нажатия, её задаёт только contentShape.
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

// MARK: - RoundedCorner (асимметричные скругления пузырей)

/// Прямоугольник с индивидуальными радиусами углов (для пузырей чата 16/16/4/16).
struct RoundedCorner: Shape, InsettableShape {
    var tl: CGFloat = 0, tr: CGFloat = 0, bl: CGFloat = 0, br: CGFloat = 0
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var p = Path()
        let (w, h) = (r.width, r.height)
        let tl = min(min(self.tl, h/2), w/2)
        let tr = min(min(self.tr, h/2), w/2)
        let bl = min(min(self.bl, h/2), w/2)
        let br = min(min(self.br, h/2), w/2)
        p.move(to: CGPoint(x: r.minX + tl, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - tr, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr,
                 startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - br))
        p.addArc(center: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br,
                 startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX + bl, y: r.maxY))
        p.addArc(center: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl,
                 startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + tl))
        p.addArc(center: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl,
                 startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var c = self; c.insetAmount += amount; return c
    }
}
