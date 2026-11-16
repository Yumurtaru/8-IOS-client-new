import SwiftUI
import MapKit

//
//  OrgPlace.swift — поток «Заведение и товар» (паритет с Android: OrgPlace.kt / PlaceMap.kt / PlaceDto.kt):
//   1. «Зона доставки» на экране заведения → карта с закрашенными зонами и подписями цены /
//      минимальной суммы (GET api/v1/shops/{id}/delivery-zones). Нет зон — пункта нет.
//   2. «Забронировать столик» (mode = restaurant): дата, гости, время, стол на схеме, имя и
//      телефон → POST api/public/reservations. Ключа повтора у ручки нет: от двойного нажатия
//      кнопка блокируется на время запроса.
//   3. Видео товара (GET api/v1/products/{id}/videos) — показываем тем же ReviewMediaStrip, что видео отзывов.
//  Карта заведения с пином и «↗ Маршрут» на iPhone уже есть (addressCard/OrgMiniMap).
//

// MARK: - Модели (всё опционально: старый сервер не должен ронять экран)

/// Узел произвольного JSON для контуров зоны: число, строка-число или массив.
enum PlaceJSON: Decodable {
    case num(Double)
    case arr([PlaceJSON])
    case other

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([PlaceJSON].self) { self = .arr(a) }
        else if let d = try? c.decode(Double.self) { self = .num(d) }
        else if let s = try? c.decode(String.self), let d = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) { self = .num(d) }
        else { self = .other }
    }
}

/// GET api/v1/products/{id}/videos → [{path, thumbnail_webp, duration_sec}].
struct ProductVideo: Decodable {
    let path: String?
    let thumbnailWebp: String?
    @LenientInt var durationSec: Int?
}

/// GET api/v1/shops/{id}/delivery-zones. Имя зоны сервер клиенту не отдаёт.
struct DeliveryZoneGeo: Decodable {
    @LenientInt var id: Int?
    @LenientDecimal var deliveryPrice: Decimal?
    @LenientDecimal var minOrder: Decimal?
    @LenientDecimal var freeFrom: Decimal?
    @LenientInt var deliveryTimeMin: Int?
    @LenientInt var deliveryTimeMax: Int?
    /// Новый формат [[[lat,lng],..],..] или старый плоский [[lng,lat],..].
    let polygon: PlaceJSON?
    @LenientBool var isExcluded: Bool?
    let fillColor: String?
    let strokeColor: String?
    @LenientDouble var fillOpacity: Double?
}

/// GET api/v1/shops/{slug}/tables/availability.
struct TableAvailability: Decodable {
    let halls: [TableHall]?
    let slots: [TableSlot]?
}
struct TableHall: Decodable {
    let name: String?
    let tables: [TablePlace]?
}
struct TablePlace: Decodable {
    @LenientInt var tableId: Int?
    let name: String?
    @LenientInt var seats: Int?
    @LenientBool var free: Bool?
    @LenientBool var fits: Bool?
}
struct TableSlot: Decodable {
    let time: String?
    @LenientBool var available: Bool?
}

/// POST api/public/reservations. nil-поля не кодируются — сервер их просто не получает.
struct ReservationReq: Encodable {
    let slug: String
    let name: String
    let phone: String
    let date: String
    let time: String
    let guests: Int
    let comment: String?
    let tableId: Int?
}
struct ReservationDeposit: Decodable {
    @LenientBool var required: Bool?
    @LenientDecimal var amount: Decimal?
    let url: String?
}
struct ReservationResp: Decodable {
    @LenientInt var id: Int?
    let status: String?
    let table: String?
    let deposit: ReservationDeposit?
}

// MARK: - Чистая логика

struct PlaceZoneShape {
    let rings: [[CLLocationCoordinate2D]]
    let fill: UIColor
    let stroke: UIColor
    let opacity: Double
    let label: String
}

