import Foundation
import os

// Конверт ответа v1: {success, data, meta, error}
// errors — ошибки полей сайтового конверта {ok:false, error, errors} (Response::validation):
// без них на 422 человек видел только «Проверьте правильность заполнения» без поля.
struct APIEnvelope<T: Decodable>: Decodable { let success: Bool?; let data: T?; let meta: PageMeta?; let error: APIErr?; let errors: SiteFieldErrors? }

/// Ошибки полей сайтового конверта: {"поле": ["текст", …]} или {"поле": "текст"}.
/// Разбор никогда не бросает: errors бывает [] (пустой массив) или другой формы —
/// тогда список пуст, и ответ целиком не теряется. Вложенные объекты пропускаем.
struct SiteFieldErrors: Decodable {
    /// Первый непустой текст каждого поля (поля по алфавиту — порядок стабилен).
    let messages: [String]
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Key.self) else { messages = []; return }
        var found: [(String, String)] = []
        for k in c.allKeys {
            if let s = try? c.decode(String.self, forKey: k), !s.isEmpty {
                found.append((k.stringValue, s))
            } else if let list = try? c.decode([String].self, forKey: k),
                      let s = list.first(where: { !$0.isEmpty }) {
                found.append((k.stringValue, s))
            }
        }
        messages = found.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}

/// meta постраничных списков v1 (контракт, волна А3): page, per_page, has_more.
/// Так отвечают GET api/v1/shops и api/v1/organizations (по 100), api/v1/orders
/// (по 100), api/v1/notifications (по 20). has_more = true — есть следующая
/// страница, просите page+1. Сервер per_page НЕ принимает, размер страницы его.
/// Разбор никогда не бросает: meta бывает null, другой формы или пустым — тогда
/// все поля nil, и ответ целиком не теряется из-за служебного поля.
struct PageMeta: Decodable {
    let page: Int?
    let perPage: Int?
    let hasMore: Bool?
    /// Только у api/v1/notifications: непрочитанных ВСЕГО, а не на странице.
    let unread: Int?
    /// П-25 №2 (А62): у api/v1/orders — всего строк списка (все статусы, записи
    /// и брони тоже). Старый сервер не шлёт — nil, считаем по странице, как раньше.
    let total: Int?
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else {
            page = nil; perPage = nil; hasMore = nil; unread = nil; total = nil; return
        }
        total = (try? c.decode(Int.self, forKey: .total)) ?? (try? c.decode(String.self, forKey: .total)).flatMap { Int($0) }
        unread = (try? c.decode(Int.self, forKey: .unread)) ?? (try? c.decode(String.self, forKey: .unread)).flatMap { Int($0) }
        page = (try? c.decode(Int.self, forKey: .page)) ?? (try? c.decode(String.self, forKey: .page)).flatMap { Int($0) }
        perPage = (try? c.decode(Int.self, forKey: .perPage)) ?? (try? c.decode(String.self, forKey: .perPage)).flatMap { Int($0) }
        hasMore = (try? c.decode(Bool.self, forKey: .hasMore)) ?? (try? c.decode(Int.self, forKey: .hasMore)).map { $0 != 0 }
    }
    // Ключи в camelCase: декодер API переводит snake_case сам (per_page → perPage).
    enum CodingKeys: String, CodingKey { case page, perPage, hasMore, unread, total }
}

/// Получатель meta: API.perform передаёт ему meta конверта после разбора data.
protocol PageMetaReceiving: AnyObject { func receive(meta: PageMeta?) }

/// Страница списка вместе с признаком «есть ещё». Берётся через API.shared.page(...).
final class Page<T: Decodable>: Decodable, PageMetaReceiving {
    let items: [T]
    private(set) var meta: PageMeta?
    /// Есть ли следующая страница. Старый сервер признака не присылал — тогда false.
    var hasMore: Bool { meta?.hasMore ?? false }
    init(from decoder: Decoder) throws {
        items = try ListPayload<T>(from: decoder).items
    }
    func receive(meta: PageMeta?) { self.meta = meta }
}

// error приходит по-разному: строкой ("текст") — core/Response.php (Response::error),
// ИЛИ объектом {message} — часть эндпоинтов. Толерантно принимаем обе формы,
// иначе понятный текст (напр. «Минимальная сумма заказа…») терялся и показывалось «Ошибка 422».
struct APIErr: Decodable {
    let message: String?
    /// details из v1err: словарь строк. Нужен для 409 «не хватает на кошельке»
    /// — там приходят need / balance / missing, и без них экран не смог бы
    /// написать «пополните на 269 ₽». Другие формы details (например список
    /// сообщений по полям) декодируются в nil и никому не мешают.
    let details: [String: String]?
    /// П-27.14: машинный код ошибки v1 (`idempotency_in_progress`,
    /// `idempotency_key_reused`…). Нет — nil, всё как раньше.
    let code: String?
    /// А114: что нужно прислать («password», «new_email») — рядом с message,
    /// а не в details (v1NeedErr). Нет — nil.
    let need: String?
    /// А114: исправленный адрес при 422 email_invalid («ivan@gmail.com»);
    /// null у неживого адреса — nil.
    let suggestion: String?
    init(message: String?, details: [String: String]? = nil, code: String? = nil,
         need: String? = nil, suggestion: String? = nil) {
        self.message = message
        self.details = details
        self.code = code
        self.need = need
        self.suggestion = suggestion
    }
    init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self.message = s
            self.details = nil
            self.code = nil
            self.need = nil
            self.suggestion = nil
        } else if let c = try? decoder.container(keyedBy: CodingKeys.self) {
            self.message = try? c.decode(String.self, forKey: .message)
            self.details = try? c.decode([String: String].self, forKey: .details)
            self.code = try? c.decode(String.self, forKey: .code)
            self.need = try? c.decode(String.self, forKey: .need)
            self.suggestion = try? c.decode(String.self, forKey: .suggestion)
        } else {
            self.message = nil
            self.details = nil
            self.code = nil
            self.need = nil
            self.suggestion = nil
        }
    }
    private enum CodingKeys: String, CodingKey { case message, details, code, need, suggestion }
}

/// Журнал ошибок разбора ответа: Console.app / Xcode, категория «decode».
/// Пишет тип и путь поля — видно, какое именно поле разошлось с сервером.
enum DecodeLog {
    static let logger = Logger(subsystem: "ru.marketplace.client.premium", category: "decode")
    static func report(_ error: Error, _ type: Any.Type) {
        let what = String(describing: type)
        let why = describe(error)
        logger.error("Не разобран \(what, privacy: .public): \(why, privacy: .public)")
    }
    static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return String(describing: error) }
        func path(_ keys: [CodingKey]) -> String {
            keys.reduce("") { acc, key in
                if let i = key.intValue { return acc + "[\(i)]" }
                return acc.isEmpty ? key.stringValue : acc + "." + key.stringValue
            }
        }
        switch e {
        case .typeMismatch(let t, let ctx):  return "тип \(t) в \(path(ctx.codingPath))"
        case .valueNotFound(let t, let ctx): return "нет значения \(t) в \(path(ctx.codingPath))"
        case .keyNotFound(let k, let ctx):   return "нет ключа \(k.stringValue) в \(path(ctx.codingPath))"
        case .dataCorrupted(let ctx):        return "битые данные в \(path(ctx.codingPath))"
        @unknown default:                    return String(describing: e)
        }
    }
}

/// Элемент списка, который не роняет весь список: не разобрался — nil и запись в журнал.
struct LossyElement<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        do { value = try T(from: decoder) } catch { value = nil; DecodeLog.report(error, T.self) }
    }
}

// Список: массив или {items:[...], has_more}.
// Битую запись пропускаем (и пишем в журнал), а не теряем весь список: раньше одна
// запись с неожиданным типом поля давала пустой экран без единой ошибки.
struct ListPayload<T: Decodable>: Decodable {
    let items: [T]; let hasMore: Bool
    init(from decoder: Decoder) throws {
        if let arr = try? [LossyElement<T>](from: decoder) {
            items = arr.compactMap { $0.value }; hasMore = false; return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = ((try? c.decode([LossyElement<T>].self, forKey: .items)) ?? []).compactMap { $0.value }
        hasMore = (try? c.decode(LenientBool.self, forKey: .hasMore))?.wrappedValue ?? false
    }
    enum CodingKeys: String, CodingKey { case items, hasMore }
}

struct City: Codable, Identifiable, Hashable { let id: Int; let name: String?; let region: String? }
struct Banner: Codable, Identifiable {
    let id: Int; let imageWebp: String?; let title: String?; let link: String?
    var image: String? { imageWebp }
}
struct Category: Codable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let image: String?
    /// Категории ОРГАНИЗАЦИИ (ShopDetail.categories) дополнительно несут slug и
    /// признак лицензирования — по нему карточка медцентра/аптеки понимает,
    /// что должна показать номер лицензии. У категорий товаров этих полей нет.
    let slug: String?
    @LenientBool var requiresLicense: Bool?
}

