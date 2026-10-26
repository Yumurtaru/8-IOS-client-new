//
//  AssistantView.swift — «Помощник Yumurta» (ИИ, волна сайта А100), audience client.
//
//  Вход: «Профиль» → «Поддержка» → «Спросить помощника» (кнопка есть, если сервер
//  ответил status.enabled = true или login_required = true — гостю здесь «Войти», А102;
//  старый сервер — 404 — кнопки нет).
//
//    AssistantView()   — самодостаточный экран, открывается NavigationLink из SupportView.
//
//  Модели, запросы, разбор ответа — AssistantModels.swift. Образец текстов и
//  поведения — веб-виджет assets/js/assistant.js. Паритет с Android:
//  ui/screens/assistant/AssistantScreen.kt.
//
//  • chat_id текущей переписки хранится на телефоне отдельно для каждого аккаунта
//    (UserDefaults «asst_chat_client_<id вошедшего>»); при входе на экран — история
//    с сервера, «Новый разговор» — забыть chat_id.
//  • Ответ идёт 10–30 с (ждём до 60 с): «Помощник печатает…», вторая отправка закрыта.
//  • 502 — «Помощник не ответил — попробуйте ещё раз», переписка остаётся (chat_id из
//    error.details.chat_id). 422/429/503 — текст сервера. 401 — выход, как во всём
//    приложении (Session → корень профиля); гостю — «Войти».
//  • Ссылки (только сайта) — во встроенном Safari (SafariSheet).
//  • VoiceOver: пузыри читаются «Вы: …» / «Помощник: …», ссылки — действиями.
//  • «Позвать человека» (А102): handoff {kind: "ticket", id} — ссылка «Открыть обращение»
//    (SupportTicketView); другой kind или без номера — «Открыть уведомления», как раньше.
//

import SwiftUI

/// Строка ленты. kind: user | bot | sys | err | handoff.
struct AsstItem: Identifiable {
    let id: Int
    let kind: String
    let text: String
    var msgId: Int? = nil
    var rating: Int? = nil
    var blocks: [MdBlock] = []
    /// (название, полный адрес) — статьи, на которые ответ опирался.
    var sources: [(String, String)] = []
    /// А102: handoff — номер обращения (kind = ticket), иначе nil.
    var ticketId: Int? = nil
}

@MainActor
final class AssistantVM: ObservableObject {
    @Published private(set) var status: AssistantStatus?
    @Published private(set) var loading = true
    @Published private(set) var loadError: String?
    @Published private(set) var busy = false
    @Published private(set) var handing = false
    @Published private(set) var leftToday: Int?
    @Published private(set) var items: [AsstItem] = []
    /// Вопрос, который сервер не принял (сеть, 422/429/503…): экран вернёт его в поле.
    @Published private(set) var returned: String?

    private(set) var chatId: String?
    private var seq = 0
    /// Для какого состояния входа загружено: вошёл/вышел — грузим заново.
    private var loadedFor: Bool?
    private var rating = Set<Int>()

    // ── chat_id на телефоне: свой у каждого аккаунта ──
    private var storeKey: String { "asst_chat_\(AssistantAPI.audience)_\(UserDefaults.standard.integer(forKey: AuthLastUser.key))" }
    private func savedChat() -> String? {
        guard let s = UserDefaults.standard.string(forKey: storeKey), !s.isEmpty else { return nil }
        return s
    }
    private func saveChat(_ id: String?) {
        chatId = id
        if let id, !id.isEmpty { UserDefaults.standard.set(id, forKey: storeKey) }
        else { UserDefaults.standard.removeObject(forKey: storeKey) }
    }

