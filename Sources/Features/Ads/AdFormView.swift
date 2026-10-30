//
//  AdFormView.swift — подача и правка объявления
//
//  Порядок ровно как на сайте и в Android:
//    1. черновик с полями (денег не списываем)
//    2. фотографии — по одной, лимит берём из категории
//    3. «Оплатить и опубликовать» — списание из кошелька
//
//  Правка (editAdId != 0) ничего не стоит и не сбрасывает срок размещения.
//  Цена на провод уходит строкой "0.00" через Money.wire: под русской локалью
//  запятая сломала бы сумму на сервере.
//

import PhotosUI
import SwiftUI

@MainActor
final class AdFormViewModel: ObservableObject {
    @Published var cats: [(cat: AdCategory, label: String)] = []
    @Published var chosen: AdCategory?
    @Published var title = ""
    @Published var desc = ""
    @Published var price = ""
    /// А481: отказ по цене (422 details.price — «Цена — числом…», «Слишком большая цена»)
    /// и своя проверка формата — под полем цены, а не общим тостом.
    @Published var priceError: String?
    @Published var negotiable = false
    @Published var condition = -1          // -1 не указано, 1 новое, 0 б/у
    @Published var phone = ""
    @Published var hidePhone = false
    @Published var address = ""
    /// Город объявления. По умолчанию — тот, что выбран в приложении сейчас.
    @Published var cityId: Int? = Session.shared.cityId
    @Published var cities: [City] = []
    @Published var photos: [AdPhoto] = []
    @Published var balance: Decimal = 0
    @Published var adId = 0
    @Published var canChangeCategory = true
    @Published var loading = true
    @Published var busy = false
    @Published var toast: String?
    @Published var shortage: String?
    /// Правка: объявление не загрузилось. Сохранять нельзя — иначе пустая форма
    /// затёрла бы объявление (или, как раньше, создала бы дубль-черновик).
    @Published var loadFailed = false
    /// Паритет с Android: рубрика объявления выключена в админке — её нет в
    /// списке выбора. Сервер правку в закрытом разделе принимает (routes/ads.php,
    /// PUT /api/v1/ads/{id}: «закрытый раздел ей не помеха»), публикацию — нет.
    /// Раньше iOS писал «сохранить правку нельзя», хотя сохранить можно.
    @Published var offCatId: Int?
    @Published var offCatName = ""
    /// Состояние объявления из GET /api/v1/ads/{id} (routes/ads.php): статус, сумма
    /// включения (renew_price — 0, если снято владельцем, а оплаченный срок идёт),
    /// можно ли публиковать (can_publish — действующий тариф рубрики), срок.
    /// Раньше форма правки всегда предлагала «Оплатить и опубликовать» по цене
    /// рубрики: у активного сервер ничего не делал (срок не продлевался), а
    /// снятому с оплаченным сроком писала «не хватает», хотя включение бесплатно.
    /// nil — новое объявление (черновика ещё нет).
    @Published var adStatus: String?
    @Published var renewPrice: Decimal?
    @Published var renewDays: Int?
    @Published var canPublish = true
    @Published var publishBlockReason: String?
    @Published var expiresAt: String?
    /// Цена изменилась / исход оплаты неизвестен — текст под суммой до следующего действия
    /// (тост в 2,5 с такое не успевали прочитать).
    @Published var priceNote: String?
    /// Город выбран человеком в этой форме (в т.ч. «Не указан»). Очистку города (city_id 0)
    /// шлём только при правке открытого объявления или по явному выбору: у черновика,
    /// созданного без города, сервер ставит город профиля (ads.php:724-726), и следующее
    /// сохранение не должно молча его стирать.
    @Published var cityTouched = false
    /// Форма открыта на правку существующего объявления (поля взяты с сервера).
    private var openedForEdit = false

