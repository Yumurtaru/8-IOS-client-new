//
//  SupportTicketsView.swift — «Мои обращения» (волна сайта А102, П-54 №4):
//  список обращений в поддержку и переписка с ответом.
//
//  Вход: «Профиль» → «Поддержка» → «Мои обращения» (только вошедшему);
//  push ответа оператора (data.type = support, ticket_id) и строка ленты
//  «Уведомления» — сразу переписка (ProfilePushIntent .ticket); «Помощник» →
//  «Позвать человека» (handoff kind = ticket) — тоже она.
//
//  Ручки (routes/api_v1.php, только вошедшему):
//    • GET  api/v1/support/tickets            → [{id, subject, status, created_at}], до 100, новые сверху;
//    • GET  api/v1/support/tickets/{id}       → {…, messages: [{sender_id, sender_name, mine, message, created_at}]};
//    • POST api/v1/support/tickets/{id}/reply {message} → {sent:true}; до 2000 знаков (mb_strlen после
//      trim), обращение снова «open». Ключа повтора ручка не принимает (v1IdemReplay не вызывает):
//      вторую отправку закрывают кнопка и поле, пока запрос идёт; поле очищается только после
//      успеха — ответ не ушёл, текст остаётся в поле.
//  Старый сервер (404) — «раздел пока недоступен», без падения. Push ответа при открытом
//  экране (.ymSupportPushed) и возврат в приложение — перечитываем.
//  Паритет с Android: ui/screens/profile/SupportTicketsScreen.kt, SupportTicketText.kt.
//

import SwiftUI

// MARK: - Модели (все поля необязательные; числа и флаги — терпимо: PDO отдаёт строкой)

/// Строка списка. status — support_tickets.status: open | answered | closed.
struct SupportTicket: Decodable {
    @LenientInt var id: Int?
    let subject: String?
    let status: String?
    let createdAt: String?
}

/// Сообщение переписки. senderName — «Вы» | «Поддержка»; senderId чужого — 0.
struct SupportTicketMessage: Decodable {
    @LenientInt var senderId: Int?
    let senderName: String?
    @LenientBool var mine: Bool?
    let message: String?
    let createdAt: String?
}

/// Обращение и переписка по порядку.
struct SupportTicketDetail: Decodable {
    @LenientInt var id: Int?
    let subject: String?
    var status: String?
    let createdAt: String?
    var messages: [SupportTicketMessage]?
}

private struct SupportReplyBody: Encodable { let message: String }
struct SupportReplyResp: Decodable { @LenientBool var sent: Bool? }

extension Notification.Name {
    /// Push ответа поддержки (type = support): object — номер обращения (Int) или nil.
    static let ymSupportPushed = Notification.Name("ym.supportPushed")
}

/// Какая переписка сейчас на экране (push по ней — только перечитать, без второго экрана).
enum SupportTicketLive {
    static var openId: Int?
}

// MARK: - Логика без UI (1:1 с Android SupportTicketText)

enum SupportTicketText {
    /// Предел ответа: POST …/reply — noteClamp (trim), mb_strlen > 2000 → 422.
    static let maxReply = 2000

    /// Статус словами. support_tickets.status (sql/yumurta.sql): open — ждёт ответа поддержки
    /// (новое и после каждого ответа покупателя), answered — оператор ответил (admin.php),
    /// closed — закрыто (ответ покупателя открывает снова). Незнакомое — nil: плашки нет.
    static func statusLabel(_ status: String?) -> String? {
        switch norm(status) {
        case "open": return "Ждёт ответа"
        case "answered": return "Есть ответ"
        case "closed": return "Закрыто"
        default: return nil
        }
    }

    static func replyHint(_ status: String?) -> String? {
        norm(status) == "closed" ? "Обращение закрыто. Если напишете, оно откроется снова." : nil
    }

