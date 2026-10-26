# Публикация Yumurta iOS в App Store + push (подробно, с нуля)

Если ты публикуешь впервые — читай по порядку и ничего не пропускай.
Bundle id приложения: **`ru.marketplace.client.premium`** (запомни, он нужен везде).

**Мак не нужен** — Codemagic собирает в облаке на своих Mac. Тебе нужен только браузер.

Порядок такой:
1. Apple Developer — подготовить идентификаторы и ключи.
2. App Store Connect — создать карточку приложения.
3. Codemagic — настроить подпись, сборку и автозагрузку.
4. Сервер — включить push (APNs).
5. TestFlight — проверить на телефоне.
6. Отправить на ревью в App Store.

---

## Термины простыми словами
- **Bundle ID** — уникальный «адрес» приложения (`ru.marketplace.client.premium`).
- **APNs** — служба Apple, которая доставляет пуш-уведомления на iPhone.
- **APNs Auth Key (.p8)** — ключ, которым СЕРВЕР подписывает запросы к APNs (чтобы слать пуши).
- **App Store Connect API Key (.p8)** — ДРУГОЙ ключ, которым **Codemagic** подписывает приложение и загружает его в App Store. Это два РАЗНЫХ ключа, не путай.
- **Provisioning profile / сертификат** — «пропуск», разрешающий ставить твоё приложение на устройства. При автоподписи Codemagic создаёт их сам.
- **TestFlight** — сервис Apple для теста сборки на реальных телефонах до релиза.

---

## ЧАСТЬ 1. Apple Developer (developer.apple.com)

Войди под своим аккаунтом разработчика.

### Шаг 1.1. Создать App ID (идентификатор приложения) с Push
1. Открой **Certificates, Identifiers & Profiles** (или сразу developer.apple.com/account/resources/identifiers/list).
2. Слева **Identifiers** → синяя круглая **«+»** справа.
3. Выбери **App IDs** → **Continue**.
4. Тип **App** → **Continue**.
5. Заполни:
   - **Description**: `Yumurta` (любое).
   - **Bundle ID**: выбери **Explicit** и впиши **`ru.marketplace.client.premium`**.
6. Прокрути список **Capabilities** вниз, поставь галочку **Push Notifications**.
7. **Continue** → **Register**.

### Шаг 1.2. Создать APNs Auth Key (.p8) — для отправки пушей
1. Слева **Keys** → **«+»**.
2. **Key Name**: `Yumurta APNs`.
3. Поставь галочку **Apple Push Notifications service (APNs)** → **Continue** → **Register**.
4. Нажми **Download** — скачается файл **`AuthKey_XXXXXXXXXX.p8`**.
   ⚠️ Скачать можно ТОЛЬКО ОДИН РАЗ. Сохрани файл надёжно (не потеряй).
5. Запиши два значения (понадобятся на сервере):
   - **Key ID** — 10 символов, видно на странице ключа и в имени файла (`XXXXXXXXXX`).
   - **Team ID** — 10 символов. Найдёшь: **Account → Membership details** (или вверху справа под именем).

### Шаг 1.3. Создать App Store Connect API Key — для Codemagic
Этот ключ создаётся в App Store Connect (не в developer-портале).
1. Открой **appstoreconnect.apple.com** → **Users and Access**.
2. Вкладка **Integrations** (в старом интерфейсе — **Keys**) → раздел **App Store Connect API** → **«+»** (Generate API Key).
3. **Name**: `Codemagic`. **Access**: выбери **App Manager** → **Generate**.
4. Скачай `.p8` этого ключа (тоже один раз). Запиши:
   - **Issuer ID** (длинный, вверху раздела).
   - **Key ID** этого ключа (отличается от APNs Key ID из 1.2!).

---

## ЧАСТЬ 2. App Store Connect — карточка приложения

1. **appstoreconnect.apple.com** → **Apps** → синяя **«+»** → **New App**.
2. Заполни:
   - **Platforms**: iOS.
   - **Name**: как будет называться в App Store (напр. `Yumurta`). Должно быть уникальным во всём App Store.
   - **Primary Language**: Russian.
   - **Bundle ID**: выбери из списка `ru.marketplace.client.premium` (появится после шага 1.1).
   - **SKU**: любой уникальный код, напр. `yumurta-ios-01`.
   - **User Access**: Full Access.