struct Shop: Codable, Identifiable, Hashable {
    let id: Int; let slug: String?; let name: String?; let logo: String?; let cover: String?; let banner: String?
    @LenientDouble var rating: Double?; let category: String?; let deliveryTime: String?; @LenientBool var isOpen: Bool?; let shopMode: String?; let address: String?
    @LenientInt var avgCookTime: Int?; @LenientInt var reviewsCount: Int?
    /// Тип заведения (shop | cafe | service …, ключ type — api_v1.php shops/organizations).
    /// Паритет с Android; аддитивно, нет ключа — nil.
    let type: String?
    // Буст-продвижение (Фаза 3.1, аддитивно): 1 = показать бейдж «Реклама».
    @LenientInt var isPromoted: Int?
    /// Способы получения (аддитивно). Коды: у товаров и еды — delivery | pickup |
    /// dine_in, у услуг — at_business | at_client. Пусто = заведение ничего не
    /// настроило. Для иконок; текст под названием берём из fulfillmentLabel.
    let fulfillment: [String]?
    /// Готовая подпись от сервера: «Доставка и самовывоз», «Только самовывоз»,
    /// «На месте и с выездом». Собирается на сервере, чтобы сайт, Android и iOS
    /// писали одно и то же и формулировку можно было менять без пересборки.
    let fulfillmentLabel: String?
    /// Витринные признаки для фильтров и сортировок (аддитивно, Фаза 4).
    /// Раньше чипы «Бесплатная доставка» и сортировки «Ближе ко мне» /
    /// «Сначала недорогие» были нарисованы, но не работали: таких полей в
    /// ответе не было вовсе.
    ///   freeDelivery — есть зона доставки с нулевой ценой;
    ///   avgCheck     — средний чек за 90 дней (или средняя цена товара);
    ///   distanceKm   — расстояние от адреса доставки, если мы его прислали.
    /// Старый сервер полей не шлёт → nil, и чип ничего не отбрасывает.
    @LenientBool var freeDelivery: Bool?
    @LenientDouble var avgCheck: Double?
    @LenientDouble var distanceKm: Double?
}
// Категория организации (магазин/услуга). Ключи snake_case декодируются авто-конвертером — CodingKeys НЕ добавляем.
struct OrgCategory: Codable, Identifiable, Hashable {
    let id: Int; let slug: String?; let name: String?; let icon: String?
    @LenientInt var count: Int?
    @LenientBool var requiresLicense: Bool?
}

// Заявка на регистрацию организации из приложения («стать продавцом»).
// Тело кодируется .convertToSnakeCase: orgName→org_name, fullName→full_name, cityId→city_id.
struct OrgApplyBody: Encodable {
    let orgName: String
    let fullName: String
    let phone: String
    let type: String            // store | restaurant | service (канон API)
    let cityId: Int?
    /// П-23.5: почта и код из письма — нужны только НОВОМУ владельцу
    /// (телефона нет в базе). nil в JSON не попадает.
    var email: String? = nil
    var emailCode: String? = nil
}
struct OrgApplyResult: Decodable {
    @LenientInt var registrationId: Int?
    let status: String?          // "pending"
    /// П-23.5: заявка уже подана и ждёт разбора (200 duplicate: true).
    @LenientBool var duplicate: Bool?
    // Волна А75: сервер сразу активирует организацию (поля аддитивные).
    // approved == true — организация создана, можно входить в приложение
    // продавца; нет поля (старый сервер) — nil, экран как раньше.
    @LenientBool var approved: Bool?
    @LenientBool var canLogin: Bool?
    /// Текст сервера: что делать дальше (в т.ч. «Пароль … по ссылке из письма»).
    let message: String?
}
// ── Лицензия организации ────────────────────────────────────────────────────
// Медцентр, стоматология, аптека, ветклиника, автошкола обязаны показывать
// клиенту номер лицензии и дату выдачи. Сервер отдаёт готовый блок license
// (самый свежий одобренный документ с номером) и полный список documents.
struct OrgDocument: Codable, Identifiable {
    let id: Int
    let title: String?
    let url: String?
    @LenientInt var categoryId: Int?
    let category: String?
    let licenseNumber: String?
    let issuedAt: String?        // "2026-09-13"
    let issuedBy: String?
    let validUntil: String?
}

struct OrgLicense: Codable {
    let number: String?
    let issuedAt: String?
    let issuedBy: String?
    let validUntil: String?
    let title: String?
    let category: String?
    let url: String?
}

struct ShopDetail: Codable, Identifiable {
    let id: Int; let slug: String?; let name: String?; let logo: String?; let cover: String?; let banner: String?
    // Режим организации: "service" = запись на услуги, иначе магазин/меню (аддитивно, как на Android).
    let mode: String?
    // Кол-во оценок для сводки отзывов (аддитивно; сервер отдаёт reviews_count).
    @LenientInt var reviewsCount: Int?
    /// Среднее время приготовления, мин (avg_cook_time, api_v1.php:529). Паритет
    /// с Android; толерантно к строке/null.
    @LenientInt var avgCookTime: Int?
    let description: String?; let address: String?; let phone: String?; @LenientDouble var rating: Double?
    @LenientDouble var lat: Double?; @LenientDouble var lng: Double?; let hours: [ShopHour]?
    @LenientDouble var deliveryFee: Double?; @LenientDouble var minOrder: Double?; let deliveryTime: String?; let categories: [Category]?
    let deliveryZones: [DeliveryZone]?
    @LenientDouble var serviceFeePercent: Double?; let serviceFeePayer: String?; let serviceFeeType: String?; @LenientDouble var serviceFeeFixed: Double?
    /// Лицензия (аддитивно). requiresLicense — организация в лицензируемой
    /// категории; license — реквизиты, если организация их опубликовала.
    @LenientBool var requiresLicense: Bool?
    let license: OrgLicense?
    let documents: [OrgDocument]?
    /// Способы получения — те же коды и подпись, что в списке (аддитивно).
    let fulfillment: [String]?
    let fulfillmentLabel: String?
    /// Открыто ли заведение ПРЯМО СЕЙЧАС и подпись статуса — считает сервер.
    /// Считать это на телефоне нельзя: часы работы заданы временем заведения, а
    /// у покупателя в другом часовом поясе «сейчас» своё, и карточка показывала
    /// «Открыто» у закрытого заведения (и наоборот).
    @LenientBool var isOpen: Bool?
    let statusText: String?
    /// Какие способы оплаты заведение принимает (cash / card_courier / sbp / online_card).
    /// Без них экран рисовал все варианты, а сервер отказывал уже на последнем шаге.
    let paymentMethods: [String]?
    /// График по дням (0 = Вс … 6 = Сб) — для предзаказа у закрытого заведения.
    let statusSchedule: [ScheduleDay]?
    /// П-27.1 (А68): настраивало ли заведение способы оплаты / получения.
    /// false или нет поля (старый сервер) — «не настраивали», доступны все, как
    /// раньше; true и пустой список — этот шаг заведение не принимает.
    /// Сам список delivery_methods[] не разбираем: типы уже есть в fulfillment,
    /// а нужные данные самовывоза и зала сервер дублирует полями ниже.
    @LenientBool var paymentMethodsConfigured: Bool?
    @LenientBool var deliveryMethodsConfigured: Bool?
    /// Для заказа в зале нужен номер стола (настройка заведения).
    @LenientBool var dineInTableRequired: Bool?
    /// Адрес и пояснение самовывоза; адрес null — забирать по адресу заведения.
    let pickupAddress: String?
    let pickupComment: String?
}
/// День графика заведения: open/close — "HH:MM[:SS]" или nil (часы не заданы).
struct ScheduleDay: Codable, Hashable {
    @LenientInt var dow: Int?
    @LenientBool var isClosed: Bool?
    let open: String?
    let close: String?
}
/// Зона доставки заведения. Сервер отдаёт массив `delivery_zones` в карточке магазина.
struct DeliveryZone: Codable, Identifiable, Hashable {
    var id: String { name ?? "—" }
    let name: String?
    @LenientDouble var deliveryPrice: Double?
    @LenientDouble var minOrder: Double?
    @LenientDouble var freeFrom: Double?
    @LenientInt var deliveryTimeMin: Int?
    @LenientInt var deliveryTimeMax: Int?
}

// Серверный расчёт доставки по адресу (POST /api/v1/delivery/quote).
// ВАЖНО: API-декодер использует .convertFromSnakeCase, поэтому НЕ задаём явные
// CodingKeys (иначе двойная конвертация: delivery_price → deliveryPrice не находит ключ
// "delivery_price", и поля молча становятся nil — доставка показывалась «бесплатно»).
// Имена свойств в camelCase автоматически маппятся на snake_case сервера.
struct DeliveryQuote: Codable {
    let available: Bool
    let zone: String?
    @LenientDouble var deliveryPrice: Double?
    @LenientDouble var minOrder: Double?
    let belowMin: Bool?
    @LenientDouble var freeFrom: Double?
    let freeApplies: Bool?
    @LenientInt var timeMin: Int?
    @LenientInt var timeMax: Int?
    let reason: String?
    // Аддитивно: true — цена не по зоне, а единая по городу заведения.
    let flat: Bool?
    let city: String?
}

