import SwiftUI

// Подсказки адреса: GET api/address/suggest?q=… (серверный прокси, ключ в приложении не нужен).
// Лимит сервера 180 запросов/мин с IP: минимум 3 символа, дебаунс 350 мс на стороне вызова,
// отмена прошлого запроса (Task.cancel) и кэш последних 20 ответов в памяти.
// Ошибка/нет сети -> nil: вызывающий молча прячет подсказки, ввод работает как обычно.
actor AddressSuggestService {
    static let shared = AddressSuggestService()
    private var cache: [String: [AddrSuggest]] = [:]
    private var order: [String] = []
    private let maxEntries = 20

    func fetch(_ query: String) async -> [AddrSuggest]? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { return [] }
        if let hit = cache[q] {
            order.removeAll { $0 == q }; order.append(q)
            return hit
        }
        do {
            let res: [AddrSuggest] = try await API.shared.get("api/address/suggest", query: ["q": q])
            let list = Array(res.prefix(7))
            if Task.isCancelled { return nil }
            cache[q] = list
            order.append(q)
            while order.count > maxEntries { cache[order.removeFirst()] = nil }
            return list
        } catch {
            return nil
        }
    }
}

/// Список подсказок: основная строка — улица и дом, вторая серым — город.
/// Один контейнер для VoiceOver («Подсказки адреса»), каждая строка читается целиком.
struct AddressSuggestRows: View {
    let items: [AddrSuggest]
    let onPick: (AddrSuggest) -> Void

    static func title(_ s: AddrSuggest) -> String {
        var line = s.street ?? ""
        if let h = s.house, !h.isEmpty { line += (line.isEmpty ? "" : ", ") + "д. \(h)" }
        return line.isEmpty ? (s.value ?? "") : line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.prefix(7).enumerated()), id: \.offset) { idx, s in
                Button { onPick(s) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.circle").foregroundStyle(YMColor.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Self.title(s)).foregroundStyle(YMColor.text)
                            if let c = s.city, !c.isEmpty {
                                Text(c).font(YMFont.caption).foregroundStyle(YMColor.muted)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(s.value ?? Self.title(s))
                .accessibilityAddTraits(.isButton)
                if idx < min(items.count, 7) - 1 { Divider() }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Подсказки адреса")
        .onAppear {
            UIAccessibility.post(notification: .announcement, argument: "Подсказки адреса")
        }
    }
}

/// Подсказки под произвольным полем (форма посылки): следит за текстом, сам делает дебаунс.
/// Выбранный текст запоминается, чтобы подстановка не запускала новый поиск.
struct AddressSuggestBox: View {
    @Binding var text: String
    let city: String
    let focused: Bool
    var onPick: ((AddrSuggest) -> Void)? = nil

    @State private var items: [AddrSuggest] = []
    @State private var task: Task<Void, Never>?
    @State private var pickedText: String?

    var body: some View {
        Group {
            if focused && !items.isEmpty {
                AddressSuggestRows(items: items) { s in
                    task?.cancel()
                    let v = s.value ?? text
                    pickedText = v
                    text = v
                    items = []
                    onPick?(s)
                }
                .padding(.horizontal, 14)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            }
        }
        .onChange(of: text) { v in schedule(v) }
        .onChange(of: focused) { f in if !f { items = [] } }
        .onDisappear { task?.cancel() }
    }

    private func schedule(_ v: String) {
        task?.cancel()
        if let p = pickedText, p == v { return }
        pickedText = nil
        let q = v.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3 else { items = []; return }
        let query = city.isEmpty ? q : "\(city), \(q)"
        task = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            if Task.isCancelled { return }
            let res = await AddressSuggestService.shared.fetch(query)
            if Task.isCancelled { return }
            await MainActor.run {
                items = (res ?? []).filter { s in
                    city.isEmpty || (s.city?.isEmpty ?? true) || s.city?.caseInsensitiveCompare(city) == .orderedSame
                }
            }
        }
    }
}