3. **Create**. Карточка создана (метаданные заполним в Части 6 — можно позже).

---

## ЧАСТЬ 3. Codemagic — сборка и автозагрузка

### Шаг 3.1. Код должен быть в git
Codemagic собирает из git-репозитория (GitHub/GitLab/Bitbucket). Убедись, что папка
`8 IOS-client-new` закоммичена и запушена в твой репозиторий (в т.ч. свежие правки и файл
`Sources/GoogleService-Info.plist`-заглушку, если оставляешь проверку).

### Шаг 3.2. Подключить App Store Connect API Key в Codemagic
1. Codemagic → **Teams** (или иконка профиля) → **Integrations** → **Apple Developer Portal** →
   **Connect** → загрузи ключ из **шага 1.3**: **Issuer ID**, **Key ID**, файл **.p8**.
   (В новых версиях: **Settings → Code signing identities → App Store Connect API keys → Add key**.)

### Шаг 3.3. Положить `codemagic.yaml` в репозиторий

> Пример ниже — исторический (первая настройка). Сейчас в `codemagic.yaml` процессы `ios-testflight` и
> `ios-release` — см. ЧАСТЬ 7.
Проще всего — готовый конфиг. Создай в корне репозитория (там же, где `project.yml`) файл
**`codemagic.yaml`** с таким содержимым (подставь свои значения в `vars`):

```yaml
workflows:
  ios-release:
    name: Yumurta iOS release
    max_build_duration: 60
    integrations:
      app_store_connect: Codemagic   # имя интеграции из шага 3.2
    environment:
      ios_signing:
        distribution_type: app_store
        bundle_identifier: ru.marketplace.client.premium
      vars:
        BUNDLE_ID: "ru.marketplace.client.premium"
      xcode: latest
      cocoapods: default
    scripts:
      - name: Установить XcodeGen
        script: brew install xcodegen
      - name: Сгенерировать проект
        script: |
          cd "$CM_BUILD_DIR"
          xcodegen generate
      - name: Автоподпись (managed)
        script: |
          xcode-project use-profiles
      - name: Сборка .ipa
        script: |
          xcode-project build-ipa \
            --project "YumurtaPremium.xcodeproj" \
            --scheme "YumurtaPremium"
    artifacts:
      - build/ios/ipa/*.ipa
      - /tmp/xcodebuild_logs/*.log
    publishing:
      app_store_connect:
        auth: integration
        submit_to_testflight: true      # автозагрузка в TestFlight
        submit_to_app_store: false      # true — когда готов к релизу (после проверки метаданных)
```

Замечания:
- **Убери свой старый шаг с проверкой `GoogleService-Info.plist`** — Firebase не используем
  (пуши идут через APNs). Если оставишь его — он будет валить сборку; либо держи заглушку
  `Sources/GoogleService-Info.plist` (она уже в репо и не мешает).
- Имя интеграции `Codemagic` в `integrations.app_store_connect` должно совпадать с тем,
  как ты назвал ключ в шаге 3.2.
- Схема/имя проекта — `YumurtaPremium` (из `project.yml`, ключ `name:`).

### Шаг 3.4. Номер сборки
App Store не примет две загрузки с одинаковым `CURRENT_PROJECT_VERSION`. Добавь перед сборкой
авто-инкремент, напр. шаг:
```yaml
      - name: Номер сборки
        script: |
          BUILD_NUMBER=$(($(app-store-connect get-latest-testflight-build-number "$BUNDLE_ID" 2>/dev/null || echo 0) + 1))
          agvtool new-version -all "$BUILD_NUMBER"
```
(или просто вручную поднимай `CURRENT_PROJECT_VERSION` в `project.yml` перед каждой сборкой).