    var isDraft: Bool { adStatus == nil || adStatus == "draft" }
    /// Активное в окне продления (последние 3 дня или срок уже вышел, а крон ещё не снял —
    /// Ads.php:392) — можно продлить, как «Продлить» в «Моих объявлениях». Только платно:
    /// бесплатную рубрику сервер заранее не продлевает (Ads.php:386, price > 0).
    var renewable: Bool {
        adStatus == "active" && MyAdsViewModel.inRenewWindow(expiresAt) && canPublish && (payPrice ?? 0) > 0
    }
    /// Снято владельцем, а оплаченный срок ещё идёт — включение бесплатно до его конца.
    var paidTermLeft: Bool {
        guard adStatus == "archived", let e = expiresAt, !e.isEmpty else { return false }
        return !MyAdsViewModel.expired(e)
    }
    /// Активное, но срок уже вышел (крон снимает раз в час).
    var activeEnded: Bool {
        guard adStatus == "active", let e = expiresAt, !e.isEmpty else { return false }
        return MyAdsViewModel.expired(e)
    }
    /// Активное — без кнопки оплаты (кроме продления); заблокированное сервер не публикует (403).
    var showPay: Bool { adStatus != "blocked" && (adStatus != "active" || renewable) }
    /// Сумма, которую спишет сервер: у черновика — цена выбранной рубрики, у
    /// снятого/истёкшего/активного — renew_price с сервера. Она же уходит в expected_price.
    var payPrice: Decimal? { isDraft ? chosen?.priceValue : (renewPrice ?? chosen?.priceValue) }
    var payButtonTitle: String {
        let p = payPrice ?? 0
        if renewable { return p > 0 ? "Продлить за \(Money.format(p))" : "Продлить" }
        if !isDraft, let known = payPrice, known == 0 { return "Вернуть в ленту бесплатно" }
        return p > 0 ? "Оплатить и опубликовать" : "Опубликовать"
    }

    private func applyState(_ a: AdDetail) {
        adStatus = a.status
        renewPrice = a.renewPrice
        renewDays = a.renewDays
        canPublish = a.canPublish != false
        publishBlockReason = (a.publishBlockReason?.isEmpty == false) ? a.publishBlockReason : nil
        expiresAt = a.expiresAt
    }

    /// Текст формы на момент загрузки/последнего сохранения. Отличается от
    /// текущего — есть несохранённый ввод: смахивание шторки вниз молча
    /// выбрасывало набранные заголовок и описание.
    @Published private var savedText = ""
    private var textSnapshot: String {
        [title, desc, price, phone, address].joined(separator: "\u{1}")
    }
    var hasUnsavedText: Bool { !loading && textSnapshot != savedText }

    /// Плоский список выбираемых категорий: листья, а у корней без детей — сам корень.
    private func leaves(_ list: [AdCategory]) -> [(AdCategory, String)] {
        var out: [(AdCategory, String)] = []
        for root in list {
            let kids = root.children ?? []
            if kids.isEmpty { out.append((root, root.name ?? "")) }
            else { for k in kids { out.append((k, "\(root.name ?? "") · \(k.name ?? "")")) } }
        }
        return out
    }

    /// П-26.6: categoryOff — признак из «Моих объявлений» (GET api/v1/ads/my):
    /// рубрика закрыта, даже если по списку рубрик этого не видно.
    func start(editAdId: Int, categoryOff: Bool = false) async {
        // Рубрики не пришли (нет сети) — список выбора пуст, и «Сохранить»
        // молча отвечало «Выберите категорию», хотя выбрать было не из чего.
        var catsFailed = false
        if let r = try? await API.shared.adCategories() {
            cats = leaves(r.categories ?? []).map { (cat: $0.0, label: $0.1) }
        } else {
            catsFailed = true
        }
        if let w: WalletInfo = try? await API.shared.get("api/v1/wallet") { balance = w.balance ?? 0 }
        if let list: [City] = try? await API.shared.list("api/v1/cities") { cities = list }
        if (cityId ?? 0) <= 0 { cityId = nil }
        if editAdId > 0 {
            adId = editAdId
            loadFailed = true
        }
        if editAdId > 0, let r = try? await API.shared.ad(editAdId), let a = r.ad {
            loadFailed = false
            openedForEdit = true
            title = a.title ?? ""
            desc = a.description ?? ""
            // Целая цена — без «.00»: в поле правки стояло «1500.00».
            price = a.price.map { p -> String in
                let w = Money.wire(p)
                return w.hasSuffix(".00") ? String(w.dropLast(3)) : w
            } ?? ""
            negotiable = a.isNegotiable ?? false
            condition = a.conditionNew == nil ? -1 : ((a.conditionNew ?? false) ? 1 : 0)
            phone = a.contactPhone ?? ""
            hidePhone = a.phoneHidden ?? false
            address = a.address ?? ""
            // Город — как у объявления, и «Не указан» тоже: раньше у объявления без
            // города подставлялся город приложения, и «Сохранить» молча его ставил.
            cityId = (a.cityId ?? 0) > 0 ? a.cityId : nil
            photos = a.photos ?? []
            canChangeCategory = (a.status ?? "draft") == "draft"
            applyState(a)
            chosen = cats.first { $0.cat.stableId == (a.categoryId ?? 0) }?.cat
            // П-26.6: сервер сказал «раздел закрыт» — рубрику не выбираем из
            // списка и при сохранении не шлём.
            if categoryOff, let cid = a.categoryId, cid > 0 { chosen = nil }
            if chosen == nil, (!catsFailed || categoryOff), let cid = a.categoryId, cid > 0 {
                offCatId = cid
                offCatName = a.categoryName ?? ""
            }
        }
        if loadFailed { toast = "Не удалось загрузить объявление. Закройте форму и откройте снова" }
        else if catsFailed { toast = "Не удалось загрузить рубрики. Закройте форму и откройте снова" }
        savedText = textSnapshot
        loading = false
    }

