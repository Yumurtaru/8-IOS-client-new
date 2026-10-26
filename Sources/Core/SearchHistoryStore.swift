import Foundation

/// Недавние поисковые запросы (локально, до 8).
enum SearchHistoryStore {
    private static let key = "search_history"
    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }
    static func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        var list = load().filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        list.insert(q, at: 0)
        list = Array(list.prefix(8))
        UserDefaults.standard.set(list, forKey: key)
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