    func load(force: Bool = false) async {
        let logged = Session.shared.isLoggedIn
        // Уже загружено (или грузится) для этого состояния входа — повторно не просим.
        if !force, loadedFor == logged, status != nil || loading && loadedFor != nil { return }
        loadedFor = logged
        loading = true
        loadError = nil
        defer { loading = false }
        let s: AssistantStatus
        do { s = try await AssistantAPI.status() }
        catch is CancellationError { loadedFor = nil; return }
        catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Помощник сейчас недоступен. Попробуйте позже"
            return
        }
        status = s
        leftToday = s.leftToday
        items = []
        chatId = nil
        guard s.enabled == true, Session.shared.isLoggedIn, let saved = savedChat() else { return }
        do {
            let h = try await AssistantAPI.chat(id: saved)
            let msgs = h.messages ?? []
            if msgs.isEmpty { saveChat(nil); return }   // переписки больше нет — новая
            chatId = saved
            msgs.forEach(add)
            if h.chat?.status == "handed" { sys("Переписка передана сотруднику поддержки.") }
        } catch is CancellationError {
            // Ушли с экрана посреди загрузки — при возврате загрузим заново.
            chatId = saved
            loadedFor = nil
        } catch let e as APIError where e.rejectStatus == 404 {
            saveChat(nil)   // срок хранения, чужой аккаунт — начнём новую
        } catch {
            // Сбой связи: переписку не забываем — следующий вопрос продолжит её.
            chatId = saved
            err("Не удалось загрузить прошлую переписку. Можно задать вопрос — он продолжит её.")
        }
    }

    private func next() -> Int { seq += 1; return seq }

    private func add(_ m: AssistantMessage) {
        let text = m.text ?? ""
        if m.role == "user" {
            items.append(AsstItem(id: next(), kind: "user", text: text))
            return
        }
        let src: [(String, String)] = (m.sources ?? [])
            .filter { $0.cited != true }
            .compactMap { s -> (String, String)? in
                guard let u = AssistantMd.sourceURL(s.url, base: API.base) else { return nil }
                let t = (s.title ?? "").trimmingCharacters(in: .whitespaces)
                return (t.isEmpty ? AssistantMd.shortLabel(u) : t, u)
            }
        items.append(AsstItem(id: next(), kind: "bot", text: text, msgId: m.id, rating: m.rating,
                              blocks: AssistantMd.parse(text, base: API.base), sources: Array(src.prefix(2))))
    }

    private func sys(_ t: String) { items.append(AsstItem(id: next(), kind: "sys", text: t)) }
    private func err(_ t: String) { items.append(AsstItem(id: next(), kind: "err", text: t)) }

    /// Отправить вопрос. false — не ушёл (пусто, уже ждём ответ, гость).
    @discardableResult
    func ask(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // loading: история ещё грузится — вопрос ушёл бы без chat_id, а пришедшая
        // история потом перезаписала бы и chat_id, и ленту.
        guard !text.isEmpty, !busy, !loading, Session.shared.isLoggedIn else { return false }
        let max = (status?.maxLength ?? 0) > 0 ? (status?.maxLength ?? 2000) : 2000
        if AssistantText.length(text) > max {
            err("Слишком длинный вопрос — сократите до \(max) символов.")
            return false
        }
        busy = true
        let qId = next()
        items.append(AsstItem(id: qId, kind: "user", text: text))
        let cid = chatId
        // Сервер вопрос не сохранил (всё, кроме 502/504) — пузырь убираем, текст — в поле.
        func giveBack() {
            items.removeAll { $0.id == qId }
            returned = text
        }
        Task {
            defer { busy = false }
            do {
                let r = try await AssistantAPI.ask(chatId: cid, text: text)
                if let id = r.chatId, !id.isEmpty { saveChat(id) }
                if let reply = r.reply { add(reply) }
                leftToday = r.leftToday
                Haptics.light()
            } catch let f as AssistantFailure {
                if let id = f.chatId { saveChat(id) }
                if f.status == 404 { saveChat(nil) }
                // 429 бывает и от общего ограничителя частоты (rate:20/мин) — остаток
                // вопросов берём только из ответов status/messages, здесь не трогаем.
                if !AssistantText.keepQuestion(f.status) { giveBack() }
                err(f.message)
                Haptics.error()
            } catch is CancellationError {
                // экран закрыли — ответ сохранится на сервере и покажется при входе
            } catch {
                giveBack()   // сеть, таймаут, 401 — ответа сервера нет
                err((error as? LocalizedError)?.errorDescription ?? "Не получилось получить ответ. Повторите позже")
                Haptics.error()
            }
        }
        return true
    }

    /// 👍/👎: повторное нажатие той же оценки снимает её (rating 0).
    func rate(_ itemId: Int, _ value: Int) {
        guard let it = items.first(where: { $0.id == itemId }), let cid = chatId, let mid = it.msgId,
              rating.insert(itemId).inserted else { return }
        let nr = it.rating == value ? 0 : value
        Task {
            defer { rating.remove(itemId) }
            do {
                _ = try await AssistantAPI.rate(chatId: cid, messageId: mid, rating: nr)
                if let i = items.firstIndex(where: { $0.id == itemId }) { items[i].rating = nr == 0 ? nil : nr }
                Haptics.selection()
                if nr == -1 { sys("Спасибо, учтём. Если вопрос не решён — нажмите «Позвать человека».") }
            } catch is CancellationError {
            } catch {
                err((error as? LocalizedError)?.errorDescription ?? "Не удалось сохранить оценку")
            }
        }
    }

    var hasChat: Bool { chatId != nil }

    /// Забрать возвращённый вопрос (один раз).
    func takeReturned() -> String? { defer { returned = nil }; return returned }

    /// «Позвать человека»: покупателю — обращение в поддержку.
    func handoff() {
        guard let cid = chatId else {
            sys("Сначала опишите вопрос — переписку передадим сотруднику вместе с ним.")
            return
        }
        guard !handing else { return }
        handing = true
        Task {
            defer { handing = false }
            do {
                let h = try await AssistantAPI.handoff(chatId: cid)
                let tid = AssistantText.handoffTicket(kind: h.kind, id: h.id)
                items.append(AsstItem(id: next(), kind: "handoff",
                                      text: AssistantText.handoffText(already: h.already == true, id: h.id, ticket: tid != nil),
                                      ticketId: tid))
                Haptics.success()
            } catch is CancellationError {
            } catch {
                if (error as? APIError)?.rejectStatus == 404 { saveChat(nil) }
                err((error as? LocalizedError)?.errorDescription ?? "Не удалось передать — попробуйте ещё раз.")
                Haptics.error()
            }
        }
    }

    func newChat() {
        guard !busy, !loading else { return }
        saveChat(nil)
        items = []
    }
}