    /// Цена строго целиком: «1 500» раньше превращалось в 1 ₽ (Decimal читает
    /// только начало строки), а «abc» молча стирало цену.
    private var parsedPrice: Decimal? {
        let t = price
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: "\u{202F}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard t.range(of: #"^\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil else { return nil }
        return Decimal(string: t)
    }

    private func body(for cat: AdCategory) -> AdSaveBody {
        body(catId: cat.stableId, priceAllowed: cat.priceAllowed)
    }

    private func body(catId: Int?, priceAllowed: Bool) -> AdSaveBody {
        AdSaveBody(
            categoryId: catId,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: desc.trimmingCharacters(in: .whitespacesAndNewlines),
            // Цену нормализуем: запятую в точку, и только если категория её просит.
            price: priceAllowed
                ? (parsedPrice.map { Money.wire($0) } ?? "")
                : "",
            isNegotiable: negotiable,
            conditionNew: condition == 1 ? true : (condition == 0 ? false : nil),
            address: address.trimmingCharacters(in: .whitespaces).isEmpty ? nil : address,
            contactPhone: phone.trimmingCharacters(in: .whitespaces),
            hidePhone: hidePhone,
            // Правка: «Не указан» уходит как 0 — сервер (adsValidate) пишет NULL; без
            // ключа он поле не трогает, и очищенный город не сохранялся. Только у открытого
            // на правку или если человек сам выбрал «Не указан» (cityTouched). Создание — как
            // раньше (nil, ключ не уходит, сервер подставит город из профиля).
            cityId: cityId ?? ((adId > 0 && (openedForEdit || cityTouched)) ? 0 : nil),
            // А485: «Не указан» при создании — city_none: 1, сервер не подставит город профиля.
            cityNone: (adId == 0 && cityTouched && cityId == nil) ? 1 : nil
        )
    }

    /// Заголовок 3–190, описание 10–5000 символов, в телефоне не меньше 10 цифр —
    /// как Ads::TITLE_MIN/MAX, DESC_MIN/MAX и проверка contact_phone на сервере.
    /// Длину считаем по символам Юникода, как mb_strlen. nil — всё в порядке.
    private var fieldsProblem: String? {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        if t < 3 { return "Заголовок — минимум 3 символа" }
        if t > 190 { return "Заголовок длиннее 190 символов" }
        let d = desc.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
        if d < 10 { return "Опишите подробнее — минимум 10 символов" }
        if d > 5000 { return "Описание длиннее 5000 символов" }
        let digits = phone.filter { $0.isASCII && $0.isNumber }.count
        if digits < 10 { return "Укажите телефон для связи — не меньше 10 цифр" }
        return nil
    }