    static func norm(_ s: String?) -> String {
        (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Тема строки; пустая — «Обращение №N».
    static func title(_ id: Int, _ subject: String?) -> String {
        let t = (subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "Обращение №\(id)" : t
    }

    /// Подпись автора: senderName сервера, без него — по mine.
    static func sender(_ name: String?, mine: Bool) -> String {
        let n = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return n.isEmpty ? (mine ? "Вы" : "Поддержка") : n
    }

    /// Длина в кодовых точках — как mb_strlen на сервере (и как Android).
    static func length(_ s: String) -> Int { s.unicodeScalars.count }

    /// Обрезать до max кодовых точек.
    static func clip(_ s: String, _ max: Int = maxReply) -> String {
        guard max > 0, length(s) > max else { return s }
        var u = String.UnicodeScalarView()
        u.append(contentsOf: s.unicodeScalars.prefix(max))
        return String(u)
    }

    /// Что уйдёт на сервер: без пробелов по краям. Пусто или длиннее предела — nil.
    static func replyText(_ draft: String) -> String? {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty || length(t) > maxReply ? nil : t
    }

    /// Счётчик знаков: показываем с 80 % предела.
    static func counter(_ len: Int, _ max: Int = maxReply) -> String? {
        max > 0 && len * 5 >= max * 4 ? "\(len) / \(max)" : nil
    }

    private static let months = ["января", "февраля", "марта", "апреля", "мая", "июня",
                                 "июля", "августа", "сентября", "октября", "ноября", "декабря"]

    /// «2026-10-06 23:00:00» → «6 октября, 23:00» (другой год — «6 октября 2025, 23:00»).
    /// Время сервера — московское, показываем как есть. Не разобралось — строка как была.
    static func whenLabel(_ raw: String?, nowYear: Int) -> String {
        let s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = s.range(of: "[0-9]{4}-[0-9]{2}-[0-9]{2}", options: .regularExpression) else { return s }
        let parts = s[r].split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day) else { return s }
        let year = String(parts[0])
        var d = "\(day) \(months[month - 1])"
        if year != String(nowYear) { d += " \(year)" }
        let rest = s[r.upperBound...]
        if let t = rest.range(of: "[0-9]{2}:[0-9]{2}", options: .regularExpression) {
            return d + ", " + rest[t]
        }
        return d
    }

    /// Год по Москве (время сервера — московское).
    static func moscowYear() -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/Moscow") ?? .current
        return cal.component(.year, from: Date())
    }
}

// MARK: - Запросы

enum SupportTicketsAPI {
    static func list() async throws -> [SupportTicket] {
        try await API.shared.list("api/v1/support/tickets")
    }
    static func ticket(_ id: Int) async throws -> SupportTicketDetail {
        try await API.shared.get("api/v1/support/tickets/\(id)")
    }
    /// Без retryKey: ручка ключ повтора не принимает.
    static func reply(_ id: Int, _ text: String) async throws -> SupportReplyResp {
        try await API.shared.post("api/v1/support/tickets/\(id)/reply", body: SupportReplyBody(message: text))
    }
}

private let unavailableList = "Раздел «Мои обращения» пока недоступен. Напишите или позвоните нам — контакты в «Поддержке»."
private let unavailableTicket = "Не удалось открыть обращение: его нет в вашем аккаунте или раздел пока недоступен."

// MARK: - Список

@MainActor
final class SupportTicketsVM: ObservableObject {
    @Published private(set) var items: [SupportTicket]?
    @Published private(set) var error: String?
    /// 404: старый сервер без ручки — текст вместо ошибки с «Повторить».
    @Published private(set) var unavailable = false

