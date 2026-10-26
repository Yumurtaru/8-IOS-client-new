import Network
import Combine

/// Следит за наличием сети для офлайн-баннера.
final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    @Published var online = true
    private let monitor = NWPathMonitor()
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // Пишем только при смене: @Published шлёт изменение и на то же
            // значение, а за ним следят приложение и корень вкладок — каждое
            // обновление пути (Wi-Fi ↔ LTE, смена интерфейса) перерисовывало всё.
            let now = path.status == .satisfied
            DispatchQueue.main.async { if self?.online != now { self?.online = now } }
        }
        monitor.start(queue: DispatchQueue(label: "network.monitor"))
    }
}