    /// Создать черновик или сохранить правку. Возвращает id или 0.
    @discardableResult
    func save(silent: Bool) async -> Int {
        // Закрытая рубрика уже сохранённого объявления — правку сохраняем в ней же.
        let catId: Int?
        let priceAllowed: Bool
        if let c = chosen {
            catId = c.stableId
            priceAllowed = c.priceAllowed
        } else if offCatId != nil, adId > 0 {
            // П-26.6: закрытая рубрика — category_id не шлём, сервер оставит прежнюю.
            catId = nil
            priceAllowed = true
        } else {
            toast = "Выберите категорию"
            return 0
        }
        if loadFailed { toast = "Объявление не загрузилось — откройте форму заново"; return 0 }
        priceError = nil
        if priceAllowed, !price.trimmingCharacters(in: .whitespaces).isEmpty, parsedPrice == nil {
            let m = "Проверьте цену: только цифры, например 1500"
            if chosen?.priceAllowed != false { priceError = m } else { toast = m }
            return 0
        }
        // Те же пределы, что проверяет сервер (adsValidate в routes/ads.php):
        // раньше человек узнавал о них только после отправки, и то об одном поле.
        if let problem = fieldsProblem { toast = problem; return 0 }
        // Снимок до запроса: набранное, пока шёл ответ, сохранённым не считаем.
        let snap = textSnapshot
        do {
            if adId > 0 {
                try await API.shared.adUpdate(adId, body(catId: catId, priceAllowed: priceAllowed))
            } else {
                let r = try await API.shared.adCreate(body(catId: catId, priceAllowed: priceAllowed))
                guard let newId = r.adId, newId > 0 else {
                    toast = "Сервер не вернул номер объявления"
                    return 0
                }
                adId = newId
                if cityTouched && cityId == nil {
                    // Старый сервер city_none не знает и ставит город профиля — правка на
                    // city_id 0 остаётся (новому она ничего не меняет: город уже пустой).
                    // Город явно «Не указан» уже при создании: сервер всё равно ставит город
                    // профиля (ads.php:724-726) — сразу правим черновик на city_id 0 (PUT это
                    // принимает: adsValidate пишет NULL), чтобы объявление совпало с формой
                    // при любом пути. Не прошло — catch ниже вернёт 0, публикация не пойдёт;
                    // повтор уйдёт правкой (adId уже есть) с city_id 0.
                    try await API.shared.adUpdate(newId, body(catId: catId, priceAllowed: priceAllowed))
                } else if cityId == nil, !cityTouched, let d = try? await API.shared.ad(newId), let c = d.ad?.cityId, c > 0,
                          cityId == nil, !cityTouched {
                    // Сервер поставил черновику город профиля — показываем его в форме: дальше
                    // уходит он, а не «очистка». Условие — повторно после запроса: пока он шёл,
                    // человек мог выбрать город сам.
                    cityId = c
                }
            }
            if !silent { toast = "Сохранено" }
            savedText = snap   // сохранено — шторку снова можно смахнуть
            return adId
        } catch {
            // 422 с ошибкой по полю price — текст сервера под полем цены.
            if let api = error as? APIError, api.rejectStatus == 422,
               let pe = api.rejectDetails?["price"], !pe.isEmpty, chosen?.priceAllowed != false {
                priceError = pe
                // Другие поля тоже с ошибкой — общий текст сервера тоже показываем
                // (служебные ключи details — не поля формы).
                let service: Set<String> = ["price", "error_code", "idempotency_code", "need", "suggestion", "reason"]
                if api.rejectDetails?.keys.contains(where: { !service.contains($0) }) == true {
                    toast = api.errorDescription ?? "Проверьте поля объявления"
                }
                return 0
            }
            toast = (error as? LocalizedError)?.errorDescription ?? "Проверьте поля объявления"
            return 0
        }
    }