    func load(silent: Bool) async {
        do {
            let list = try await SupportTicketsAPI.list()
            items = list.filter { ($0.id ?? 0) > 0 }
            error = nil; unavailable = false
        } catch is CancellationError {
        } catch {
            if silent && items != nil { return }
            if (error as? APIError)?.rejectStatus == 404 { unavailable = true; return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить обращения"
        }
    }

    func retry() { error = nil; Task { await load(silent: false) } }
}

struct SupportTicketsView: View {
    @StateObject private var vm = SupportTicketsVM()
    @Environment(\.scenePhase) private var scenePhase
    private let nowYear = SupportTicketText.moscowYear()

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Мои обращения")
            .navigationBarTitleDisplayMode(.inline)
            // При открытии и при возврате с переписки (статус мог смениться).
            .task { await vm.load(silent: vm.items != nil) }
            .onReceive(NotificationCenter.default.publisher(for: .ymSupportPushed)) { _ in
                Task { await vm.load(silent: true) }
            }
            .onChange(of: scenePhase) { p in
                if p == .active { Task { await vm.load(silent: true) } }
            }
    }

    @ViewBuilder private var content: some View {
        if let list = vm.items {
            if list.isEmpty {
                note("Обращений пока нет. Здесь появятся ваши вопросы в поддержку и ответы на них — например, если в помощнике нажать «Позвать человека».")
            } else {
                ScrollView {
                    LazyVStack(spacing: YMSpace.md) {
                        ForEach(list, id: \.ticketKey) { t in
                            NavigationLink { SupportTicketView(id: t.id ?? 0) } label: { row(t) }
                                .buttonStyle(.plain)
                                .accessibilityHint("Открыть переписку")
                        }
                    }
                    .padding(.horizontal, YMSpace.xl)
                    .padding(.top, YMSpace.sm)
                    .padding(.bottom, YMSpace.xxxl)
                }
                .refreshable { await vm.load(silent: true) }
            }
        } else if vm.unavailable {
            note(unavailableList)
        } else if let err = vm.error {
            VStack(spacing: YMSpace.md) {
                Text(err).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                Button("Повторить") { vm.retry() }
                    .font(YMFont.headline).foregroundStyle(YMColor.accent)
            }
            .padding(YMSpace.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().tint(YMColor.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ t: SupportTicket) -> some View {
        let id = t.id ?? 0
        let date = SupportTicketText.whenLabel(t.createdAt, nowYear: nowYear)
        let label = SupportTicketText.statusLabel(t.status)
        let meta = (["Обращение №\(id)", date].filter { !$0.isEmpty }).joined(separator: " · ")
        return VStack(alignment: .leading, spacing: YMSpace.xs) {
            HStack(alignment: .firstTextBaseline, spacing: YMSpace.sm) {
                Text(SupportTicketText.title(id, t.subject))
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let label { SupportStatusPill(status: t.status, label: label) }
            }
            Text(meta).font(YMFont.caption).foregroundStyle(YMColor.muted)
        }
        .padding(YMSpace.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(YMColor.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        // VoiceOver: одна строка — «Тема, статус: Есть ответ, Обращение №12 · 6 октября».
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SupportTicketText.title(id, t.subject)
                            + (label.map { ", статус: \($0)" } ?? "") + ", " + meta)
        .accessibilityAddTraits(.isButton)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(YMFont.body).foregroundStyle(YMColor.muted)
            .multilineTextAlignment(.center)
            .padding(YMSpace.xl)
            .frame(maxWidth: .infinity)
    }
}

private extension SupportTicket {
    var ticketKey: Int { id ?? 0 }
}

/// Плашка статуса: answered — акцент (есть что прочитать), open — ожидание, closed — приглушённо.
private struct SupportStatusPill: View {
    let status: String?
    let label: String

    private var tone: Color {
        switch SupportTicketText.norm(status) {
        case "answered": return YMColor.accent
        case "open": return YMColor.statusPending
        default: return YMColor.muted
        }
    }

    var body: some View {
        Text(label)
            .font(YMFont.caption2).foregroundStyle(tone)
            .padding(.horizontal, YMSpace.sm).padding(.vertical, 3)
            .background(tone.opacity(0.14), in: Capsule())
            .accessibilityLabel("Статус: \(label)")
    }
}

// MARK: - Переписка

@MainActor
final class SupportTicketVM: ObservableObject {
    let id: Int
    @Published private(set) var ticket: SupportTicketDetail?
    @Published private(set) var error: String?
    @Published private(set) var notFound = false
    @Published private(set) var sending = false
    @Published var sendError: String?
    /// Ответов, принятых сервером: экран очищает поле только по нему (после успеха).
    @Published private(set) var sentCount = 0

    init(id: Int) { self.id = id }

    func load(silent: Bool) async {
        do {
            ticket = try await SupportTicketsAPI.ticket(id)
            error = nil; notFound = false
        } catch is CancellationError {
        } catch {
            if silent && ticket != nil { return }
            if (error as? APIError)?.rejectStatus == 404 { notFound = true; return }
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить переписку"
        }
    }

    func retry() { error = nil; Task { await load(silent: false) } }

    /// Отправить ответ (пусто, длинно, уже отправляем — ничего). Поле экран очищает по sentCount.
    func send(_ draft: String) {
        guard !sending, let text = SupportTicketText.replyText(draft) else { return }
        sending = true
        sendError = nil
        Task {
            do {
                _ = try await SupportTicketsAPI.reply(id, text)
                sending = false
                sentCount += 1
                // Сразу своё сообщение; время и статус «open» — из перечитанного ответа.
                if var t = ticket {
                    t.status = "open"
                    t.messages = (t.messages ?? []) + [SupportTicketMessage(senderId: nil, senderName: "Вы", mine: true, message: text, createdAt: nil)]
                    ticket = t
                }
                Haptics.success()
                await load(silent: true)
            } catch {
                // Не принят (сеть, 422, 429…) — текст так и остался в поле.
                sending = false
                if !(error is CancellationError) {
                    sendError = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить — попробуйте ещё раз"
                    Haptics.error()
                }
            }
        }
    }
}

struct SupportTicketView: View {
    let id: Int
    @StateObject private var vm: SupportTicketVM
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""
    private let nowYear = SupportTicketText.moscowYear()

    init(id: Int) {
        self.id = id
        _vm = StateObject(wrappedValue: SupportTicketVM(id: id))
    }

    private var messages: [SupportTicketMessage] {
        (vm.ticket?.messages ?? []).filter { !($0.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Обращение №\(id)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.load(silent: vm.ticket != nil) }
        .onReceive(NotificationCenter.default.publisher(for: .ymSupportPushed)) { n in
            if let pid = n.object as? Int, pid != id { return }
            Task { await vm.load(silent: true) }
        }
        .onChange(of: scenePhase) { p in
            if p == .active { Task { await vm.load(silent: true) } }
        }
        // Сервер принял ответ — только теперь очищаем поле.
        .onChange(of: vm.sentCount) { _ in draft = "" }
        .onAppear { SupportTicketLive.openId = id }
        .onDisappear { if SupportTicketLive.openId == id { SupportTicketLive.openId = nil } }
    }

    @ViewBuilder private var content: some View {
        if let t = vm.ticket {
            header(t)
            chat
            replyBar(t)
        } else if vm.notFound {
            Text(unavailableTicket).font(YMFont.body).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
                .padding(YMSpace.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let err = vm.error {
            VStack(spacing: YMSpace.md) {
                Text(err).font(YMFont.body).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
                Button("Повторить") { vm.retry() }
                    .font(YMFont.headline).foregroundStyle(YMColor.accent)
            }
            .padding(YMSpace.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().tint(YMColor.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ t: SupportTicketDetail) -> some View {
        let subject = (t.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let label = SupportTicketText.statusLabel(t.status)
        return HStack(alignment: .center, spacing: YMSpace.sm) {
            if !subject.isEmpty {
                Text(subject).font(YMFont.callout).foregroundStyle(YMColor.text).lineLimit(2)
            }
            Spacer(minLength: 0)
            if let label { SupportStatusPill(status: t.status, label: label) }
        }
        .padding(.horizontal, YMSpace.lg).padding(.vertical, YMSpace.sm)
        .frame(maxWidth: .infinity)
        .background(YMColor.surface)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: YMSpace.sm) {
                    if messages.isEmpty {
                        Text("Сообщений пока нет.").font(YMFont.callout).foregroundStyle(YMColor.muted)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(Array(messages.enumerated()), id: \.offset) { i, m in
                        bubble(m).id(i)
                    }
                }
                .padding(.horizontal, YMSpace.lg)
                .padding(.vertical, YMSpace.md)
            }
            .scrollDismissesKeyboard(.interactively)
            // Новое сообщение — к низу переписки.
            .onAppear { scrollDown(proxy) }
            .onChange(of: messages.count) { _ in scrollDown(proxy) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy) {
        let n = messages.count
        guard n > 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(n - 1, anchor: .bottom) }
    }

    private func bubble(_ m: SupportTicketMessage) -> some View {
        let mine = m.mine == true
        let who = SupportTicketText.sender(m.senderName, mine: mine)
        let time = SupportTicketText.whenLabel(m.createdAt, nowYear: nowYear)
        let text = m.message ?? ""
        return HStack {
            if mine { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 2) {
                if !mine { Text(who).font(YMFont.caption2).foregroundStyle(YMColor.accent) }
                Text(text).font(YMFont.body).foregroundStyle(mine ? YMColor.onAccent : YMColor.text)
                    .fixedSize(horizontal: false, vertical: true)
                if !time.isEmpty {
                    Text(time).font(YMFont.caption)
                        .foregroundStyle(mine ? YMColor.onAccent.opacity(0.75) : YMColor.muted)
                }
            }
            .padding(.horizontal, YMSpace.md).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(LinearGradient(colors: mine ? [YMPalette.goldBright, YMPalette.goldDeep] : [YMColor.surface, YMColor.surface],
                                         startPoint: .leading, endPoint: .trailing)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(mine ? Color.clear : YMColor.hairline, lineWidth: 1))
            if !mine { Spacer(minLength: 40) }
        }
        // VoiceOver: «Поддержка, 6 октября, 23:00: текст» одним элементом.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(who + (time.isEmpty ? "" : ", \(time)") + ": " + text)
    }

    private func replyBar(_ t: SupportTicketDetail) -> some View {
        let canSend = !vm.sending && SupportTicketText.replyText(draft) != nil
        let counter = SupportTicketText.counter(SupportTicketText.length(draft))
        return VStack(alignment: .leading, spacing: 6) {
            if let hint = SupportTicketText.replyHint(t.status) {
                Text(hint).font(YMFont.caption).foregroundStyle(YMColor.muted)
            }
            HStack(alignment: .bottom, spacing: YMSpace.sm) {
                TextField("Напишите ответ…", text: $draft, axis: .vertical)
                    .font(YMFont.body).foregroundStyle(YMColor.text)
                    .lineLimit(1...6)
                    .onChange(of: draft) { v in
                        if SupportTicketText.length(v) > SupportTicketText.maxReply { draft = SupportTicketText.clip(v) }
                        if vm.sendError != nil { vm.sendError = nil }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .accessibilityLabel("Ответ в поддержку")
                    // Пока ответ отправляется, поле закрыто: очистим его после успеха.
                    .disabled(vm.sending)
                Button {
                    vm.send(draft)
                } label: {
                    Group {
                        if vm.sending { ProgressView().tint(YMColor.onAccent) }
                        else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 17, weight: .semibold)).foregroundStyle(YMColor.onAccent)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .background(YMColor.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .opacity(canSend || vm.sending ? 1 : 0.5)
                .accessibilityLabel(vm.sending ? "Отправляем ответ" : "Отправить ответ")
            }
            if let counter { Text(counter).font(YMFont.caption).foregroundStyle(YMColor.muted) }
            if let e = vm.sendError {
                Text(e).font(YMFont.callout.weight(.semibold)).foregroundStyle(YMColor.statusCancel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, YMSpace.md)
        .padding(.top, YMSpace.sm)
        .padding(.bottom, YMSpace.md)
        .background(YMColor.surface)
    }
}