enum PlaceGeo {
    /// Контуры в (lat, lng). Зеркало Geo::normalizeContours на сервере.
    static func contours(_ j: PlaceJSON?) -> [[CLLocationCoordinate2D]] {
        guard case .arr(let arr)? = j, let first = arr.first else { return [] }
        var nested = false
        if case .arr(let f) = first, let f0 = f.first, case .arr = f0 { nested = true }
        var out: [[CLLocationCoordinate2D]] = []
        if nested {
            for ring in arr {
                guard case .arr(let pts) = ring else { continue }
                let r = pts.compactMap { point($0, lngFirst: false) }
                if r.count >= 3 { out.append(r) }
            }
        } else {
            let r = arr.compactMap { point($0, lngFirst: true) }
            if r.count >= 3 { out.append(r) }
        }
        return out
    }

    private static func point(_ j: PlaceJSON, lngFirst: Bool) -> CLLocationCoordinate2D? {
        guard case .arr(let p) = j, p.count >= 2, case .num(let a) = p[0], case .num(let b) = p[1] else { return nil }
        let lat = lngFirst ? b : a
        let lng = lngFirst ? a : b
        guard lat.isFinite, lng.isFinite, abs(lat) <= 90, abs(lng) <= 180 else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lng)
    }

    /// "#RRGGBB" / "#RGB" → UIColor; иначе запасной.
    static func color(_ raw: String?, fallback: UInt32) -> UIColor {
        var s = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return hex(fallback) }
        return hex(v)
    }

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// Исключённые зоны (is_excluded) и без геометрии пропускаем — как сайт.
    static func shapes(_ zones: [DeliveryZoneGeo]) -> [PlaceZoneShape] {
        zones.compactMap { z in
            if z.isExcluded == true { return nil }
            let rings = contours(z.polygon)
            if rings.isEmpty { return nil }
            let op = z.fillOpacity.flatMap { $0 >= 0 && $0 <= 1 ? $0 : nil } ?? 0.2
            return PlaceZoneShape(rings: rings,
                                  fill: color(z.fillColor, fallback: 0x3B82F6),
                                  stroke: color(z.strokeColor, fallback: 0x1D4ED8),
                                  opacity: min(max(op, 0.1), 0.6), label: label(z))
        }
    }

    /// «Доставка 150 ₽ · от 500 ₽ · бесплатно от 1 000 ₽ · 30–45 мин». Нет данных — пусто.
    static func label(_ z: DeliveryZoneGeo) -> String {
        var parts: [String] = []
        if let p = z.deliveryPrice { parts.append(p == 0 ? "Доставка бесплатно" : "Доставка " + Money.format(p)) }
        if let m = z.minOrder, m > 0 { parts.append("от " + Money.format(m)) }
        if let f = z.freeFrom, f > 0 { parts.append("бесплатно от " + Money.format(f)) }
        let t1 = (z.deliveryTimeMin ?? 0) > 0 ? z.deliveryTimeMin : nil
        let t2 = (z.deliveryTimeMax ?? 0) > 0 ? z.deliveryTimeMax : nil
        if let a = t1, let b = t2, b > a { parts.append("\(a)–\(b) мин") }
        else if let a = t1 { parts.append("от \(a) мин") }
        else if let b = t2 { parts.append("до \(b) мин") }
        return parts.joined(separator: " · ")
    }

    /// «0:45» из секунд; нет данных — nil.
    static func durationLabel(_ sec: Int?) -> String? {
        guard let s = sec, s > 0 else { return nil }
        return "\(s / 60):" + (s % 60 < 10 ? "0" : "") + "\(s % 60)"
    }
}

// MARK: - Карта зон (MapKit)

struct PlaceZonesMap: UIViewRepresentable {
    let zones: [PlaceZoneShape]
    let pin: CLLocationCoordinate2D?