// Подсказка адреса с сервера (GET /api/address/suggest?q=…) — прокси Dadata, токен на сервере.
struct AddrSuggest: Codable, Identifiable {
    let value: String?
    let city: String?
    let street: String?
    let house: String?
    @LenientDouble var lat: Double?
    @LenientDouble var lng: Double?
    var id: String { value ?? "" }
}
struct ShopHour: Codable, Hashable, Identifiable {
    var id: Int { dayOfWeek ?? 0 }
    @LenientInt var dayOfWeek: Int?; let openTime: String?; let closeTime: String?; @LenientInt var isClosed: Int?
}
struct Product: Codable, Identifiable, Hashable {
    let id: Int; let name: String?; @LenientDouble var price: Double?; @LenientDouble var oldPrice: Double?
    let description: String?; let photo: String?; @LenientInt var categoryId: Int?; let hasMods: Bool?; @LenientInt var shopId: Int?
    let unit: String?
    @LenientBool var isHalal: Bool?
    /// Позиция в стоп-листе (закончилась). Сервер отдаёт stopped в меню магазина;
    /// раньше приложение его не знало — товар клали в корзину, а оформление
    /// отклонялось «Часть товаров закончилась» без указания какой.
    @LenientBool var stopped: Bool?
    /// Платное продвижение товара (аддитивно, 1 = показать бейдж «Реклама»).
    /// Сервер ставит продвинутые товары в начало выдачи поиска — подъём обязан
    /// быть помечен, иначе это неотмеченная реклама.
    @LenientInt var isPromoted: Int?
    /// Меню магазина (`shops/{slug}/products`) отдаёт старую цену в `price_old`,
    /// а `old_price` там null: фильтр «Скидки» был всегда пустым.
    @LenientDouble var priceOld: Double?
    /// Старая цена из любого из двух ключей.
    var oldPriceAny: Double? { oldPrice ?? priceOld }
    /// П-22.3 (А58): название заведения в умном поиске и избранных товарах.
    /// Нет поля (старый сервер, меню магазина) — nil, строка не показывается.
    let shopName: String?
}
struct ComboItem: Codable {
    let name: String?; @LenientInt var qty: Int?; @LenientDouble var price: Double?; let photo: String?
}
struct ProductDetail: Codable, Identifiable {
    let id: Int; let name: String?; @LenientDouble var price: Double?; @LenientDouble var oldPrice: Double?
    let description: String?; let photos: [MediaPhoto]?; let modifierGroups: [ModifierGroup]?; @LenientInt var shopId: Int?; let shopName: String?; let shopSlug: String?
    let comboItems: [ComboItem]?
    let unit: String?; @LenientInt var qtyFractional: Int?; @LenientDouble var qtyStep: Double?; let qtyPresets: String?
    @LenientBool var isHalal: Bool?
    /// Позиция закончилась (стоп-лист) или выключена продавцом. Раньше карточка
    /// этого не знала: кнопка «В корзину» работала, человек набирал корзину, а
    /// отказ приходил только на оформлении и без указания позиции.
    @LenientBool var stopped: Bool?
    /// А65: категория товара выключена продавцом — товар недоступен (сервер
    /// ставит и stopped, флаг читаем на случай расхождения). Нет поля — nil.
    @LenientBool var categoryOff: Bool?
    /// А428: закончился у магазина, который не продаёт в минус (или набор с
    /// остановленным компонентом) — «Закончился»; сервер тогда ставит и stopped.
    /// Нет поля (старый сервер) — nil, как раньше.
    @LenientBool var outOfStock: Bool?
}
struct ModifierGroup: Codable, Identifiable {
    let id: Int; let name: String?; let type: String?; @LenientBool var isRequired: Bool?
    @LenientInt var minQty: Int?; @LenientInt var maxQty: Int?; let options: [ModifierOption]?
}
struct ModifierOption: Codable, Identifiable, Hashable { let id: Int; let name: String?; @LenientDouble var price: Double?; let photoWebp: String? }
struct MediaPhoto: Codable, Hashable { let pathWebp: String? }

