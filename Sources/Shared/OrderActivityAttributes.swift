import Foundation

//  Общая модель Live Activity «Статус заказа». Файл входит и в основное приложение
//  (Sources), и в расширение YumurtaWidgets (project.extensions.yml, sources).
//  Без ActivityKit-зависимостей выше #if — шаги нужны и виджетам.
//
//  ContentState для push (APNs liveactivity) — JSON с ключами snake_case:
//    { "step": "preparing", "status_text": "Готовится", "eta_minutes": 25,
//      "eta_at": 1790000000, "courier_name": "Иван" }
//  eta_minutes, eta_at (unix-секунды), courier_name — необязательные; step —
//  placed | preparing | on_way | done | cancelled (неизвестный = placed).

/// Шаги заказа на экране блокировки.
enum OrderStep: String, Codable, Hashable {
    case placed, preparing
    case onWay = "on_way"
    case done, cancelled

    /// Позиция на шкале из четырёх делений (оформлен, готовится, в пути, доставлен).
    var index: Int {
        switch self {
        case .placed:    return 0
        case .preparing: return 1
        case .onWay:     return 2
        case .done:      return 3
        case .cancelled: return 0
        }
    }

    /// Мягкий разбор строки сервера; незнакомое значение = placed.
    static func parse(_ raw: String?) -> OrderStep {
        switch raw ?? "" {
        case "preparing": return .preparing
        case "on_way":    return .onWay
        case "done":      return .done
        case "cancelled": return .cancelled
        default:          return .placed
        }
    }

    func title(isPickup: Bool) -> String {
        switch self {
        case .placed:    return "Оформлен"
        case .preparing: return "Готовится"
        case .onWay:     return isPickup ? "Готов к выдаче" : "В пути"
        case .done:      return isPickup ? "Выдан" : "Доставлен"
        case .cancelled: return "Отменён"
        }
    }
}

#if canImport(ActivityKit)
import ActivityKit

@available(iOS 16.1, *)
struct OrderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var step: OrderStep
        var statusText: String
        var etaMinutes: Int?
        /// Время прибытия, unix-секунды (точнее минут: не «стареет» без обновлений).
        var etaAt: Int?
        var courierName: String?

        enum CodingKeys: String, CodingKey {
            case step
            case statusText = "status_text"
            case etaMinutes = "eta_minutes"
            case etaAt = "eta_at"
            case courierName = "courier_name"
        }

        init(step: OrderStep, statusText: String, etaMinutes: Int? = nil, etaAt: Int? = nil, courierName: String? = nil) {
            self.step = step
            self.statusText = statusText
            self.etaMinutes = etaMinutes
            self.etaAt = etaAt
            self.courierName = courierName
        }

        /// Мягкий разбор: числа могут прийти строками, шаг — незнакомым.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let rawStep = (try? c.decode(String.self, forKey: .step)) ?? ""
            step = OrderStep.parse(rawStep)
            statusText = (try? c.decode(String.self, forKey: .statusText)) ?? ""
            etaMinutes = Self.lenientInt(c, .etaMinutes)
            etaAt = Self.lenientInt(c, .etaAt)
            let name = (try? c.decode(String.self, forKey: .courierName)) ?? nil
            courierName = (name?.isEmpty ?? true) ? nil : name
        }

        private static func lenientInt(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Int? {
            if let i = try? c.decode(Int.self, forKey: key) { return i }
            if let s = try? c.decode(String.self, forKey: key) { return Int(s) }
            return nil
        }
    }

    var orderId: Int
    var orderNumber: String
    var shopName: String
    var isPickup: Bool
}
#endif