    func makeCoordinator() -> Coordinator { Coordinator(zones: zones) }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.delegate = context.coordinator
        var rect = MKMapRect.null
        for (i, z) in zones.enumerated() {
            guard let outer = z.rings.first else { continue }
            let holes = z.rings.dropFirst().map { MKPolygon(coordinates: $0, count: $0.count) }
            let poly = MKPolygon(coordinates: outer, count: outer.count, interiorPolygons: holes.isEmpty ? nil : holes)
            poly.title = String(i)
            m.addOverlay(poly)
            rect = rect.union(poly.boundingMapRect)
        }
        if let p = pin {
            let a = MKPointAnnotation()
            a.coordinate = p
            m.addAnnotation(a)
            let mp = MKMapPoint(p)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 1, height: 1))
        }
        if !rect.isNull {
            m.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40), animated: false)
        }
        return m
    }

    func updateUIView(_ uiView: MKMapView, context: Context) {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        let zones: [PlaceZoneShape]
        init(zones: [PlaceZoneShape]) { self.zones = zones }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let p = overlay as? MKPolygon, let t = p.title, let i = Int(t), zones.indices.contains(i) {
                let r = MKPolygonRenderer(polygon: p)
                r.fillColor = zones[i].fill.withAlphaComponent(CGFloat(zones[i].opacity))
                r.strokeColor = zones[i].stroke
                r.lineWidth = 2
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

// MARK: - Перенос чипов по строкам (iOS 16 Layout)

struct PlaceFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Блок на экране заведения

private enum PlaceSheet: Identifiable {
    case zones, reserve
    var id: Int { self == .zones ? 1 : 2 }
}

/// «Зона доставки» и «Забронировать столик». Свой единственный .sheet(item:) — с листами OrgView не конфликтует.
struct OrgPlaceBlock: View {
    let detail: ShopDetail?

    @State private var zones: [PlaceZoneShape] = []
    @State private var sheet: PlaceSheet?

    private var slug: String { detail?.slug ?? "" }
    private var canReserve: Bool { detail?.mode?.lowercased() == "restaurant" && !slug.isEmpty }

    var body: some View {
        VStack(spacing: 10) {
            if !zones.isEmpty {
                Button { Haptics.light(); sheet = .zones } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Зона доставки").ymFont(14.5, weight: .bold).foregroundStyle(YMColor.text)
                            Text("Показать на карте").ymFont(12).foregroundStyle(YMColor.muted)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").ymIcon(13, weight: .semibold).foregroundStyle(YMColor.muted)
                    }
                    .padding(14)
                    .background(YMUi.card, in: RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: YMRadius.card, style: .continuous)
                        .strokeBorder(YMColor.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            if canReserve {
                Button { Haptics.light(); sheet = .reserve } label: { Text("Забронировать столик") }
                    .buttonStyle(YMPrimaryButtonStyle())
            }
        }
        .padding(.top, (zones.isEmpty && !canReserve) ? 0 : 12)
        .task(id: detail?.id) { await loadZones() }
        .sheet(item: $sheet) { s in
            switch s {
            case .zones:
                PlaceZonesSheet(zones: zones, pin: pin, onClose: { sheet = nil })
            case .reserve:
                ReserveTableView(slug: slug, timezone: detail?.timezone, onClose: { sheet = nil })
            }
        }
    }

    private var pin: CLLocationCoordinate2D? {
        guard let lat = detail?.lat, let lng = detail?.lng, !(lat == 0 && lng == 0) else { return nil }
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lng)
        return CLLocationCoordinate2DIsValid(c) ? c : nil
    }

    private func loadZones() async {
        guard let id = detail?.id else { return }
        // Ошибка или пусто — пункта нет; экран заведения не трогаем.
        if let list: [DeliveryZoneGeo] = try? await API.shared.list("api/v1/shops/\(id)/delivery-zones") {
            if Task.isCancelled { return }
            zones = PlaceGeo.shapes(list)
        } else {
            zones = []
        }
    }
}

// MARK: - Лист «Зона доставки»

private struct PlaceZonesSheet: View {
    let zones: [PlaceZoneShape]
    let pin: CLLocationCoordinate2D?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Зона доставки").ymFont(17, weight: .semibold).foregroundStyle(YMColor.text)
                .frame(maxWidth: .infinity).padding(.top, 18).padding(.bottom, 12)
            PlaceZonesMap(zones: zones, pin: pin)
                .frame(maxHeight: .infinity)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { i, z in
                        HStack(spacing: 10) {
                            Circle().fill(Color(z.fill)).frame(width: 12, height: 12)
                            Text(zoneText(i, z)).ymFont(14).foregroundStyle(YMColor.text)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(16)
            }
            .frame(maxHeight: 170)
        }
        .ymSheetChrome(onClose: onClose)
    }

    private func zoneText(_ i: Int, _ z: PlaceZoneShape) -> String {
        let t = z.label.isEmpty ? "условия уточняйте у заведения" : z.label
        return zones.count > 1 ? "Зона \(i + 1): " + t : t.prefix(1).uppercased() + t.dropFirst()
    }
}

// MARK: - Бронь столика

private struct PlaceDay: Hashable {
    let value: String
    let label: String
}

private struct ReserveTableView: View {
    let slug: String
    let timezone: String?
    let onClose: () -> Void

    @State private var days: [PlaceDay] = []
    @State private var date = ""
    @State private var guests = 2
    @State private var time: String?
    @State private var table: Int?
    @State private var name = ""
    @State private var phone = ""
    @State private var comment = ""
    @State private var avail: TableAvailability?
    @State private var availLoading = false
    @State private var availError: String?
    @State private var submitting = false
    @State private var error: String?
    @State private var done: ReservationResp?
    @State private var reload = 0
    @Environment(\.openURL) private var openURL

    /// Ключ перезапуска загрузки доступности: смена даты, гостей, времени или «Повторить».
    private var availKey: String { "\(date)|\(guests)|\(time ?? "")|\(reload)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let ok = done { doneView(ok) } else { formView }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .ymSheetChrome(onClose: { if !submitting { onClose() } })
        .interactiveDismissDisabled(submitting)
        .task { prepare() }
        .task { await prefill() }
        .task(id: availKey) { await loadAvailability() }
    }

    // MARK: Форма

    @ViewBuilder private var formView: some View {
        Group {
        Text("Бронь столика").ymFont(20, weight: .bold).foregroundStyle(YMColor.text)
        Text("Дата").ymFont(13, weight: .semibold).foregroundStyle(YMColor.muted)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { d in
                    chip(d.label, selected: d.value == date, enabled: true) { date = d.value; time = nil; table = nil }
                }
            }
        }
        HStack {
            Text("Гостей").ymFont(13, weight: .semibold).foregroundStyle(YMColor.muted)
            Spacer()
            stepButton("minus", enabled: guests > 1) { guests -= 1; time = nil; table = nil }
            Text("\(guests)").ymFont(17, weight: .semibold).foregroundStyle(YMColor.text).frame(minWidth: 40)
            stepButton("plus", enabled: guests < 50) { guests += 1; time = nil; table = nil }
        }
        Text("Время").ymFont(13, weight: .semibold).foregroundStyle(YMColor.muted)
        slotsView
        hallsView
        }
        Group {
        TextField("Имя", text: $name).textFieldStyle(.roundedBorder).disabled(submitting)
            .ymMaxLength($name, 120)
        TextField("Телефон", text: $phone).textFieldStyle(.roundedBorder).keyboardType(.phonePad).disabled(submitting)
            .ymMaxLength($phone, 20)
        TextField("Пожелания (необязательно)", text: $comment).textFieldStyle(.roundedBorder).disabled(submitting)
            .ymMaxLength($comment, 255)
        if let e = error {
            Text(e).ymFont(14).foregroundStyle(YMColor.statusCancel)
        }
        Button { Task { await submit() } } label: {
            if submitting { ProgressView().tint(YMColor.onAccent) } else { Text("Забронировать") }
        }
        .buttonStyle(YMPrimaryButtonStyle())
        .disabled(!canSubmit)
        }
    }

    private var canSubmit: Bool {
        !submitting && time != nil
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !phone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder private var slotsView: some View {
        let slots = avail?.slots ?? []
        if let e = availError, avail == nil {
            Text(e).ymFont(14).foregroundStyle(YMColor.statusCancel)
            Button("Повторить") { reload += 1 }.ymFont(13, weight: .semibold).foregroundStyle(YMColor.accent)
        } else if slots.isEmpty && availLoading {
            ProgressView()
        } else if slots.isEmpty {
            Text("На эту дату свободного времени нет").ymFont(14).foregroundStyle(YMColor.muted)
        } else {
            PlaceFlow(spacing: 8) {
                ForEach(Array(slots.enumerated()), id: \.offset) { _, s in
                    if let t = s.time {
                        chip(t, selected: t == time, enabled: s.available != false) { time = t; table = nil }
                    }
                }
            }
        }
    }

    /// Схема зала: только если время выбрано и у заведения есть план.
    @ViewBuilder private var hallsView: some View {
        let halls: [TableHall] = time == nil ? [] : (avail?.halls ?? []).filter { !($0.tables ?? []).isEmpty }
        if !halls.isEmpty {
            Text("Стол на схеме зала (необязательно)").ymFont(13, weight: .semibold).foregroundStyle(YMColor.muted)
            ForEach(Array(halls.enumerated()), id: \.offset) { _, h in
                if let hn = h.name, !hn.isEmpty { Text(hn).ymFont(12).foregroundStyle(YMColor.muted) }
                PlaceFlow(spacing: 8) {
                    ForEach(Array((h.tables ?? []).enumerated()), id: \.offset) { _, t in
                        if let id = t.tableId {
                            let free = t.free != false && t.fits != false
                            chip(tableTitle(t, id: id, free: free), selected: table == id, enabled: free) {
                                table = (table == id) ? nil : id
                            }
                        }
                    }
                }
            }
        }
    }

    private func tableTitle(_ t: TablePlace, id: Int, free: Bool) -> String {
        var s = t.name ?? "№\(id)"
        if let n = t.seats { s += " · \(n) мест" }
        if !free { s += " · занят" }
        return s
    }

    // MARK: Готово

    @ViewBuilder private func doneView(_ ok: ReservationResp) -> some View {
        Text("Бронь отправлена").ymFont(20, weight: .bold).foregroundStyle(YMColor.text)
        Text("Заведение подтвердит её. Статус брони пришлёт уведомление.").ymFont(14).foregroundStyle(YMColor.muted)
        Text(summary(ok)).ymFont(15).foregroundStyle(YMColor.text)
        if let dep = ok.deposit, dep.required == true {
            Text("Для брони нужен депозит" + (dep.amount.map { ": " + Money.format($0) } ?? "") + ".")
                .ymFont(14, weight: .semibold).foregroundStyle(YMColor.text)
            if let u = dep.url, u.hasPrefix("http"), let url = URL(string: u) {
                Button { openURL(url) } label: { Text("Оплатить депозит") }
                    .buttonStyle(YMPrimaryButtonStyle())
            }
        }
        Button { onClose() } label: { Text("Готово") }
            .buttonStyle(YMPrimaryButtonStyle())
    }

    private func summary(_ ok: ReservationResp) -> String {
        var bits: [String] = [date]
        if let t = time { bits.append(t) }
        bits.append("гостей: \(guests)")
        if let tb = ok.table, !tb.isEmpty { bits.append("стол \(tb)") }
        return bits.joined(separator: " · ")
    }

    // MARK: Элементы

    private func chip(_ text: String, selected: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Text(text).ymFont(13, weight: .semibold)
                .foregroundStyle(selected ? YMColor.onAccent : (enabled ? YMColor.text : YMColor.muted))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected ? YMColor.accent : YMUi.card, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? YMColor.accent : YMColor.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func stepButton(_ icon: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.light(); action() } label: {
            Image(systemName: icon).ymIcon(14, weight: .bold)
                .foregroundStyle(enabled ? YMColor.onAccent : YMColor.muted)
                .frame(width: 36, height: 36)
                .background(enabled ? YMColor.accent : YMColor.surface2, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Загрузка и отправка

    /// Дни — по часам города заведения (ShopTime), а не телефона.
    private func prepare() {
        guard days.isEmpty else { return }
        let tz = ShopTime.zone(timezone)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        let wd = ["Вс", "Пн", "Вт", "Ср", "Чт", "Пт", "Сб"]
        let now = Date()
        var out: [PlaceDay] = []
        for i in 0..<14 {
            guard let d = cal.date(byAdding: .day, value: i, to: now) else { continue }
            let comps = cal.dateComponents([.weekday, .day], from: d)
            let w = wd[max(0, min(6, (comps.weekday ?? 1) - 1))]
            out.append(PlaceDay(value: f.string(from: d), label: (i == 0 ? "Сегодня" : w) + " \(comps.day ?? 0)"))
        }
        days = out
        if date.isEmpty { date = out.first?.value ?? "" }
    }

    /// Имя и телефон из профиля — только если вошёл; гость вводит сам (сервер бронь гостю разрешает).
    private func prefill() async {
        guard Session.shared.isLoggedIn else { return }
        if let p: Profile = try? await API.shared.get("api/v1/profile") {
            if name.isEmpty { name = p.name ?? "" }
            if phone.isEmpty { phone = p.phone ?? "" }
        }
    }

    /// .task(id:) отменяет прежнюю загрузку при смене ключа — поздний ответ не перетрёт свежий.
    private func loadAvailability() async {
        guard !date.isEmpty else { return }
        availLoading = true; availError = nil
        var q: [String: String] = ["date": date, "guests": String(guests)]
        if let t = time { q["time"] = t }
        do {
            let a: TableAvailability = try await API.shared.get("api/v1/shops/\(slug)/tables/availability", query: q, fresh: true)
            if Task.isCancelled { return }
            avail = a
            // Выбранное время стало недоступным — сбрасываем.
            if let t = time, let slots = a.slots, !slots.isEmpty,
               !slots.contains(where: { $0.time == t && $0.available != false }) {
                time = nil; table = nil
            }
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            availError = error.userMessage ?? "Не удалось получить свободное время"
        }
        availLoading = false
    }

    private func submit() async {
        guard !submitting, let t = time else { return }
        submitting = true; error = nil
        defer { submitting = false }
        let req = ReservationReq(
            slug: slug,
            name: name.trimmingCharacters(in: .whitespaces),
            phone: phone.trimmingCharacters(in: .whitespaces),
            date: date, time: t, guests: guests,
            comment: comment.trimmingCharacters(in: .whitespaces).isEmpty ? nil : comment.trimmingCharacters(in: .whitespaces),
            tableId: table)
        do {
            let r: ReservationResp = try await API.shared.post("api/public/reservations", body: req)
            Haptics.success()
            done = r
        } catch {
            self.error = error.userMessage ?? "Не удалось забронировать"
            reload += 1   // занято / время ушло — обновим доступность
        }
    }
}

// MARK: - Видео товара

/// Блок «Видео» в карточке товара: превью + ▶, воспроизведение — как у видео отзывов (ReviewMediaStrip).
struct ProductVideosBlock: View {
    let videos: [ProductVideo]

    var body: some View {
        let media = videos.compactMap { v -> ReviewMedia? in
            guard let p = v.path, !p.isEmpty else { return nil }
            return ReviewMedia(kind: "video", url: p, poster: v.thumbnailWebp)
        }
        if !media.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Видео").ymFont(18, weight: .semibold).foregroundStyle(YMColor.text)
                ReviewMediaStrip(media: media)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, YMForm.cardGap)
        }
    }
}