### Шаг 3.5. Запустить сборку
Codemagic → твой проект → **Start new build** → **«Yumurta iOS (TestFlight)»** (`ios-testflight`; до 21.10.2026 этот
процесс назывался `ios-release`). Дождись зелёного. Сборка сама уедет в **TestFlight**.
Для выпуска в App Store без ручной подачи — процесс **«Yumurta iOS — релиз в App Store»**, ЧАСТЬ 7.

---

## ЧАСТЬ 4. Push через APNs — на сервере (reg.ru)

Клиент уже готов. Сервер тоже умеет APNs — надо задать ключ из **шага 1.2**.

1. Залей файл `AuthKey_XXXXXXXXXX.p8` на сервер, напр. в `config/apns-key.p8`.
2. Пропиши переменные (в `.env` площадки или прямо в `config/config.php`):
   ```
   APNS_KEY_ID=XXXXXXXXXX          # Key ID из шага 1.2
   APNS_TEAM_ID=YYYYYYYYYY         # Team ID из шага 1.2
   APNS_BUNDLE_ID=ru.marketplace.client.premium
   APNS_KEY_FILE=/абсолютный/путь/config/apns-key.p8
   APNS_ENV=production             # TestFlight и App Store = production
   ```
3. Сохрани. Всё — сервер начнёт слать iOS-пуши напрямую в Apple.
   (Если ключ не задан — iOS-пуши просто не уходят, но ничего не ломается.)

---

## ЧАСТЬ 5. Проверка на телефоне (TestFlight)
1. Установи на iPhone приложение **TestFlight** (из App Store).
2. В App Store Connect → твоё приложение → **TestFlight** → добавь себя как тестировщика
   (Internal Testing → добавь свой Apple ID). Придёт приглашение.
3. Открой приглашение в TestFlight на телефоне, установи сборку.
4. Запусти приложение, **войди в аккаунт**, на запрос уведомлений нажми **Разрешить**.
5. Смени статус его заказа в кабинете продавца или напиши в чат по заказу → на телефон
   придёт уведомление, тап откроет заказ/чат.

---

## ЧАСТЬ 6. Отправка в App Store на ревью
1. App Store Connect → приложение → раздел версии (слева, напр. «1.0 Prepare for Submission»).
2. Заполни:
   - **Screenshots**: обязательны для 6.7″ и 6.5″ iPhone (сделай на симуляторе/телефоне).
   - **Description**, **Keywords**, **Support URL**, **Marketing URL** (по желанию).
   - **Privacy Policy URL** — обязателен.
   - **App Privacy** (слева отдельный раздел) — заполни, какие данные собираешь.
   - **Age Rating**, **Category** (напр. Food & Drink).
3. В блоке **Build** нажми **«+»** и выбери сборку, загруженную из Codemagic/TestFlight.
4. **Add for Review** → **Submit for Review**.
5. Вопрос про экспортное шифрование не всплывёт — в проекте уже стоит
   `ITSAppUsesNonExemptEncryption = false`.

Ревью обычно занимает от нескольких часов до 1–2 суток.

---

## Частые ошибки и что делать
- **Codemagic: «нет GoogleService-Info.plist»** → удали шаг-проверку из `codemagic.yaml`
  (Firebase не нужен) или оставь заглушку `Sources/GoogleService-Info.plist`.
- **Codemagic: ошибка подписи / no profile** → проверь, что App Store Connect API Key
  подключён (шаг 3.2) и `bundle_identifier` = `ru.marketplace.client.premium`.
- **App Store Connect: build number already used** → подними номер сборки (шаг 3.4).
- **Пуш не приходит** — смотри лог сервера `logs/push.log`:
  - `403 InvalidProviderToken` → неверный APNs Key ID / Team ID / .p8.
  - `400 BadDeviceToken` или `410 Unregistered` → не тот `APNS_ENV`
    (TestFlight/App Store = `production`; запуск из Xcode = `sandbox`).
  - `403 TopicDisallowed` → `APNS_BUNDLE_ID` не совпадает с bundle id.
  - Ошибка HTTP/2 → у хостинга curl без HTTP/2 (напиши мне — переключу на Firebase-канал).

---

