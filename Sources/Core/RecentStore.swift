import Foundation

struct RecentProduct: Codable, Identifiable, Hashable {
    let id: Int; let name: String; let photo: String?; let price: Double?
    let shopId: Int?; let shopName: String?
}

/// Хранилище «недавно смотрели» (локально, до 12 товаров).
enum RecentStore {
    private static let key = "recently_viewed"
    static func load() -> [RecentProduct] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([RecentProduct].self, from: d) else { return [] }
        return list
    }
    static func add(_ p: RecentProduct) {
        var list = load().filter { $0.id != p.id }
        list.insert(p, at: 0)
        list = Array(list.prefix(12))
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}