// clientCode — карта клиента: личный штрихкод (EAN-13), который кассир
// сканирует в магазине. Сервер выдаёт его при первом открытии профиля и больше
// не меняет. Старый сервер поля не отдаёт — остаётся nil, блок не рисуется.
// avatar — путь к фото профиля (api_v1.php:1652), паритет с Android; nil — нет фото.
struct Profile: Codable { @LenientInt var id: Int?; let name: String?; let phone: String?; let email: String?; @LenientDouble var bonusBalance: Double?; let clientCode: String?; let avatar: String?
    /// А114: почта подтверждена кодом (true / false; null — почты нет или старый сервер).
    @LenientBool var emailVerified: Bool?
    /// А114: письма на почту не доходят — null | "typo" | "undeliverable". Старый сервер — nil.
    var emailProblem: String? = nil
}
struct Address: Codable, Identifiable {
    let id: Int; let label: String?; let city: String?; let street: String?; let house: String?
    let apartment: String?; let entrance: String?; let floor: String?; let intercom: String?
    @LenientDouble var lat: Double?; @LenientDouble var lng: Double?; @LenientInt var isDefault: Int?
    var display: String {
        [city, street, house.map { "д. \($0)" }, apartment.map { "кв. \($0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
    var isDefaultBool: Bool { (isDefault ?? 0) > 0 }
}

struct Order: Codable, Identifiable {
    let id: Int; @LenientInt var dailyNumber: Int?; let status: String?; @LenientDouble var total: Double?
    let createdAt: String?; let shopName: String?; let shopLogo: String?
    /// Запись на услугу. На сервере запись хранится как заказ, поэтому она приходила
    /// и сюда, и должна была прийти в «Мои записи». Признак is_appointment позволяет
    /// показать её ровно в одном разделе — в «Моих записях» (см. OrdersViewModel.load).
    /// Поле аддитивное: у старого ответа без него значение nil → заказ обычный.
    @LenientBool var isAppointment: Bool?
    /// Тип организации: shop | cafe | service. Поле аддитивное (сервер отдаёт
    /// его в /api/v1/orders). Одно и то же состояние называется по-разному:
    /// кафе готовит, магазин собирает, салон работает — раньше клиент писал
    /// «Готовится» даже для записи в барбершоп.
    let shopType: String?
    /// Подпись статуса от сервера (словами типа организации) и способ получения —
    /// сервер шлёт оба, раньше не читались: неизвестный код статуса показывался
    /// латиницей, а самовывоз в списке подписывался «доставлен».
    let statusTitle: String?
    let deliveryType: String?
    /// Предзаказ «ко времени»: "YYYY-MM-DD HH:MM:SS" по Москве или null (П-24 №7).
    /// Список отдаёт поле, если сервер его шлёт; нет — nil, карточка как раньше.
    let preorderAt: String?
}

/// Запись клиента на услугу — GET api/v1/appointments (экран «Мои записи»).
///
/// Раньше этого эндпоинта не существовало (был только POST на создание), поэтому
/// BookingsView стоял пустой заглушкой. Форма ответа повторяет продавцовый
/// GET /api/seller/bookings: те же date / time_start / time_end / service / master / status.
///
/// `id` — это id ОКНА (service_slots.id), а `orderId` — id заказа, которым запись
/// хранится на сервере: он нужен для отмены (POST api/v1/orders/{id}/cancel).
struct Appointment: Codable, Identifiable {
    let id: Int
    @LenientInt var orderId: Int?
    let date: String?           // "2026-09-06"
    let timeStart: String?      // "15:00:00"
    let timeEnd: String?
    @LenientInt var serviceId: Int?
    let service: String?
    @LenientDouble var price: Double?
    @LenientInt var durationMin: Int?
    let master: String?
    let masterPhoto: String?
    /// Человек в брони и сколько окон она занимает (аддитивно, по умолчанию 1).
    @LenientInt var guests: Int?
    @LenientInt var slots: Int?
    let status: String?         // new | accepted | done | cancelled
    @LenientDouble var total: Double?
    @LenientInt var shopId: Int?
    let shop: String?
    let shopSlug: String?
    let shopLogo: String?
    let shopAddress: String?
    let shopPhone: String?
    @LenientDouble var shopLat: Double?
    @LenientDouble var shopLng: Double?
    /// Адрес визита строкой — у выездной услуги клиенту нужно видеть, куда
    /// приедет мастер. У услуги в заведении сервер шлёт пустую строку
    /// (api_v1.php: formatVisitAddress), поэтому проверяем на пустоту.
    let address: String?
    /// Считает сервер — чтобы табы «Предстоящие / Прошедшие» одинаково делились
    /// на всех платформах и не зависели от часового пояса телефона.
    @LenientBool var isPast: Bool?
    /// А63: комментарий клиента мастеру (то, что ввели при записи). null — нет.
    let clientComment: String?
}
struct OrderItem: Codable, Identifiable {
    /// order_items.id — настоящий, стабильный ключ строки. Появился вместе с
    /// правкой состава заказа (миграция 2026_09_order_edit.sql). Пока сервер его
    /// не отдавал, id приходилось выводить из productId и qty, из-за чего смена
    /// количества выглядела для SwiftUI как удаление строки и вставка новой.
    @LenientInt var lineId: Int?
    @LenientInt var productId: Int?
    let name: String?
    @LenientDouble var qty: Double?
    /// Сколько заказывал КЛИЕНТ. Отличается от qty, если продавец правил заказ.
    @LenientDouble var qtyOrdered: Double?
    @LenientDouble var price: Double?
    let unit: String?
    /// А115 (П-60 №7), только GET api/v1/orders/{id}, строкой «0.000»:
    /// return_qty — уже одобренный возврат, return_pending_qty — в заявке,
    /// ждущей решения магазина, returnable_qty — сколько ещё можно вернуть
    /// (максимум в форме возврата). nil — старый сервер, тогда как раньше.
    @LenientDouble var returnQty: Double?
    @LenientDouble var returnPendingQty: Double?
    @LenientDouble var returnableQty: Double?

    // Ключи камелкейсом: декодер работает с .convertFromSnakeCase, он уже
    // превратил product_id → productId. Явно переименовываем только id → lineId.
    enum CodingKeys: String, CodingKey {
        case lineId = "id"
        case productId, name, qty, qtyOrdered, price, unit
        case returnQty, returnPendingQty, returnableQty
    }

    var id: Int { lineId ?? ((productId ?? 0) &* 100000 &+ Int((qty ?? 0).rounded())) }

    /// Количество отличается от заказанного — позицию правил продавец.
    var quantityChanged: Bool {
        guard let was = qtyOrdered, let now = qty else { return false }
        return abs(was - now) > 0.0005
    }
}

// ── Правки заказа продавцом/кассой (аддитивно) ──────────────────────────────
// Клиент заказал 1 кг помидоров, в магазине оказалось 700 г. Сервер хранит
// историю правок, а мы показываем её отдельным блоком: человек должен видеть
// не только новый состав, но и чем он отличается от заказанного.
struct OrderChangeLine: Codable, Identifiable {
    let op: String?                  // qty | remove
    @LenientInt var itemId: Int?
    let name: String?
    let unit: String?
    @LenientDouble var qtyBefore: Double?
    @LenientDouble var qtyAfter: Double?
    @LenientDouble var price: Double?
    @LenientDouble var sumBefore: Double?
    @LenientDouble var sumAfter: Double?
    var id: String { "\(itemId ?? 0)|\(name ?? "")|\(qtyAfter ?? 0)" }
}

struct OrderChange: Codable, Identifiable {
    @LenientInt var rev: Int?
    let at: String?
    let actorType: String?           // pos | seller | system
    let actor: String?
    let reason: String?
    @LenientDouble var totalBefore: Double?
    @LenientDouble var totalAfter: Double?
    let lines: [OrderChangeLine]?
    let text: String?                // готовая строка на случай, если рисовать построчно негде
    var id: Int { rev ?? 0 }
}
struct OrderDetail: Codable, Identifiable {
    let id: Int; @LenientInt var dailyNumber: Int?; let status: String?; @LenientDouble var total: Double?
    let deliveryType: String?; let paymentType: String?; let address: String?
    /// pending | paid | … — чтобы не показывать «Оплатить» у оплаченного заказа.
    let paymentStatus: String?
    let createdAt: String?; let shopName: String?; let items: [OrderItem]?
    @LenientDouble var subtotal: Double?; @LenientDouble var deliveryPrice: Double?; @LenientDouble var serviceFee: Double?
    @LenientDouble var tip: Double?; @LenientDouble var discount: Double?; let promoCode: String?
    // Баллы по заказу (points_spent / points_earned маппятся через .convertFromSnakeCase).
    @LenientDouble var pointsSpent: Double?; @LenientDouble var pointsEarned: Double?
    /// Тип организации: shop | cafe | service (аддитивно, см. Order.shopType).
    let shopType: String?
    /// Ревизия состава и история правок (аддитивно). Пусто — заказ не правили.
    @LenientInt var rev: Int?
    let changes: [OrderChange]?
    /// Подпись статуса и шаги с временем перехода — сервер шлёт их словами типа
    /// организации (как читает Android). Раньше не читались: у самовывоза и
    /// услуг в таймлайне стояли «Курьер в пути» и «Доставлен».
    let statusTitle: String?
    let statusTimeline: OrderTimeline?
    /// П-23.1 (А58): отзыв по заказу. nil — старый сервер, тогда прежняя логика
    /// (форма у завершённого заказа, 409 при отправке = «уже оставлен»).
    @LenientBool var hasReview: Bool?
    @LenientInt var reviewId: Int?
    @LenientBool var canReview: Bool?
    /// Предзаказ «ко времени»: "YYYY-MM-DD HH:MM:SS" по Москве или null (П-24 №7).
    /// Задан — ETA сервер не считает, показываем время предзаказа.
    let preorderAt: String?
    /// А63: комментарий клиента к записи на услугу (только его текст). null —
    /// обычный заказ или запись без комментария.
    let clientComment: String?
    /// П-24 №2 (А62): NPS по заказу уже поставлен (оценка 0 — тоже да) и сама
    /// оценка. nil — старый сервер, форма NPS как раньше.
    @LenientBool var hasNps: Bool?
    @LenientInt var npsScore: Int?
    /// «Сдача с …» — то, что клиент указал при оплате наличными (change_from).
    /// GET api/v1/orders/{id} отдаёт o.*, поле payment_note (api_v1.php). nil — не указано.
    let paymentNote: String?
    /// А115 (П-60 №8): бронь жилья (orderStayInfo). null у обычного заказа и у
    /// старого сервера — тогда как раньше. Битое поле карточку не роняет.
    let stay: OrderStay?
}
/// `stay` карточки заказа: {date_from, date_to, nights, adults, children, unit,
/// check_in_from, check_out_until, status}. status — статус самой брони:
/// pending / confirmed / checked_in / checked_out / cancelled / no_show
/// (мгновенная бронь уже confirmed, хотя заказ ещё new). Разбор терпимый:
/// любое поле может отсутствовать, не тот тип — nil, а не ошибка карточки.
struct OrderStay: Codable {
    var dateFrom: String?
    var dateTo: String?
    var nights: Int?
    var adults: Int?
    var children: Int?
    var unit: String?
    var checkInFrom: String?
    var checkOutUntil: String?
    var status: String?

    private enum CodingKeys: String, CodingKey {
        case dateFrom, dateTo, nights, adults, children, unit, checkInFrom, checkOutUntil, status
    }
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        func str(_ k: CodingKeys) -> String? { (try? c.decodeIfPresent(String.self, forKey: k)) ?? nil }
        func int(_ k: CodingKeys) -> Int? { ((try? c.decodeIfPresent(LenientInt.self, forKey: k)) ?? nil)?.wrappedValue }
        dateFrom = str(.dateFrom); dateTo = str(.dateTo)
        nights = int(.nights); adults = int(.adults); children = int(.children)
        unit = str(.unit); checkInFrom = str(.checkInFrom); checkOutUntil = str(.checkOutUntil)
        status = str(.status)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(dateFrom, forKey: .dateFrom); try c.encodeIfPresent(dateTo, forKey: .dateTo)
        try c.encodeIfPresent(nights, forKey: .nights); try c.encodeIfPresent(adults, forKey: .adults)
        try c.encodeIfPresent(children, forKey: .children); try c.encodeIfPresent(unit, forKey: .unit)
        try c.encodeIfPresent(checkInFrom, forKey: .checkInFrom); try c.encodeIfPresent(checkOutUntil, forKey: .checkOutUntil)
        try c.encodeIfPresent(status, forKey: .status)
    }
    /// Код статуса брони в нижнем регистре; пусто — nil.
    var statusCode: String? {
        let s = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.isEmpty ? nil : s
    }
}
/// Шаг `status_timeline`: {code, title, at}.
struct OrderTimelineStep: Codable {
    let code: String?
    let title: String?
    let at: String?
}
/// Таймлайн, который не роняет карточку заказа: битый шаг или другая форма
/// поля дают пустой список, а не «не удалось загрузить заказ».
struct OrderTimeline: Codable {
    let steps: [OrderTimelineStep]
    init(from decoder: Decoder) throws {
        steps = ((try? [LossyElement<OrderTimelineStep>](from: decoder)) ?? []).compactMap { $0.value }
    }
    func encode(to encoder: Encoder) throws { try steps.encode(to: encoder) }
    /// Шаг по коду статуса (первый с таким кодом).
    func step(_ code: String) -> OrderTimelineStep? { steps.first { $0.code == code } }
}
/// GET api/v1/orders/{id}/track.
///
/// Сервер отдаёт положение курьера ВЛОЖЕННЫМ объектом:
///   {"status":"in_delivery","courier":{"lat":55.7,"lng":37.6,"updated_at":"…"},"eta_minutes":7}
/// Раньше здесь ждали плоские courier_lat / courier_lng — таких ключей в ответе
/// нет и не было, поэтому метка курьера на карте не появлялась ни разу.
/// Имя и телефон курьера ручка сейчас не отдаёт: поля объявлены опциональными,
/// чтобы блок «Позвонить курьеру» заработал сам, когда сервер начнёт их слать.
struct TrackData: Codable {
    struct CourierLoc: Codable {
        @LenientDouble var lat: Double?
        @LenientDouble var lng: Double?
        let updatedAt: String?
        let name: String?
        let phone: String?
    }
    let status: String?
    let courier: CourierLoc?
    @LenientInt var etaMinutes: Int?

    var courierLat: Double? { courier?.lat }
    var courierLng: Double? { courier?.lng }
    var courierName: String? { courier?.name }
    var courierPhone: String? { courier?.phone }
}
struct ChatMessage: Codable, Identifiable {
    @LenientInt var id: Int?; let message: String?; let sender: String?; let createdAt: String?
    @LenientBool var mine: Bool?        // сервер отдаёт mine — источник правды «моё сообщение»
    let attachment: String?             // относительный webp-путь фото (nil = текст)
    @LenientBool var read: Bool?        // прочитано контрагентом (для моих сообщений → ✓✓)
    let senderName: String?
    var stableId: String { "\(id ?? 0)-\(createdAt ?? "")" }
    // Локальные (ещё не отправленные / ошибка) сообщения — для оптимистичного UI.
    var localState: String? = nil       // nil=с сервера, "sending", "failed"
    var localImage: Data? = nil         // локальное фото до загрузки (превью)
}

// Диалог в списке чатов: GET /api/v1/chats.
struct ChatDialog: Codable, Identifiable {
    @LenientInt var orderId: Int?
    @LenientInt var dailyNumber: Int?
    let status: String?
    let shopName: String?
    let shopLogo: String?
    let lastMessage: String?
    let lastAttachment: String?
    let lastAt: String?
    @LenientInt var unreadCount: Int?
    var id: Int { orderId ?? 0 }
}
struct BonusInfo: Codable { @LenientDouble var balance: Double?; let history: [BonusRow]? }
struct BonusRow: Codable, Identifiable { @LenientInt var id: Int?; @LenientDouble var amount: Double?; let reason: String?; let createdAt: String?
    var stableId: Int { id ?? 0 } }
// Баланс баллов по магазину (ответ /profile/bonuses — массив).
struct BonusShopBalance: Codable { @LenientInt var shopId: Int?; let shop: String?; @LenientDouble var balance: Double?
    /// П-25 №3: shop_id здесь всегда число и уникален — ключ строки списка.
    var rowKey: String { shopId.map { "s\($0)" } ?? "n-\(shop ?? "")" } }
// Операция по баллам (ответ /profile/bonuses/history).
// П-22.4: amount — строка "10.00", читаем точным Decimal (знак у старых строк бывает неверным).
struct BonusTx: Codable { @LenientInt var id: Int?; let shop: String?; let type: String?; @LenientDecimal var amount: Decimal?; let createdAt: String?
    var stableId: String { "\(id ?? 0)-\(createdAt ?? "")" } }
struct AppNotification: Codable, Identifiable { let id: Int; let type: String?; let title: String?; let body: String?; @LenientInt var isRead: Int?; let createdAt: String?
    var read: Bool { (isRead ?? 0) > 0 }
    /// Волна 4313: data_json строки ленты — те же ключи, что в data push
    /// (order_id, slug, screen…). Без него строка никуда не вела.
    @NotifDataText var dataJson: String? }

/// Волна 4313: data_json приходит строкой с JSON или null (ОТВЕТЫ-САЙТА П-21 №2).
/// Другой тип (объект) не роняет разбор всей ленты — просто nil.
@propertyWrapper
struct NotifDataText: Codable, Hashable {
    var wrappedValue: String?
    init(wrappedValue: String?) { self.wrappedValue = wrappedValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = c.decodeNil() ? nil : (try? c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Старый сервер data_json не шлёт — нет ключа = nil, а не ошибка.
    func decode(_ type: NotifDataText.Type, forKey key: Key) throws -> NotifDataText {
        (try? decodeIfPresent(type, forKey: key)) ?? NotifDataText(wrappedValue: nil)
    }
}

extension AppNotification {
    /// Волна 4313: data_json → словарь для AppDelegate.openNotification — строка
    /// ленты ведёт туда же, куда push. Пусто / «[]» / мусор — пустой словарь.
    var notifPayload: [AnyHashable: Any] {
        guard let s = dataJson, let d = s.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        var out: [AnyHashable: Any] = [:]
        for (k, v) in obj { out[k] = v }
        return out
    }
}
struct OrderCreateResult: Codable {
    @LenientInt var id: Int?; @LenientInt var dailyNumber: Int?
    // Сервер возвращает id созданного заказа под ключом order_id (→ orderId после
    // convertFromSnakeCase). Раньше читали только id → nil → трекинг открывал id=0
    // («заказ не найден»). Теперь резолвим оба.
    @LenientInt var orderId: Int?
    /// Итоговый id заказа: сначала order_id, затем id.
    var resolvedId: Int? { orderId ?? id }
    // Движок акций: применённые акции/подарки/баллы (аддитивно, optional).
    var promotions: [AppliedPromo]? = nil
    var gifts: [PromoGift]? = nil
    var pointsSpent: Double? = nil
    var pointsEarned: Double? = nil
    /// П-22.2 (А58): фактический способ получения, срок в минутах и время
    /// предзаказа. Всё необязательно: старый сервер и повтор (duplicate) —
    /// eta = nil, тогда экран успеха срок не показывает.
    var deliveryType: String? = nil
    var etaMin: Int? = nil
    var etaMax: Int? = nil
    var preorderAt: String? = nil
    /// AT-3: true — заказ по этому ключу уже был создан раньше (повтор после
    /// обрыва связи): сервер вернул его, второй не создан (api_v1.php, v1DupOrderReply).
    var duplicate: Bool? = nil

    enum CodingKeys: String, CodingKey { case id, dailyNumber, orderId, promotions, gifts, pointsSpent, pointsEarned
        case deliveryType, etaMin, etaMax, preorderAt, duplicate }
    /// Когда приходит этот ответ, заказ УЖЕ создан. Раньше любое поле акций не
    /// того типа (строка "0.00" вместо числа, null в имени акции) роняло разбор
    /// целиком: человек видел «Не удалось обработать ответ», корзина оставалась,
    /// и казалось, что заказа нет. Для экрана успеха нужен только номер —
    /// дополнительные поля разбираем мягко.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        _id = try c.decode(LenientInt.self, forKey: .id)
        _dailyNumber = try c.decode(LenientInt.self, forKey: .dailyNumber)
        _orderId = try c.decode(LenientInt.self, forKey: .orderId)
        promotions = try? c.decodeIfPresent([AppliedPromo].self, forKey: .promotions)
        gifts = try? c.decodeIfPresent([PromoGift].self, forKey: .gifts)
        pointsSpent = try c.decode(LenientDouble.self, forKey: .pointsSpent).wrappedValue
        pointsEarned = try c.decode(LenientDouble.self, forKey: .pointsEarned).wrappedValue
        // П-22.2: мягко — не того типа = nil, заказ всё равно «оформлен».
        deliveryType = (try? c.decodeIfPresent(String.self, forKey: .deliveryType)) ?? nil
        etaMin = try c.decode(LenientInt.self, forKey: .etaMin).wrappedValue
        etaMax = try c.decode(LenientInt.self, forKey: .etaMax).wrappedValue
        let pre = (try? c.decodeIfPresent(String.self, forKey: .preorderAt)) ?? nil
        preorderAt = (pre?.trimmingCharacters(in: .whitespaces).isEmpty ?? true) ? nil : pre
        duplicate = (try? c.decodeIfPresent(Bool.self, forKey: .duplicate)) ?? nil
    }
}
// Ответ создания онлайн-платежа (YooKassa). Декодер сам делает snake_case → CodingKeys не нужны.
struct PayOnlineResp: Codable { let confirmationUrl: String?; let paymentId: String? }

// ---- Доска объявлений (routes/ads.php) ----
// Декодер делает snake_case → camelCase сам, CodingKeys не нужны.
// Деньги — @LenientDecimal (точный Decimal из строки "0.00"), не Double.
// price у объявления ОПЦИОНАЛЬНА: «цена не указана» — это не ноль, и
// price_text уже приходит готовой строкой, чтобы все клиенты писали одинаково.
struct AdCategory: Codable, Identifiable, Hashable {
    @LenientInt var id: Int?
    @LenientInt var parentId: Int?
    var name: String?
    var slug: String?
    var icon: String?
    @LenientDecimal var price: Decimal?      // стоимость размещения, ₽
    @LenientInt var days: Int?
    @LenientInt var maxPhotos: Int?
    var allowPrice: Bool?
    var children: [AdCategory]?

    var stableId: Int { id ?? 0 }
    var priceValue: Decimal { price ?? 0 }
    var daysValue: Int { days ?? 30 }
    var photosLimit: Int { maxPhotos ?? 8 }
    var priceAllowed: Bool { allowPrice ?? true }
}
struct AdCategoriesResponse: Codable {
    var categories: [AdCategory]?
    var enabled: Bool?
}
struct AdCard: Codable, Identifiable, Hashable {
    @LenientInt var id: Int?
    var title: String?
    @LenientDecimal var price: Decimal?
    var priceText: String?
    var isNegotiable: Bool?
    @LenientInt var categoryId: Int?
    var categoryName: String?
    var city: String?
    // Нужен форме правки, чтобы подставить город объявления в список.
    @LenientInt var cityId: Int?
    var photo: String?
    var photoThumb: String?
    @LenientInt var photosCount: Int?
    @LenientInt var viewsCount: Int?
    var publishedAt: String?
    var status: String?
    var expiresAt: String?
    var favorite: Bool?
    // Только в «моих объявлениях»
    @LenientDecimal var renewPrice: Decimal?
    @LenientInt var renewDays: Int?
    var blockReason: String?
    /// Раздел объявления выключили в админке: объявление активно, но в ленте его нет.
    @LenientBool var categoryOff: Bool?

    var stableId: Int { id ?? 0 }
    var photoURL: String? { (photo?.isEmpty == false ? photo : nil) ?? (photoThumb?.isEmpty == false ? photoThumb : nil) }
}
struct AdsFeedResponse: Codable {
    var items: [AdCard]?
    @LenientInt var total: Int?
    @LenientInt var page: Int?
    @LenientInt var pages: Int?
    var enabled: Bool?
}
struct AdPhoto: Codable, Identifiable, Hashable {
    @LenientInt var id: Int?
    var thumb: String?
    var card: String?
    var full: String?
    var stableId: Int { id ?? 0 }
}
struct AdAuthor: Codable, Hashable {
    @LenientInt var id: Int?
    var name: String?
    var since: String?
}
struct AdDetail: Codable, Identifiable {
    @LenientInt var id: Int?
    var title: String?
    @LenientDecimal var price: Decimal?
    var priceText: String?
    var isNegotiable: Bool?
    @LenientInt var categoryId: Int?
    var categoryName: String?
    var city: String?
    // Нужен форме правки, чтобы подставить город объявления в список.
    @LenientInt var cityId: Int?
    var status: String?
    @LenientInt var viewsCount: Int?
    var publishedAt: String?
    var expiresAt: String?
    var favorite: Bool?
    var description: String?
    // true — новое, false — б/у, nil — не указано. Толерантно к 0/1 и строкам:
    // строгий Bool не открыл бы карточку, если сервер пришлёт число.
    @LenientBool var conditionNew: Bool?
    var address: String?
    var contactName: String?
    // nil — владелец спрятал номер, он придёт по POST .../contact
    var contactPhone: String?
    var phoneHidden: Bool?
    @LenientInt var contactsCount: Int?
    var photos: [AdPhoto]?
    var author: AdAuthor?
    var isMine: Bool?
    @LenientDecimal var renewPrice: Decimal?
    @LenientInt var renewDays: Int?
    /// GET /api/v1/ads/{id} (routes/ads.php): можно ли публиковать — по действующему
    /// тарифу рубрики. nil — старый сервер без поля, считаем «можно».
    @LenientBool var canPublish: Bool?
    var publishBlockReason: String?
}
struct AdDetailResponse: Codable { var ad: AdDetail? }
struct MyAdsResponse: Codable {
    var items: [AdCard]?
    @LenientInt var active: Int?
    @LenientInt var maxActive: Int?
    @LenientDecimal var balance: Decimal?
}
/// Тело создания и правки. Деньги — строкой "0.00" (Money.wire), "" = цена не указана.
struct AdSaveBody: Encodable {
    /// П-26.6: nil — рубрику не шлём (правка в закрытом разделе: сервер
    /// оставляет прежнюю, а новый category_id там не принимается).
    let categoryId: Int?
    let title: String
    let description: String
    let price: String
    let isNegotiable: Bool
    let conditionNew: Bool?
    let address: String?
    let contactPhone: String
    let hidePhone: Bool
    // Сервер поле принимал всегда, но приложение его не слало: город брался из
    // профиля, и объявление о гараже в соседнем городе туда положить было
    // нельзя — при том что фильтр по городу в ленте есть.
    let cityId: Int?
    /// А485: 1 — создание с явным «Не указан» (cityId пустой): сервер не подставит
    /// город профиля. nil — ключ не уходит (как раньше). Старый сервер флаг не читает.
    var cityNone: Int? = nil

    // Явная запись полей: синтезированный Encodable выкидывает nil, а сервер
    // меняет поле, только если ключ пришёл. Очищенный адрес и «состояние не
    // указано» при правке раньше не сохранялись, хотя экран писал «Сохранено».
    enum CodingKeys: String, CodingKey {
        case categoryId, title, description, price, isNegotiable, conditionNew, address, contactPhone, hidePhone, cityId
        case cityNone
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(categoryId, forKey: .categoryId)
        try c.encode(title, forKey: .title)
        try c.encode(description, forKey: .description)
        try c.encode(price, forKey: .price)
        try c.encode(isNegotiable, forKey: .isNegotiable)
        try c.encode(conditionNew, forKey: .conditionNew)      // nil → null = «не указано»
        try c.encode(address ?? "", forKey: .address)          // "" → сервер очистит
        try c.encode(contactPhone, forKey: .contactPhone)
        try c.encode(hidePhone, forKey: .hidePhone)
        // Город: при правке «Не указан» приходит сюда как 0 (сервер пишет NULL),
        // при создании nil — ключ не уходит, сервер подставит город из профиля.
        try c.encodeIfPresent(cityId, forKey: .cityId)
        try c.encodeIfPresent(cityNone, forKey: .cityNone)
    }
}
struct AdCreatedResponse: Codable {
    @LenientInt var adId: Int?
    var status: String?
    @LenientDecimal var price: Decimal?
    @LenientInt var days: Int?
    @LenientInt var maxPhotos: Int?
    @LenientDecimal var balance: Decimal?
}
/// Ответ публикации. charged = 0 и free = true — включили бесплатно.
struct AdPublishResponse: Codable {
    @LenientInt var adId: Int?
    var status: String?
    @LenientDecimal var charged: Decimal?
    @LenientDecimal var balance: Decimal?
    var expiresAt: String?
    var free: Bool?
}
struct AdPhotoUploadedResponse: Codable {
    var photo: AdPhoto?
    @LenientInt var photosCount: Int?
}
struct AdContactResponse: Codable { var phone: String? }
struct AdFavoriteResponse: Codable { var favorite: Bool? }
struct AdReportBody: Encodable { let reason: String; let comment: String? }
/// Тело POST api/v1/ads/{id}/publish. expected_price — сумма, которую видел человек
/// (Money.wire): разошлась с ценой рубрики — сервер (Ads::publish) отвечает 409
/// details.reason = "price_changed", details.price = новая цена, ничего не списав.
/// renew = true — продление действующего (только по явному запросу). nil — ключ не уходит.
struct AdPublishBody: Encodable {
    let renew: Bool?
    let expectedPrice: String?
    enum CodingKeys: String, CodingKey { case renew, expectedPrice }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(renew, forKey: .renew)
        try c.encodeIfPresent(expectedPrice, forKey: .expectedPrice)
    }
}

// ---- Кошелёк клиента (routes/wallet.php) ----
// Декодер делает snake_case → camelCase сам, CodingKeys не нужны.
// Деньги — @LenientDecimal (точный Decimal из строки "0.00"), не Double.
// enabled=false: онлайн-оплата на площадке не настроена или схема кошелька ещё
// не накатана — экран показывает баланс и историю, но не предлагает пополнение.
struct WalletInfo: Codable {
    @LenientDecimal var balance: Decimal?
    var enabled: Bool?
    @LenientDecimal var minTopup: Decimal?
    @LenientDecimal var maxTopup: Decimal?
    var transactions: [WalletTx]?
}
struct WalletTx: Codable, Identifiable {
    @LenientInt var id: Int?
    var type: String?            // topup | order_pay | order_refund | correction
    var typeLabel: String?
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balanceAfter: Decimal?
    var description: String?
    @LenientInt var orderId: Int?
    var createdAt: String?
    var stableId: String { "\(id ?? 0)-\(createdAt ?? "")" }
}
/// POST api/v1/wallet/topup → ссылка на страницу оплаты ЮKassa.
struct WalletTopupCreated: Codable {
    @LenientInt var topupId: Int?
    @LenientDecimal var amount: Decimal?
    var confirmationUrl: String?
}
/// GET api/v1/wallet/topup/{id} — статус. Баланс поднимает только сервер и
/// только после подтверждения платежа провайдером.
struct WalletTopupStatus: Codable {
    @LenientInt var topupId: Int?
    var status: String?          // pending | confirmed | rejected
    @LenientDecimal var amount: Decimal?
    @LenientDecimal var balance: Decimal?
}
/// Тело POST api/v1/wallet/topup. method — необязательный предвыбор способа
/// («card» | «sbp»); без него открывается общая страница выбора ЮKassa.
struct WalletTopupBody: Encodable {
    let amount: String           // деньги на провод — строкой "0.00", как везде
    let method: String?
}

// ---- Возвраты ----
struct ReturnItem: Codable, Identifiable {
    let id: Int; @LenientInt var orderId: Int?; let type: String?; let reasonCode: String?
    let status: String?; @LenientDouble var refundAmount: Double?; let createdAt: String?; let shop: String?
    /// П-23.3 (А58): номер заказа за день (как видит клиент). nil — старые заказы/сервер.
    @LenientInt var orderDailyNumber: Int?
    /// П-24 №1 (А62): дата заказа "YYYY-MM-DD HH:MM:SS" (Москва) или null.
    let orderCreatedAt: String?
}
struct ReturnEligibility: Codable { let eligible: Bool?; @LenientInt var windowHours: Int?; let reason: String? }

// ---- Вакансии ----
struct Job: Codable, Identifiable {
    let id: Int; let title: String?; let category: String?
    @LenientDouble var salaryFrom: Double?; @LenientDouble var salaryTo: Double?; let employmentType: String?
    let experience: String?; let schedule: String?; let shop: String?
}
struct JobDetail: Codable, Identifiable {
    let id: Int; let title: String?; let category: String?
    @LenientDouble var salaryFrom: Double?; @LenientDouble var salaryTo: Double?; let description: String?; let requirements: String?
    let schedule: String?; let employmentType: String?; let experience: String?
    let shop: String?; let shopAddress: String?
    /// Условия работы и адрес самой вакансии — сервер шлёт, экран не показывал.
    let conditions: String?
    let address: String?
}

// ---- Услуги / запись ----
struct Master: Codable, Identifiable { let id: Int; let name: String?; let photoWebp: String?; let bio: String?; @LenientDouble var rating: Double? }
struct ServiceItem: Codable, Identifiable {
    let id: Int; @LenientInt var masterId: Int?; let name: String?; let description: String?
    @LenientInt var durationMin: Int?; @LenientDouble var price: Double?
    /// Где оказывается услуга: at_business (в заведении) | at_client (выезд).
    /// Сервер отдаёт location_type всегда, со значением по умолчанию
    /// at_business — форма ответа одинакова даже без миграции (api_v1.php).
    let locationType: String?
    /// Доплата за выезд. Приходит строкой ("0.00"), поэтому @LenientDouble.
    @LenientDouble var travelFee: Double?
    /// Услуга с выездом к клиенту — тогда при записи нужен адрес.
    var isAtClient: Bool { locationType == "at_client" }

    /// Кто оказывает услугу (аддитивно). Раньше сервер отдавал masters[] общим
    /// списком по организации, и связать их с услугой приложение не умело —
    /// имя мастера на услуге не показывалось вовсе.
    let masters: [Master]?
    /// Готовая подпись с сервера: «Анна» или «Анна, Ольга». nil — любой мастер.
    let masterName: String?

    // ── Бронирование с местами: игровой зал, кинозал, бильярд, дорожка ──────
    // У такой «услуги» цена считается за человека и/или за час, одновременно
    // ей пользуются несколько человек, а время берут на 1..maxSlots окон подряд.
    // Поля аддитивные: у старого сервера их нет, и значения по умолчанию дают
    // прежнее поведение — одно место, фиксированная цена, одно окно.
    let pricingMode: String?
    /// Готовая подпись единицы цены с сервера: «за человека в час».
    let priceUnit: String?
    @LenientInt var capacity: Int?
    @LenientInt var minGuests: Int?
    /// 0 — ограничение только ёмкостью.
    @LenientInt var maxGuests: Int?
    @LenientInt var maxSlots: Int?
    /// Длительность одного окна, мин. Дублирует durationMin — считает сервер.
    @LenientInt var slotMin: Int?
    /// Перерыв между окнами, мин. Цепочку «N окон подряд» сервер собирает с
    /// допуском на него, поэтому клиент обязан считать такие окна соседними —
    /// иначе прячет время, которое сервер забронировал бы. Старый сервер поля
    /// не отдаёт → nil → 0, как было.
    @LenientInt var bufferMin: Int?
    /// Группа в списке: «Игровой зал», «Кинозал».
    let groupName: String?

    // ── Категория услуги ────────────────────────────────────────────────────
    // Услуга лежит в той же категории, что и товары организации, а порядок
    // категории задаёт, где стоит блок услуг на витрине. Поля аддитивные: у
    // старого сервера их нет → nil/0, поведение прежнее.
    //
    // Отдельно: сервер подставляет название категории в group_name, если своей
    // группы у услуги нет, — поэтому подзаголовки и порядок работают и в уже
    // установленных сборках, без обновления в App Store.
    @LenientInt var categoryId: Int?
    let categoryName: String?
    /// Порядок категории. 999999 — услуга без категории (идёт последней).
    @LenientInt var categorySort: Int?
    /// Порядок услуги внутри категории.
    @LenientInt var sortOrder: Int?

    var capacityValue: Int { max(1, capacity ?? 1) }
    var bufferMinutes: Int { max(0, bufferMin ?? 0) }
    var slotMinutes: Int { max(5, (slotMin ?? 0) > 0 ? (slotMin ?? 0) : (durationMin ?? 30)) }
    /// Максимум человек в ОДНОЙ брони.
    var guestsMax: Int {
        let mg = maxGuests ?? 0
        return (mg > 0 && mg <= capacityValue) ? mg : capacityValue
    }
    var guestsMin: Int { min(max(1, minGuests ?? 1), guestsMax) }
    var maxSlotsValue: Int { max(1, maxSlots ?? 1) }
    /// Нужен ли выбор количества человек.
    var needsGuests: Bool { capacityValue > 1 || pricingMode == "per_person" || pricingMode == "per_person_hour" }
    /// Нужен ли выбор количества часов.
    var needsHours: Bool { maxSlotsValue > 1 }

    /// Предпросмотр стоимости. Повторяет serviceBookingQuote() из
    /// core/helpers.php; ИТОГ всегда считает сервер, здесь только экран.
    /// `minutesTotal` — суммарная длина выбранных окон, если она известна с
    /// сервера (Slot.minutes). Ноль/nil → считаем по длительности услуги, как
    /// раньше: у старого сервера длины окон нет.
    func quote(guests: Int, slots: Int, minutesTotal: Int? = nil) -> Decimal {
        let g = Decimal(max(1, guests))
        let s = Decimal(max(1, slots))
        let base = Money.dec(price)
        let mt = minutesTotal ?? 0
        let minutes = Decimal(mt > 0 ? mt : slotMinutes * max(1, slots))
        var raw: Decimal
        switch pricingMode {
        case "per_person": raw = base * g * s
        case "per_hour": raw = base * minutes / 60
        case "per_person_hour": raw = base * g * minutes / 60
        default: raw = base * s
        }
        var out = Decimal()
        NSDecimalRound(&out, &raw, 2, .plain)
        return out
    }

    /// «мастер Анна» / «мастера: Анна, Ольга». nil, если мастер не назначен.
    var mastersLabel: String? {
        let names = (masters ?? []).compactMap { $0.name }.filter { !$0.isEmpty }
        if names.count > 1 { return "мастера: " + names.joined(separator: ", ") }
        if let one = names.first { return "мастер " + one }
        if let n = masterName, !n.isEmpty { return "мастер " + n }
        return nil
    }
}
/// placement — где показывать блок услуг относительно меню: "first" (до меню,
/// как было) или "last" (после). Решение принимает сервер по порядку категории,
/// в которую продавец положил услуги: считать это на каждом клиенте по-своему —
/// верный способ получить три разные витрины. Старый сервер поля не отдаёт →
/// nil → "first".
struct ServicesResponse: Codable { let masters: [Master]?; let services: [ServiceItem]?; let placement: String? }
struct CatalogItem: Codable, Hashable {
    let id: Int; let name: String?; @LenientDouble var price: Double?
    let type: String?; let shopName: String?; let shopSlug: String?; let photo: String?; let category: String?
    var uid: String { "\(type ?? "p")-\(id)" }
}

// Личные рекомендации (Фаза 1.5): GET /api/v1/recommendations.
// popular — товары по истории заказов (та же форма, что CatalogItem),
// ordered_again — магазины, где пользователь уже заказывал.
struct RecommendationsResp: Codable {
    let orderedAgain: [Shop]?
    let popular: [CatalogItem]?
}
struct Slot: Codable, Identifiable {
    let id: Int
    let timeStart: String?
    let timeEnd: String?
    // Места в окне. Аддитивно: старый сервер их не отдаёт, и по умолчанию окно
    // считается «на одного и свободно» — как было до бронирования с местами.
    @LenientInt var capacity: Int?
    @LenientInt var booked: Int?
    @LenientInt var free: Int?
    /// Фактическая длина ИМЕННО ЭТОГО окна, мин. Аддитивно: старый сервер поля
    /// не отдаёт → nil, и экран считает по длительности услуги, как раньше.
    /// Окна одной услуги могут быть разной длины (23:00–00:00 и 09:00–09:30),
    /// поэтому предпросмотр цены берёт длину окна, а не услуги.
    @LenientInt var minutes: Int?

    var capacityValue: Int { max(1, capacity ?? 1) }
    var freeValue: Int { max(0, free ?? 1) }
    /// 0 — сервер длину не прислал.
    var minutesValue: Int { max(0, minutes ?? 0) }
}

// ---- Подарочные карты ----
struct GiftCard: Codable { let code: String?; @LenientDouble var balance: Double?; let status: String?; let expiresAt: String? }

// ---- Заявки / отклики ----
struct Application: Codable, Identifiable { let id: Int; let status: String?; let title: String?; let shop: String?; let createdAt: String? }

// ---- Отзыв (чтение) ----
struct Review: Codable, Identifiable {
    var id: String { serverId.map { "r\($0)" } ?? "\(author ?? "")-\(createdAt ?? "")" }
    /// П-21.4/П-23.4 (А58): id отзыва на сервере — для жалобы и дублей при догрузке.
    /// nil — старый сервер: тогда «Пожаловаться» не показываем.
    @LenientInt var serverId: Int?
    @LenientInt var ratingOverall: Int?; let text: String?; let author: String?; @LenientInt var isVerified: Int?; let createdAt: String?
    let photos: [String]?
    // Ответ продавца (Фаза 2.4, аддитивно): nil = ответа нет.
    let reply: String?; let replyAt: String?
    // Ключи в camelCase: декодер сам переводит snake_case; serverId ← "id".
    enum CodingKeys: String, CodingKey {
        case serverId = "id", ratingOverall, text, author, isVerified, createdAt, photos, reply, replyAt
    }
}

// ---- Тела запросов (camelCase -> snake_case автоматически) ----
struct NotifReadBody: Encodable { let ids: [Int] }
/// items — А111: частичный возврат по количеству (type = "partial"): [{item_id, qty}],
/// qty дробное у весовых (core/helpers.php returnBuild). nil — возврат всего заказа.
struct ReturnCreateBody: Encodable { let orderId: Int; let type: String; let reasonCode: String; let reasonText: String?
    var items: [ReturnLineBody]? = nil }
/// А111: строка частичного возврата — order_items.id и сколько вернуть.
struct ReturnLineBody: Encodable { let itemId: Int; let qty: Double }
/// А111: GET api/profile/returns/{id} (маршрут сайта, конверт {ok, data}, Bearer).
/// order_number — номер заказа как в «Моих заказах»; items — что возвращают
/// (name, qty, price строкой). Старый сервер полей не шлёт — nil.
struct ReturnDetail: Decodable {
    @LenientInt var orderNumber: Int?
    let type: String?
    let items: [ReturnDetailLine]?
}
struct ReturnDetailLine: Decodable {
    let name: String?
    @LenientDouble var qty: Double?
    @LenientDecimal var price: Decimal?
}
/// Адрес визита для выездной услуги — тело POST api/v1/appointments.
///
/// Форма ровно та, которую ждёт сервер (core/helpers.php: normalizeVisitAddress):
/// value — это ГОРОД, а не готовая строка адреса; сервер сам склеивает
/// «value, улица, д. N, кв. M» в formatVisitAddress(). Если положить в value
/// полный адрес, город и улица задвоятся в «Моих записях».
///
/// Сервер отклоняет запись (422), если нет дома либо нет ни улицы, ни города,
/// поэтому isComplete повторяет ту же проверку до отправки — чтобы кнопка
/// «Подтвердить запись» не приводила к ошибке от сервера.
struct VisitAddress: Codable, Equatable {
    /// Город. Название поля историческое: у адресов доставки на сервере
    /// оно тоже называется value.
    var value = ""
    var street = ""
    var house = ""
    var apartment = ""
    var entrance = ""
    var floor = ""
    /// Комментарий для мастера («домофон не работает», «второй подъезд»).
    var comment = ""
    /// Координаты нужны, чтобы мастер открыл маршрут одним нажатием.
    /// nil — сервер просто не сохранит их (поля необязательные).
    var lat: Double?
    var lng: Double?

    /// Достаточно ли адреса, чтобы мастер доехал.
    var isComplete: Bool {
        !street.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !house.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// address — только для выездной услуги (location_type = at_client);
/// для услуги в заведении поле не отправляется вовсе (nil не кодируется).
// address по умолчанию nil: карточка товара (ProductView) записывает на слот
// без адреса, и её вызов AppointmentBody(slotId:) остаётся валидным.
struct AppointmentBody: Encodable {
    let slotId: Int
    var address: VisitAddress? = nil
    // Человек и окон подряд. nil = не отправляем — тело запроса у обычной
    // услуги остаётся ровно таким, как раньше, и сервер подставляет 1 и 1.
    var guests: Int? = nil
    var slots: Int? = nil
    /// Ключ повтора (ответ на заявку №17): повтор после обрыва — та же запись.
    var idempotencyKey: String? = nil
    /// А63: «Комментарий мастеру» (до 300 знаков, сервер режет сам). nil — поле
    /// в теле не уходит, запрос как раньше.
    var comment: String? = nil
}

/// Ответ на создание записи/брони — POST api/v1/appointments.
///
/// Раньше разбирался общий с заказами OrderCreateResult, из которого
/// использовался только id. Своя модель нужна, чтобы экран успеха показал
/// интервал и состав брони, не пересчитывая их сам.
struct AppointmentResult: Codable {
    @LenientInt var orderId: Int?
    /// П-28.11 (А68): номер записи за день — тот, что видит заведение. При
    /// повторе (repeat=1) — номер существующей брони. Нет поля — nil, как раньше.
    @LenientInt var dailyNumber: Int?
    let date: String?
    let time: String?
    let timeEnd: String?
    @LenientInt var guests: Int?
    @LenientInt var slots: Int?
    @LenientDouble var hours: Double?
    @LenientDouble var price: Double?
    @LenientInt var atClient: Int?
    @LenientDouble var travelFee: Double?
    let address: String?
}
struct SocialBody: Encodable { let provider: String; let code: String }
struct NpsBody: Encodable { let score: Int; let comment: String? }
struct ReferralInfo: Decodable {
    let code: String?; @LenientInt var invited: Int?; @LenientInt var reward: Int?
}
struct LoyaltyLevel: Decodable, Identifiable {
    let key: String; let name: String; let icon: String
    @LenientInt var min: Int?; @LenientInt var cashback: Int?
    var id: String { key }
}
struct LoyaltyInfo: Decodable {
    let level: LoyaltyLevel?; let next: LoyaltyLevel?
    @LenientInt var doneOrders: Int?; @LenientInt var toNext: Int?
    @LenientDouble var bonusBalance: Double?
    let levels: [LoyaltyLevel]?
}
struct ReorderData: Decodable {
    @LenientInt var shopId: Int?; let shopName: String?; let shopSlug: String?
    let items: [ReorderItem]?
}
struct ReorderItem: Decodable {
    @LenientInt var productId: Int?; @LenientDouble var qty: Double?; let name: String?; @LenientDouble var price: Double?; let photo: String?
    // Аддитивно (сервер 2026-09): модификаторы строки, цена с ними, единица и дробность.
    let modifierIds: [Int]?
    let modifiersLabel: String?
    @LenientDouble var unitPrice: Double?
    let unit: String?
    @LenientBool var qtyFractional: Bool?
    let qtyPresets: String?
}
struct PromoCheckBody: Encodable {
    let code: String; let subtotal: Double; let shopId: Int?
    enum CodingKeys: String, CodingKey { case code, subtotal, shopId = "shop_id" }
}