struct AssistantView: View {
    @StateObject private var vm = AssistantVM()
    @ObservedObject private var session = Session.shared
    @State private var draft = ""
    @State private var confirmHandoff = false
    /// Ссылка сайта — во встроенном Safari (тот же SafariSheet, что у оплаты).
    @State private var link: PayLink?

    private var maxLen: Int { (vm.status?.maxLength ?? 0) > 0 ? (vm.status?.maxLength ?? 2000) : 2000 }
    private var ready: Bool { vm.status?.enabled == true && session.isLoggedIn && !vm.loading }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle(vm.status?.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Помощник Yumurta")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if ready {
                    Button { vm.newChat() } label: { Image(systemName: "square.and.pencil") }
                        .disabled(vm.busy)
                        .accessibilityLabel("Новый разговор")
                }
            }
        }
        // При открытии и после входа/выхода (id меняется) — статус и история заново.
        .task(id: session.isLoggedIn) { await vm.load() }
        // Сервер не принял вопрос — возвращаем текст в поле (набранное после — не затираем).
        .onChange(of: vm.returned) { v in
            guard v != nil, let back = vm.takeReturned() else { return }
            let t = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? back : back + "\n" + draft
            draft = AssistantText.clip(t, maxLen)
        }
        .environment(\.openURL, OpenURLAction { url in
            let s = (url.scheme ?? "").lowercased()
            guard s == "https" || s == "http" else { return .discarded }
            link = PayLink(url: url)
            return .handled
        })
        .sheet(item: $link) { l in SafariSheet(url: l.url).ignoresSafeArea() }
        .confirmationDialog("Передать эту переписку сотруднику поддержки?", isPresented: $confirmHandoff, titleVisibility: .visible) {
            Button("Передать") { vm.handoff() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Ответ поддержки придёт в «Мои обращения» и в уведомления.")
        }
    }

    @ViewBuilder private var content: some View {
        if vm.loading && vm.status == nil {
            ProgressView().tint(YMColor.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let st = vm.status {
            if st.enabled != true && st.loginRequired != true {
                gate("Помощник сейчас выключен. Напишите в поддержку — ответит человек.", login: false)
            } else if !session.isLoggedIn || st.enabled != true {
                gate("Войдите в аккаунт, чтобы задать вопрос помощнику: переписка сохранится, а сложный вопрос можно передать сотруднику.", login: true)
            } else {
                disclaimerStrip(st)
                chat(st)
                inputBar(st)
            }
        } else {
            VStack(spacing: YMSpace.md) {
                Text(vm.loadError ?? "Помощник сейчас недоступен. Попробуйте позже")
                    .font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                Button("Повторить") { Task { await vm.load(force: true) } }
                    .font(YMFont.headline).foregroundStyle(YMColor.accent)
            }
            .padding(YMSpace.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func gate(_ text: String, login: Bool) -> some View {
        VStack(spacing: YMSpace.lg) {
            Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(YMColor.accent)
                .accessibilityHidden(true)
            Text(text).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
            if login {
                NavigationLink { AuthView() } label: { Text("Войти") }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .padding(.horizontal, YMSpace.xxxl)
            }
        }
        .padding(.horizontal, YMSpace.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func disclaimerStrip(_ st: AssistantStatus) -> some View {
        Text(st.disclaimer.flatMap { $0.isEmpty ? nil : $0 } ?? "Отвечает ИИ — может ошибаться")
            .font(YMFont.caption).foregroundStyle(YMColor.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, YMSpace.lg).padding(.vertical, YMSpace.sm)
            .background(YMColor.surface)
    }

    private func chat(_ st: AssistantStatus) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: YMSpace.sm) {
                    if vm.items.isEmpty { welcome(st) }
                    ForEach(vm.items) { item in
                        row(item).id(item.id)
                    }
                    if vm.busy { typing.id(-1) }
                }
                .padding(.horizontal, YMSpace.lg)
                .padding(.vertical, YMSpace.md)
            }
            .scrollDismissesKeyboard(.interactively)
            // Новое сообщение или «печатает…» — к низу ленты.
            .onChange(of: vm.items.count) { _ in scrollDown(proxy) }
            .onChange(of: vm.busy) { _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        let target: Int? = vm.busy ? -1 : vm.items.last?.id
        guard let target else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .bottom) }
    }

    // ── Пустой чат: приветствие и подсказки (тап — сразу вопрос) ──
    private func welcome(_ st: AssistantStatus) -> some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            bubble(mine: false) {
                Text((st.greeting.flatMap { $0.isEmpty ? nil : $0 } ?? "Здравствуйте! Я помощник Yumurta.") + "\nСпросите своими словами — например:")
                    .font(YMFont.body).foregroundStyle(YMColor.text)
            }
            ForEach(Array((st.suggestions ?? []).filter { !$0.isEmpty }.enumerated()), id: \.offset) { _, q in
                Button { vm.ask(q) } label: {
                    Text(q).font(YMFont.callout).foregroundStyle(YMColor.text)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, YMSpace.md).padding(.vertical, YMSpace.sm)
                        .background(YMColor.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(YMColor.accent.opacity(0.45), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(vm.busy || vm.loading)
            }
        }
    }

    @ViewBuilder private func row(_ item: AsstItem) -> some View {
        switch item.kind {
        case "user":
            bubble(mine: true) {
                Text(item.text).font(YMFont.body).foregroundStyle(YMColor.onAccent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Вы: \(item.text)")
        case "bot":
            botBubble(item)
        case "handoff":
            VStack(spacing: YMSpace.xs) {
                Text(item.text).font(YMFont.callout).foregroundStyle(YMColor.text).multilineTextAlignment(.center)
                if let tid = item.ticketId {
                    NavigationLink { SupportTicketView(id: tid) } label: {
                        Text("Открыть обращение №\(tid)").font(YMFont.callout.weight(.bold)).foregroundStyle(YMColor.accent)
                    }
                } else {
                    NavigationLink { NotificationsView() } label: {
                        Text("Открыть уведомления").font(YMFont.callout.weight(.bold)).foregroundStyle(YMColor.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        case "err":
            Text(item.text).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                .multilineTextAlignment(.center)
                .padding(.horizontal, YMSpace.md).padding(.vertical, YMSpace.sm)
                .background(YMColor.statusCancel.opacity(0.10), in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
                .frame(maxWidth: .infinity)
        default:
            Text(item.text).font(YMFont.caption).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func bubble<C: View>(mine: Bool, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            if mine { Spacer(minLength: 40) }
            content()
                .padding(.horizontal, YMSpace.md).padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: mine ? [YMPalette.goldBright, YMPalette.goldDeep] : [YMColor.surface, YMColor.surface],
                                             startPoint: .leading, endPoint: .trailing)))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(mine ? Color.clear : YMColor.hairline, lineWidth: 1))
            if !mine { Spacer(minLength: 40) }
        }
    }

    /// Куски блока → один Text: жирный/курсив, свои ссылки — подчёркнуты и нажимаются
    /// (ссылка — атрибут link куска, нажатие уходит в openURL экрана → SafariSheet).
    private func attributed(_ spans: [MdSpan]) -> Text {
        var out = Text("")
        for s in spans {
            var a = AttributedString(s.text)
            if let u = s.url, let url = URL(string: u) {
                a.link = url
                a[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            var t = Text(a).bold(s.bold)
            if s.italic { t = t.italic() }
            out = out + t
        }
        return out
    }

    private func botBubble(_ item: AsstItem) -> some View {
        let links: [(String, URL)] = {
            var seen = Set<String>(); var out: [(String, URL)] = []
            let all = item.blocks.flatMap { b in b.spans.compactMap { s in s.url.map { (s.text, $0) } } } + item.sources
            for (label, u) in all where seen.insert(u).inserted {
                if let url = URL(string: u) { out.append((label, url)) }
            }
            return out
        }()
        let spoken = "Помощник: " + AssistantMd.plain(item.blocks)
            + (item.sources.isEmpty ? "" : "\nИсточники: " + item.sources.map { $0.0 }.joined(separator: ", "))
        return VStack(alignment: .leading, spacing: YMSpace.xs) {
            bubble(mine: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, b in
                        if let marker = b.marker {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(marker).font(YMFont.body.weight(.semibold)).foregroundStyle(YMColor.accent)
                                    .frame(minWidth: marker == "•" ? 10 : 20, alignment: .leading)
                                attributed(b.spans).font(YMFont.body).foregroundStyle(YMColor.text)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            attributed(b.spans).font(YMFont.body).foregroundStyle(YMColor.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if item.blocks.isEmpty {
                        Text(item.text).font(YMFont.body).foregroundStyle(YMColor.text)
                    }
                    if !item.sources.isEmpty {
                        Text(sourcesLine(item.sources)).font(YMFont.caption).foregroundStyle(YMColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(YMColor.accent)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spoken)
            .modifier(AssistantLinkActions(links: links, open: { link = PayLink(url: $0) }))
            if item.msgId != nil {
                HStack(spacing: YMSpace.xs) {
                    rateButton(item, up: true)
                    rateButton(item, up: false)
                }
                .padding(.leading, YMSpace.xs)
            }
        }
    }

    private func sourcesLine(_ sources: [(String, String)]) -> AttributedString {
        var out = AttributedString("Источники: ")
        for (i, s) in sources.enumerated() {
            if i > 0 { out.append(AttributedString(" · ")) }
            var a = AttributedString(s.0)
            if let url = URL(string: s.1) {
                a.link = url
                a[AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = .single
            }
            out.append(a)
        }
        return out
    }

    private func rateButton(_ item: AsstItem, up: Bool) -> some View {
        let on = item.rating == (up ? 1 : -1)
        return Button { vm.rate(item.id, up ? 1 : -1) } label: {
            Image(systemName: up ? (on ? "hand.thumbsup.fill" : "hand.thumbsup") : (on ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(on ? YMColor.accent : YMColor.muted)
                .frame(width: 36, height: 36)
                .background(on ? YMColor.accent.opacity(0.16) : YMColor.surface2, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(up ? "Помогло" : "Не помогло")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var typing: some View {
        bubble(mine: false) {
            HStack(spacing: YMSpace.sm) {
                ProgressView().controlSize(.small).tint(YMColor.muted)
                Text("Помощник печатает…").font(YMFont.callout).foregroundStyle(YMColor.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func inputBar(_ st: AssistantStatus) -> some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let left = AssistantText.leftLabel(vm.leftToday)
        // Длина — в кодовых точках, как mb_strlen на сервере: счётчик, проверка и предел одинаковы.
        let counter = AssistantText.counter(AssistantText.length(draft), maxLen)
        return VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: YMSpace.sm) {
                TextField("Напишите вопрос…", text: $draft, axis: .vertical)
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                    .lineLimit(1...5)
                    .onChange(of: draft) { v in
                        if AssistantText.length(v) > maxLen { draft = AssistantText.clip(v, maxLen) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Вопрос помощнику")
                Button {
                    if vm.ask(draft) { draft = "" }
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 17, weight: .semibold)).foregroundStyle(YMColor.onAccent)
                        .frame(width: 40, height: 40)
                        .background(YMColor.accent, in: Circle())
                }
                .buttonStyle(.plain)
                // Пока грузится история — отправка закрыта (см. AssistantVM.ask).
                .disabled(empty || vm.busy || vm.loading)
                .opacity(empty || vm.busy || vm.loading ? 0.5 : 1)
                .accessibilityLabel(vm.busy ? "Отправить — ждём ответ помощника" : "Отправить")
            }
            if left != nil || counter != nil || st.canHandoff == true {
                HStack(alignment: .center, spacing: YMSpace.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        if let left { Text(left).font(YMFont.caption).foregroundStyle(YMColor.muted) }
                        if let counter { Text(counter).font(YMFont.caption).foregroundStyle(YMColor.muted) }
                    }
                    Spacer(minLength: 0)
                    if st.canHandoff == true {
                        Button {
                            if vm.hasChat { confirmHandoff = true } else { vm.handoff() }
                        } label: {
                            Label(vm.handing ? "Передаём…" : "Позвать человека", systemImage: "person.crop.circle.badge.questionmark")
                                .font(YMFont.subhead).foregroundStyle(YMColor.accent)
                        }
                        .buttonStyle(.plain)
                        .disabled(vm.handing)
                    }
                }
            }
        }
        .padding(.horizontal, YMSpace.md)
        .padding(.top, YMSpace.sm)
        .padding(.bottom, YMSpace.md)
        .background(YMColor.surface)
    }
}

/// VoiceOver: пузырь ответа читается одним элементом — ссылки (до трёх) даём действиями.
private struct AssistantLinkActions: ViewModifier {
    let links: [(String, URL)]
    let open: (URL) -> Void
    @ViewBuilder func body(content: Content) -> some View {
        switch links.count {
        case 0:
            content
        case 1:
            content
                .accessibilityAction(named: "Открыть \(links[0].0)") { open(links[0].1) }
        case 2:
            content
                .accessibilityAction(named: "Открыть \(links[0].0)") { open(links[0].1) }
                .accessibilityAction(named: "Открыть \(links[1].0)") { open(links[1].1) }
        default:
            content
                .accessibilityAction(named: "Открыть \(links[0].0)") { open(links[0].1) }
                .accessibilityAction(named: "Открыть \(links[1].0)") { open(links[1].1) }
                .accessibilityAction(named: "Открыть \(links[2].0)") { open(links[2].1) }
        }
    }
}