## Что от тебя нужно по шагам (чек-лист)
- [ ] 1.1 App ID `ru.marketplace.client.premium` + Push.
- [ ] 1.2 APNs `.p8` + записать Key ID и Team ID.
- [ ] 1.3 App Store Connect API Key `.p8` + Issuer ID + Key ID.
- [ ] 2. Создать приложение в App Store Connect.
- [ ] 3.2 Подключить API-ключ в Codemagic.
- [ ] 3.3 Положить `codemagic.yaml` в репозиторий (убрать Firebase-проверку).
- [ ] 3.5 Запустить сборку → TestFlight.
- [ ] 4. Прописать APNs-ключ на сервере.
- [ ] 5. Проверить пуш через TestFlight.
- [ ] 6. Заполнить метаданные и Submit for Review.

Застрял на любом пункте — напиши номер шага, распишу ещё детальнее.

---

## ЧАСТЬ 7. Автопубликация в App Store (с 21.10.2026, как у приложения продавца)

В `codemagic.yaml` теперь два процесса:

| Процесс | Что делает |
|---|---|
| **Yumurta iOS (TestFlight)** (`ios-testflight`) | как раньше: собрать, загрузить, отправить в TestFlight. В App Store не подаёт |
| **Yumurta iOS — релиз в App Store** (`ios-release`) | создать карточку версии, вписать «Что нового» из `release-notes/ru.txt`, проверить, что Apple примет (иначе стоп **до** сборки), собрать, загрузить, **подать на проверку**, выпустить сразу после одобрения |
| **Yumurta iOS — довести зависшую заявку** (`ios-submit-draft`) | только руками и только если подача упала и остался черновик заявки |

Каждый выпуск:

1. `project.yml` — поднять **оба** номера: `CFBundleShortVersionString` и `MARKETING_VERSION` (после одобрения
   каждая версия закрывается — нужен новый номер; после отказа — тот же номер, просто новая сборка).
2. Переписать `release-notes/ru.txt` — это «Что нового» в магазине (без него Apple не примет обновление: 409 whatsNew).
3. Залить в GitHub **`codemagic.yaml`**, **`ci/asc_store.py`**, **`store/app.json`** (новые, 21.10.2026), `project.yml`,
   `release-notes/ru.txt` и код.
4. Codemagic → **Start new build** → **«Yumurta iOS — релиз в App Store»**. Запускать **один раз**.

Что искать в логе:

- «Версия X в App Store Connect свободна» — иначе шаг назовёт свободный номер и остановит сборку;
- «Карточка версии X … готова» — шаг сам создал карточку новой версии (или переименовал редактируемую);
- ««Что нового» на месте» — текст записан (заполненный руками не перетирается без `APP_STORE_WHATS_NEW_FORCE=1`);
- «Карточка готова к подаче.» — иначе список «Карточка НЕ готова» (нет «Что нового», вопрос анкеты возраста без
  ответа — например новый вопрос Apple `socialMedia`, — нет скриншотов) и остановка **до** сборки: заявка не потрачена.
  Вопрос анкеты — ответить в App Store Connect → «Возрастной рейтинг», затем запустить снова;
- «Занято из лимита Apple: N из 5» — Apple держит не больше пяти заявок, черновики тоже считаются;
- сама подача идёт **после** всех шагов, в пост-обработке Codemagic — вкладка **Publishing** у сборки: «submitted for
  review» или ошибка Apple. Упало и остался черновик — **не перезапускайте релиз**, запустите **«довести зависшую
  заявку»** (сначала проверьте в App Store Connect, что в версии нужная сборка).

API-ключ `yumurta_asc` должен быть с ролью **App Manager** или **Admin** (App Store Connect → Пользователи и доступ →
Интеграции): с ролью Developer создать карточку версии нельзя — шаг скажет «403», проверка остановит релиз до сборки.

Карточка (описание, скриншоты, «Конфиденциальность») у клиента уже заполнена и переходит в каждую новую версию —
её Codemagic не трогает. Бета-заявка в TestFlight в процессе релиза выключена: Apple держит на бета-проверке одну
сборку, и с ней подача в магазин падала бы раньше времени.