    /// Кнопка «Сохранить»: двойное нажатие (или нажатие во время загрузки фото)
    /// раньше создавало два черновика — сервер повторы создания не склеивает.
    func saveTapped() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        priceNote = nil
        await save(silent: false)
    }

    func addPhotos(_ items: [PhotosPickerItem]) async {
        // Фото выбрали во время сохранения/оплаты — выбор сбрасывается
        // (picked = []), и раньше пропадал молча. Говорим, что повторить.
        guard !busy else { toast = "Подождите окончания сохранения и выберите фото ещё раз"; return }
        busy = true
        defer { busy = false }
        // Паритет с Android: фото можно добавить и в закрытой рубрике (лимит
        // проверит сервер по своей категории).
        guard chosen != nil || (offCatId != nil && adId > 0) else { toast = "Сначала выберите категорию"; return }
        let limit = chosen?.photosLimit ?? 8
        // Объявление не загрузилось — фото к нему не добавляем вслепую.
        if loadFailed { toast = "Объявление не загрузилось — откройте форму заново"; return }
        // Фото цепляются к объявлению, поэтому черновик должен существовать.
        if adId == 0, await save(silent: true) == 0 { return }
        // Фото, которое не открылось (iCloud без сети, чужой формат), раньше
        // пропускалось молча — человек думал, что загрузил все.
        var unreadable = 0
        var stopped = false
        for item in items {
            if photos.count >= limit { toast = "Больше \(limit) фотографий нельзя"; stopped = true; break }
            guard let raw = try? await item.loadTransferable(type: Data.self) else { unreadable += 1; continue }
            // Камера iPhone снимает в HEIC — сервер его не принимает; шлём JPEG.
            // Перекодирование 48-Мп снимка — не на главном потоке: экран замирал на секунды.
            let data = await Task.detached(priority: .userInitiated) { ImageUpload.jpeg(from: raw) ?? raw }.value
            do {
                if let ph = try await API.shared.uploadAdPhoto(adId: adId, jpeg: data) { photos.append(ph) }
            } catch {
                toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить фото"
                stopped = true
                break
            }
        }
        if unreadable > 0 && !stopped { toast = "Не удалось открыть фото: \(unreadable). Выберите другое" }
    }

    /// Фото, которые уже удаляются: двойное ✕ слало второй DELETE, тот отвечал
    /// 404, и после удачного удаления всплывало «Не удалось удалить фото».
    private var deletingPhotoIds = Set<Int>()

    func deletePhoto(_ p: AdPhoto) async {
        guard adId > 0, !deletingPhotoIds.contains(p.stableId) else { return }
        deletingPhotoIds.insert(p.stableId)
        defer { deletingPhotoIds.remove(p.stableId) }
        do { try await API.shared.adPhotoDelete(adId: adId, photoId: p.stableId)
             photos.removeAll { $0.stableId == p.stableId } }
        catch {
            // 404 — фото уже удалено (с сайта, другим устройством): убираем из
            // формы, а не пишем «не удалось». Иначе — причина словами.
            if (error as? APIError)?.rejectStatus == 404 {
                photos.removeAll { $0.stableId == p.stableId }
            } else {
                toast = (error as? LocalizedError)?.errorDescription ?? "Не удалось удалить фото"
            }
        }
    }

    /// Оплатить и опубликовать (или продлить активное). onDone получает id объявления.
    func publish(onDone: @escaping (Int) -> Void) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        priceNote = nil
        // Сумма с кнопки — серверу для сверки (expected_price); снимок до сохранения.
        let expected = payPrice
        let renew = renewable
        let statusBefore = adStatus
        let tillBefore = expiresAt
        let id = await save(silent: true)
        guard id > 0 else { return }
        do {
            let r: AdPublishResponse
            if renew { r = try await API.shared.adRenew(id, expectedPrice: expected) }
            else { r = try await API.shared.adPublish(id, expectedPrice: expected) }
            let charged = r.charged ?? 0
            if renew {
                toast = charged > 0 ? "Продлено, списано \(Money.format(charged))" : "Уже продлено"
            } else {
                toast = charged > 0 ? "Опубликовано, списано \(Money.format(charged))" : "Опубликовано"
            }
            onDone(id)
        } catch {
            // 409 price_changed: денег не списано — показываем новую цену и
            // перечитываем рубрики/объявление; повтор — по нажатию человека.
            // busy держится до конца перечитывания (defer) — кнопка недоступна.
            if (error as? APIError)?.priceChangedTo != nil {
                await refreshPrices()
                // «Нажмите ещё раз» — только если кнопка после перечитывания осталась.
                let changed = MyAdsViewModel.priceChangedText(error, retry: showPay && chosen != nil && (isDraft || canPublish)) ?? ""
                toast = changed
                priceNote = changed
                return
            }
            let msg = (error as? LocalizedError)?.errorDescription ?? "Не удалось опубликовать"
            // Нехватку денег узнаём по типу ошибки (409 с суммами), а не только
            // по слову в тексте: иной текст сервера уходил коротким тостом без
            // подсказки пополнить кошелёк.
            var isShortage = msg.contains("хватает")
            if let e = error as? APIError, case .walletShortage = e { isShortage = true }
            // Явный отказ сервера (4xx) — денег точно не списано. Иначе (обрыв, таймаут,
            // 5xx) исход неизвестен: оплата могла пройти.
            let explicit = isShortage || (error as? APIError)?.rejectStatus != nil
            if isShortage { shortage = msg }
            else if explicit { toast = msg }
            else {
                // Перечитываем объявление и кошелёк, прежде чем снова дать кнопку, —
                // иначе повтор позже 2 минут списал бы второй раз.
                await refreshPrices()
                let done = renew ? (expiresAt != tillBefore) : (adStatus == "active" && statusBefore != "active")
                let text = done
                    ? (renew ? "Ответ сервера не дошёл, но объявление продлено — платить ещё раз не нужно"
                             : "Ответ сервера не дошёл, но объявление опубликовано — платить ещё раз не нужно")
                    : msg + ". Проверьте баланс кошелька перед повтором"
                toast = text
                priceNote = text
            }
        }
    }

    /// Перечитать цену: рубрики (у черновика), объявление (renew_price, статус) и кошелёк.
    func refreshPrices() async {
        if let r = try? await API.shared.adCategories() {
            cats = leaves(r.categories ?? []).map { (cat: $0.0, label: $0.1) }
            if let cid = chosen?.stableId, let fresh = cats.first(where: { $0.cat.stableId == cid })?.cat { chosen = fresh }
        }
        if adId > 0, let r = try? await API.shared.ad(adId), let a = r.ad {
            applyState(a)
            canChangeCategory = (a.status ?? "draft") == "draft"
        }
        if let w: WalletInfo = try? await API.shared.get("api/v1/wallet") { balance = w.balance ?? 0 }
    }
}

struct AdFormView: View {
    let editAdId: Int
    /// П-26.6: рубрика объявления закрыта (category_off из «Моих объявлений»).
    var categoryOff: Bool = false
    let onPublished: (Int) -> Void

    @StateObject private var vm = AdFormViewModel()
    @State private var picked: [PhotosPickerItem] = []
    /// Паритет с Android: «Не хватает денег» → «Пополнить кошелёк» открывает кошелёк.
    @State private var showWallet = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.loading { AdsSkeletonView() } else { form }
            }
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle(editAdId > 0 ? "Правка объявления" : "Новое объявление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("Закрыть") { dismiss() }.disabled(vm.busy) }
            }
            // Пока идёт оплата/публикация или загрузка фото, форма не закрывается
            // (ни «Закрыть», ни смахивание): раньше закрытая посреди оплаты форма
            // прятала итог — списано ли и опубликовано ли.
            // Набранный, но не сохранённый текст смахиванием тоже не теряем —
            // закрыть можно кнопкой «Закрыть».
            .interactiveDismissDisabled(vm.busy || vm.hasUnsavedText)
            .task { await vm.start(editAdId: editAdId, categoryOff: categoryOff) }
            .navigationDestination(isPresented: $showWallet) { WalletView() }
            // Один параметр: двухпараметрический onChange — это iOS 17, а цель
            // развёртывания проекта 16.0 (project.yml), и сборка на нём падает.
            .onChange(of: picked) { items in
                guard !items.isEmpty else { return }
                Task { await vm.addPhotos(items); picked = [] }
            }
            .alert("Не хватает денег", isPresented: Binding(
                get: { vm.shortage != nil }, set: { if !$0 { vm.shortage = nil } }
            )) {
                Button("Пополнить кошелёк") { vm.shortage = nil; showWallet = true }
                Button("Позже", role: .cancel) { vm.shortage = nil }
            } message: {
                Text((vm.shortage ?? "") + "\n\nОбъявление сохранено — пополните кошелёк и опубликуйте его здесь или из «Моих объявлений».")
            }
            .overlay(alignment: .bottom) {
                if let t = vm.toast {
                    Text(t)
                        .font(YMFont.caption).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(YMColor.text.opacity(0.9), in: Capsule())
                        .padding(.bottom, YMSpace.lg)
                        // Свой таймер у каждого сообщения: таймер прежнего тоста гасил новый раньше срока.
                        .task(id: t) {
                            // Длинный текст (цена изменилась, исход оплаты) — дольше.
                            try? await Task.sleep(nanoseconds: t.count > 60 ? 6_000_000_000 : 2_500_000_000)
                            if !Task.isCancelled { vm.toast = nil }
                        }
                }
            }
        }
    }

    private var form: some View {
        Form {
            Section("Категория") {
                // П-26.6: рубрика закрыта — показываем её текстом, а не пустым
                // выбором «— выберите —». Черновик (и только он) можно перенести
                // в открытую рубрику — для него выбор ниже остаётся.
                if vm.offCatId != nil && vm.chosen == nil {
                    HStack {
                        Text(vm.offCatName.isEmpty ? "Рубрика" : vm.offCatName).foregroundStyle(YMColor.text)
                        Spacer()
                        Text("раздел закрыт").font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                    }
                }
                if vm.offCatId == nil || vm.canChangeCategory {
                Picker(vm.offCatId != nil ? "Перенести в рубрику" : "Категория", selection: Binding(
                    get: { vm.chosen?.stableId ?? 0 },
                    set: { id in vm.chosen = vm.cats.first { $0.cat.stableId == id }?.cat }
                )) {
                    Text("— выберите —").tag(0)
                    ForEach(vm.cats, id: \.cat.stableId) { row in
                        Text(row.label + " — " + (row.cat.priceValue > 0 ? Money.format(row.cat.priceValue) : "бесплатно"))
                            .tag(row.cat.stableId)
                    }
                }
                .disabled(!vm.canChangeCategory)
                }
                if !vm.canChangeCategory {
                    Text("Категорию можно выбрать только до публикации.")
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }

            Section("Объявление") {
                TextField("Заголовок", text: $vm.title)
                TextField("Описание", text: $vm.desc, axis: .vertical).lineLimit(4...10)
            }

            if vm.chosen?.priceAllowed != false {
                Section("Цена") {
                    TextField("Цена, ₽ (можно не указывать)", text: $vm.price).keyboardType(.decimalPad)
                        .onChange(of: vm.price) { _ in vm.priceError = nil }
                    if let pe = vm.priceError {
                        Text(pe)
                            .font(YMFont.caption)
                            .foregroundStyle(YMColor.statusCancel)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Возможен торг", isOn: $vm.negotiable)
                }
            }

            Section("Состояние") {
                Picker("Состояние", selection: $vm.condition) {
                    Text("Не указано").tag(-1)
                    Text("Новое").tag(1)
                    Text("Б/у").tag(0)
                }
                .pickerStyle(.segmented)
            }

            Section("Контакты") {
                TextField("Телефон для связи", text: $vm.phone).keyboardType(.phonePad)
                Toggle("Показывать телефон только по кнопке", isOn: $vm.hidePhone)
                Picker("Город", selection: Binding(
                    get: { vm.cityId },
                    set: { vm.cityId = $0; vm.cityTouched = true }
                )) {
                    Text("Не указан").tag(Int?.none)
                    ForEach(vm.cities) { city in
                        Text(city.name ?? "").tag(Int?.some(city.id))
                    }
                }
                TextField("Адрес или район (необязательно)", text: $vm.address)
            }

            Section("Фотографии") {
                if !vm.photos.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: YMSpace.sm) {
                            ForEach(vm.photos) { p in
                                ZStack(alignment: .topTrailing) {
                                    if let u = API.imageURL(p.thumb ?? p.card) {
                                        CachedAsyncImage(url: u) { phase in
                                            if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                                            else { Rectangle().fill(YMColor.surface2) }
                                        }
                                        .frame(width: 96, height: 96)
                                        .clipShape(RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
                                    }
                                    Button {
                                        Task { await vm.deletePhoto(p) }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.white, YMColor.statusCancel)
                                    }
                                    // В строке Form кнопки со стилем по умолчанию
                                    // срабатывают ВСЕ сразу от касания по строке —
                                    // одно касание удаляло все фото. borderless —
                                    // каждая ✕ только своя (как в iOS-продавце).
                                    .buttonStyle(.borderless)
                                    .offset(x: 6, y: -6)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                PhotosPicker(selection: $picked, maxSelectionCount: vm.chosen?.photosLimit ?? 8, matching: .images) {
                    Label("Добавить фото", systemImage: "camera")
                }
                Text("До \(vm.chosen?.photosLimit ?? 8) фотографий. Первая станет главной.")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
            }

            Section {
                if vm.adStatus == "blocked" {
                    // Заблокированное сервер не публикует и не продлевает (403) — цену не показываем.
                    Text("Объявление заблокировано администратором — публикация недоступна. Обратитесь в поддержку.")
                        .font(YMFont.body).foregroundStyle(YMColor.statusCancel)
                } else if let cat = vm.chosen {
                    VStack(alignment: .leading, spacing: 2) {
                        if vm.adStatus == "active" {
                            // Активное: правка бесплатна и срок не сбрасывает. Оплата — только
                            // продление в последние 3 дня срока.
                            Text((vm.activeEnded ? "Срок размещения закончился" : "Объявление опубликовано") + activeTillText)
                                .font(YMFont.body).foregroundStyle(YMColor.text)
                            if !vm.canPublish {
                                // Раздел закрыт: продлить нельзя — говорим почему, а не «в последние 3 дня».
                                Text(vm.publishBlockReason ?? "Раздел временно закрыт — продление недоступно")
                                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            } else if vm.renewable {
                                let p = vm.payPrice ?? 0
                                let d = vm.renewDays ?? 0
                                Text((vm.activeEnded ? "Можно продлить" : "Срок скоро закончится — можно продлить")
                                     + (d > 0 ? " ещё на " + LodgingDate.plural(d, "день", "дня", "дней") : "")
                                     + (p > 0 ? " за \(Money.format(p))" : ""))
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                                walletLine(p)
                            } else {
                                // Бесплатную рубрику заранее не продлевают (Ads.php:386) — про 3 дня не пишем.
                                Text("Изменения сохраняются бесплатно, срок размещения не сбрасывается."
                                     + ((vm.payPrice ?? 0) > 0 ? " Продлить можно в последние 3 дня срока." : ""))
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                            }
                        } else {
                            let p = vm.payPrice ?? 0
                            Text(vm.isDraft ? "Размещение в «\(cat.name ?? "")»" : "Вернуть в ленту «\(cat.name ?? "")»")
                                .font(YMFont.caption).foregroundStyle(YMColor.muted)
                            Text(p > 0 ? Money.format(p) : "Бесплатно")
                                .font(YMFont.title3).foregroundStyle(YMColor.text)
                            // renew_price 0: либо снято, а оплаченный срок ещё идёт (бесплатно до его
                            // конца), либо рубрика бесплатная — тогда новый срок (Ads.php:345-347).
                            if !vm.isDraft && vm.payPrice == 0 && vm.paidTermLeft {
                                Text("Оплаченный срок ещё не закончился — до его конца объявление вернётся в ленту бесплатно.")
                                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                            } else {
                                // «на 1 день», «на 3 дня», «на 30 дней» — раньше всегда «дней».
                                let days = vm.isDraft ? cat.daysValue : ((vm.renewDays ?? 0) > 0 ? (vm.renewDays ?? 0) : cat.daysValue)
                                Text("на " + LodgingDate.plural(days, "день", "дня", "дней")).font(YMFont.caption).foregroundStyle(YMColor.muted)
                            }
                            walletLine(p)
                            if !vm.isDraft && !vm.canPublish {
                                Text(vm.publishBlockReason ?? "Раздел временно закрыт — публикация недоступна")
                                    .font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                            }
                        }
                        if let note = vm.priceNote {
                            Text(note).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                        }
                    }
                } else if vm.offCatId != nil {
                    // Раздел закрыт: правку сохранить можно, опубликовать — нет (как в Android).
                    Text("Раздел «\(vm.offCatName)» временно закрыт — публикация недоступна, изменения можно сохранить.")
                        .font(YMFont.body).foregroundStyle(YMColor.muted)
                } else if !vm.canChangeCategory && !vm.cats.isEmpty {
                    // Рубрика опубликованного объявления закрыта (её нет в списке),
                    // а сменить её нельзя: кнопки ниже серые, и раньше здесь
                    // предлагалось «выбрать категорию», которую выбрать невозможно.
                    Text("Рубрика этого объявления сейчас закрыта — сохранить правку нельзя. Обратитесь в поддержку.")
                        .font(YMFont.body).foregroundStyle(YMColor.statusCancel)
                } else {
                    Text("Выберите категорию — рядом покажем стоимость размещения.")
                        .font(YMFont.body).foregroundStyle(YMColor.muted)
                }
            }

            Section {
                Button {
                    Task { await vm.saveTapped() }
                } label: {
                    HStack { Spacer(); Text("Сохранить"); Spacer() }
                }
                .disabled(vm.busy || (vm.chosen == nil && vm.offCatId == nil))

                if vm.showPay {
                Button {
                    Task { await vm.publish { id in onPublished(id); dismiss() } }
                } label: {
                    HStack {
                        Spacer()
                        if vm.busy { ProgressView() }
                        else {
                            Text(vm.payButtonTitle).bold()
                        }
                        Spacer()
                    }
                }
                .disabled(vm.busy || vm.chosen == nil || (!vm.isDraft && !vm.canPublish))
                }
            } footer: {
                Text("Объявление публикуется сразу после оплаты. За нарушение правил площадки объявление может быть заблокировано.")
            }
        }
        // У цифровых клавиатур цены и телефона нет «Готово» — клавиатура
        // закрывала кнопки внизу формы. Убирается жестом прокрутки.
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .background(YMColor.bg.ignoresSafeArea())
    }

    /// « до 09.11.2026» (DateFmt.day) к «Объявление опубликовано», « 09.11.2026» к
    /// «Срок размещения закончился»; без срока — пусто.
    private var activeTillText: String {
        guard let e = vm.expiresAt, !e.isEmpty else { return "" }
        return (vm.activeEnded ? " " : " до ") + (DateFmt.day(e) ?? String(e.prefix(10)))
    }

    /// «Кошелёк: N — не хватает» под суммой; при 0 ₽ ничего не пишет.
    @ViewBuilder
    private func walletLine(_ p: Decimal) -> some View {
        if p > 0 {
            let enough = vm.balance >= p
            Text("Кошелёк: \(Money.format(vm.balance))" + (enough ? "" : " — не хватает"))
                .font(YMFont.caption)
                .foregroundStyle(enough ? YMColor.muted : YMColor.statusCancel)
        }
    }
}
