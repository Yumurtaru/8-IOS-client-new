//
//  JobsView.swift — Вакансии (premium-клиент)
//
//  Список вакансий → деталь вакансии → форма отклика (имя + телефон).
//  Всё в одном файле: деталь пушится через NavigationLink, форма отклика — через .sheet.
//  Токены — только YM. Light + dark, Dynamic Type. Тексты — русские литералы.
//
//  ПРИВЯЗКА К API (реальные пути, сверено с routes/api_v1.php и Android-клиентом):
//    • GET  api/v1/jobs?city_id=<id>   → [Job]        (сервер фильтрует по city_id)
//    • GET  api/v1/jobs/{id}           → JobDetail
//    • POST api/v1/jobs/{id}/apply     ← form {name, phone}  (сервер читает $_POST!)
//
//  БАГ ГОРОДА (как чинили на Android): вакансии фильтруются по city_id; если у выбранного
//  города их нет — список пуст. Поэтому грузим с city_id, а при ПУСТОМ результате
//  повторяем запрос БЕЗ city_id (все вакансии площадки). Город — из Session.shared.cityId.
//
//  ВАЖНО про отклик: серверный эндпоинт читает $_POST['name'] / $_POST['phone'], а PHP не
//  наполняет $_POST из JSON-тела. Поэтому шлём form-urlencoded (API.postForm) — 1:1 с Android
//  @FormUrlEncoded. JSON-POST молча провалился бы в имя/телефон из профиля.
//

import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Форматтеры вакансии (паритет с Android salaryText/employmentText/experienceText)
// ─────────────────────────────────────────────────────────────────────────────

enum JobFormat {
    /// Зарплата → человекочитаемый диапазон. Деньги — через Money (Decimal, канон клиента).
    /// null/0 → «з/п не указана».
    static func salary(_ from: Double?, _ to: Double?) -> String {
        let f = from.flatMap { $0 > 0 ? $0 : nil }
        let t = to.flatMap { $0 > 0 ? $0 : nil }
        switch (f, t) {
        case let (f?, t?): return "\(Money.format(Money.parse(f))) – \(Money.format(Money.parse(t)))"
        case let (f?, nil): return "от \(Money.format(Money.parse(f)))"
        case let (nil, t?): return "до \(Money.format(Money.parse(t)))"
        default: return "з/п не указана"
        }
    }

    // Сервер: employment_type enum('full','part','project'); experience enum('none','1year','3years','5years').
    static func employment(_ v: String?) -> String? {
        switch v?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "full":    return "Полная занятость"
        case "part":    return "Частичная занятость"
        case "project": return "Проектная работа"
        case nil, "", "none", "не указано": return nil
        default: return v
        }
    }

    static func experience(_ v: String?) -> String? {
        switch v?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "none":   return "Без опыта"
        case "1year":  return "Опыт от 1 года"
        case "3years": return "Опыт от 3 лет"
        case "5years": return "Опыт от 5 лет"
        case nil, "":  return nil
        default: return v
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - JobsView (список)
// ─────────────────────────────────────────────────────────────────────────────

struct JobsView: View {
    @State private var jobs: [Job] = []
    @State private var phase: LoadPhase = .loading

    enum LoadPhase { case loading, content, empty, error }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                VStack(spacing: YMSpace.md) {
                    ForEach(0..<5, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 108) }
                }
                .padding(.horizontal, YMSpace.xl).padding(.top, YMSpace.sm)

            case .error:
                JobsErrorState { Task { await load() } }

            case .empty:
                // На «вы», как во всём приложении (было «Загляни позже»).
                JobsEmptyState(emoji: "💼",
                               title: "Вакансий нет",
                               hint: "Сейчас открытых вакансий нет. Загляните позже.")

            case .content:
                LazyVStack(spacing: YMSpace.md) {
                    ForEach(jobs) { job in
                        NavigationLink { JobDetailView(jobId: job.id) } label: {
                            JobCard(job: job)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, YMSpace.xxxl)
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Вакансии")
        .navigationBarTitleDisplayMode(.large)
        .task { if jobs.isEmpty { await load() } }
    }

    /// Город → фолбэк без города. Сервер фильтрует вакансии по city_id: пустой город = пустой
    /// список, поэтому при пустом ответе повторяем запрос без фильтра (паритет с Android).
    private func load() async {
        phase = .loading
        let cityId = Session.shared.cityId
        // П-21.3 (А58): вакансии постранично — собираем все страницы по has_more
        // (раньше видна была только первая).
        do {
            var list: [Job] = try await API.shared.allPages("api/v1/jobs", query: cityQuery(cityId)) { (j: Job) in j.id }
            if list.isEmpty, cityId != nil {
                // По городу пусто — показываем все вакансии площадки.
                // Запрос без города упал — это ошибка, а не «вакансий нет».
                do { list = try await API.shared.allPages("api/v1/jobs") { (j: Job) in j.id } }
                catch { await MainActor.run { phase = .error }; return }
            }
            // В @Sendable-замыкание — только let: захват var — ошибка сборки в Xcode 15.
            let found = list
            await MainActor.run {
                jobs = found
                phase = found.isEmpty ? .empty : .content
            }
        } catch {
            // На ошибке города пробуем без фильтра, прежде чем показывать ошибку.
            let all: [Job] = (try? await API.shared.allPages("api/v1/jobs") { (j: Job) in j.id }) ?? []
            await MainActor.run {
                jobs = all
                phase = all.isEmpty ? .error : .content
            }
        }
    }

    private func cityQuery(_ cityId: Int?) -> [String: String] {
        guard let cityId else { return [:] }
        return ["city_id": String(cityId)]
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Карточка вакансии
// ─────────────────────────────────────────────────────────────────────────────

/// Карточка вакансии. Общая: список «Профиль → Вакансии» и рубрика «Вакансии» в объявлениях.
struct JobCard: View {
    let job: Job

    private var chips: [String] {
        [job.schedule?.trimmingCharacters(in: .whitespaces),
         JobFormat.employment(job.employmentType),
         JobFormat.experience(job.experience)]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Text(job.title ?? "Вакансия")
                .font(YMFont.headline).foregroundStyle(YMColor.text)
                .lineLimit(2).multilineTextAlignment(.leading)

            Text(JobFormat.salary(job.salaryFrom, job.salaryTo))
                .font(.system(size: 15, weight: .heavy)).foregroundStyle(YMColor.accent)

            if let shop = job.shop, !shop.isEmpty {
                Label(shop, systemImage: "storefront")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .labelStyle(.titleAndIcon).lineLimit(1)
            }

            if !chips.isEmpty {
                JobChipRow(chips: chips)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(job.title ?? "Вакансия"), \(JobFormat.salary(job.salaryFrom, job.salaryTo))")
    }
}

/// Ряд чипов с переносом (аналог Android FlowRow).
private struct JobChipRow: View {
    let chips: [String]
    var body: some View {
        FlexibleWrap(spacing: YMSpace.sm) {
            ForEach(chips, id: \.self) { InfoChip(text: $0) }
        }
    }
}

private struct InfoChip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(YMFont.caption2).foregroundStyle(YMColor.text)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.chip, style: .continuous))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Деталь вакансии + форма отклика
// ─────────────────────────────────────────────────────────────────────────────

struct JobDetailView: View {
    let jobId: Int

    @State private var job: JobDetail?
    @State private var phase: DetailPhase = .loading
    @State private var showApply = false
    /// Отклик отправлен — кнопка неактивна: раньше каждое нажатие создавало ещё один.
    @State private var applied = false
    @State private var banner: (text: String, success: Bool)?

    enum DetailPhase { case loading, content, error }

    private var chips: [String] {
        guard let j = job else { return [] }
        return [j.schedule?.trimmingCharacters(in: .whitespaces),
                JobFormat.employment(j.employmentType),
                JobFormat.experience(j.experience)]
            .compactMap { $0 }.filter { !$0.isEmpty }
    }

    var body: some View {
        ZStack {
            YMColor.bg.ignoresSafeArea()
            switch phase {
            case .loading:
                VStack(spacing: YMSpace.md) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 80) }
                }
                .padding(.horizontal, YMSpace.xl).padding(.top, YMSpace.md)
                .frame(maxHeight: .infinity, alignment: .top)

            case .error:
                JobsErrorState { Task { await load() } }

            case .content:
                if let j = job {
                    content(j)
                } else {
                    JobsEmptyState(emoji: "💼", title: "Вакансия не найдена", hint: "Возможно, вакансия уже закрыта.")
                }
            }
        }
        .navigationTitle("Вакансия")
        .navigationBarTitleDisplayMode(.inline)
        .task { if job == nil { await load() } }
        .sheet(isPresented: $showApply) {
            ApplyFormView(jobId: jobId) { ok, message in
                banner = (message, ok); if ok { applied = true }
            }
        }
    }

    @ViewBuilder private func content(_ j: JobDetail) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: YMSpace.lg) {
                // Заголовок + зарплата + магазин/адрес
                VStack(alignment: .leading, spacing: YMSpace.sm) {
                    Text(j.title ?? "Вакансия").font(YMFont.title2).foregroundStyle(YMColor.text)
                    Text(JobFormat.salary(j.salaryFrom, j.salaryTo))
                        .font(YMFont.title3).foregroundStyle(YMColor.accent)
                    if let shop = j.shop, !shop.isEmpty {
                        Label(shop, systemImage: "storefront")
                            .font(YMFont.body).foregroundStyle(YMColor.muted).labelStyle(.titleAndIcon)
                    }
                    // Адрес самой вакансии (может отличаться от адреса заведения).
                    if let addr = (j.address?.isEmpty == false ? j.address : j.shopAddress), !addr.isEmpty {
                        Label(addr, systemImage: "mappin.and.ellipse")
                            .font(YMFont.caption).foregroundStyle(YMColor.muted).labelStyle(.titleAndIcon)
                    }
                }

                if !chips.isEmpty {
                    FlexibleWrap(spacing: YMSpace.sm) {
                        ForEach(chips, id: \.self) { InfoChip(text: $0) }
                    }
                }

                if let d = j.description, !d.isEmpty {
                    SectionBlock(title: "Описание", text: d)
                }
                if let r = j.requirements, !r.isEmpty {
                    SectionBlock(title: "Требования", text: r)
                }
                // Условия сервер присылает, но экран их не показывал.
                if let c = j.conditions, !c.isEmpty {
                    SectionBlock(title: "Условия", text: c)
                }

                if let banner {
                    ResultBanner(text: banner.text, success: banner.success)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.md)
            .padding(.bottom, YMSpace.xxxl)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Haptics.light()
                showApply = true
            } label: {
                Text(applied ? "Отклик отправлен" : "Откликнуться")
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(applied)
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.sm)
            .padding(.bottom, YMSpace.md)
            .background(.bar)
        }
    }

    private func load() async {
        phase = .loading
        do {
            let detail: JobDetail = try await API.shared.get("api/v1/jobs/\(jobId)")
            await MainActor.run { job = detail; phase = .content }
        } catch let e as APIError where e.rejectStatus == 404 {
            // Вакансию закрыли/удалили — это не «проверь соединение» с вечным
            // «Повторить»: показываем «Вакансия не найдена».
            await MainActor.run { job = nil; phase = .content }
        } catch {
            await MainActor.run { phase = .error }
        }
    }
}

private struct SectionBlock: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.xs) {
            Text(title).font(YMFont.headline).foregroundStyle(YMColor.text)
            Text(text).font(YMFont.body).foregroundStyle(YMColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ResultBanner: View {
    let text: String
    let success: Bool
    var body: some View {
        let color = success ? YMColor.statusDone : YMColor.statusCancel
        Label(text, systemImage: success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(YMFont.subhead).foregroundStyle(color)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(YMSpace.md)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Форма отклика (sheet): имя + телефон
// ─────────────────────────────────────────────────────────────────────────────

private struct ApplyFormView: View {
    let jobId: Int
    /// (success, message) — родитель показывает баннер результата.
    let onResult: (Bool, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var phone = ""
    @State private var sending = false
    @State private var error: String?

    private var valid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !phone.trimmingCharacters(in: .whitespaces).isEmpty
    }
    /// В телефоне 10–11 цифр: «123» раньше уходило работодателю, и связаться
    /// с соискателем было невозможно.
    private var phoneOk: Bool { (10...11).contains(phone.filter(\.isNumber).count) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Имя", text: $name)
                        .textContentType(.name)
                    TextField("Телефон", text: $phone)
                        .textContentType(.telephoneNumber)
                        .keyboardType(.phonePad)
                } header: {
                    Text("Ваши контакты")
                } footer: {
                    // В профиле нет телефона — поле пустое, а «Откликнуться»
                    // серая без объяснения. Говорим, чего не хватает.
                    if !valid { Text("Укажите имя и телефон — без них отклик не отправить") }
                }
                if let error {
                    Text(error).font(YMFont.caption).foregroundStyle(YMColor.statusCancel)
                }
                Section {
                    Button(action: submit) {
                        HStack {
                            Spacer()
                            if sending { ProgressView() } else { Text("Откликнуться").fontWeight(.bold) }
                            Spacer()
                        }
                    }
                    .disabled(!valid || sending)
                }
            }
            // У клавиатуры телефона нет «Готово» — убирается жестом прокрутки.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Отклик на вакансию")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(sending) } }
            // Пока отклик уходит, окно не закрывается: закрытое смахиванием
            // прятало ошибку, и человек не знал, дошёл ли отклик.
            .interactiveDismissDisabled(sending)
            // Автоподстановка имени/телефона из профиля — клиент подтверждает/правит.
            .task { await prefill() }
        }
        .tint(YMColor.accent)
    }

    private func prefill() async {
        guard Session.shared.isLoggedIn else { return }
        if let p: Profile = try? await API.shared.get("api/v1/profile") {
            await MainActor.run {
                if name.isEmpty, let n = p.name, !n.isEmpty { name = n }
                if phone.isEmpty, let ph = p.phone, !ph.isEmpty { phone = ph }
            }
        }
    }

    private func submit() {
        // Второе нажатие до перерисовки кнопки отправляло второй отклик.
        guard !sending, valid else { return }
        guard phoneOk else { error = "Проверьте номер телефона: нужно 10–11 цифр"; return }
        error = nil
        sending = true
        let n = name.trimmingCharacters(in: .whitespaces)
        let ph = phone.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                // form-urlencoded: сервер читает $_POST['name']/$_POST['phone'] (не JSON).
                // П-27.14: ключ повтора сервер учитывает только у вошедшего — гостю не шлём.
                try await API.shared.postFormVoid("api/v1/jobs/\(jobId)/apply", form: ["name": n, "phone": ph],
                                                  retryKey: TokenStore.access != nil)
                await MainActor.run {
                    Haptics.success()
                    sending = false
                    onResult(true, "Отклик отправлен!")
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    sending = false
                    self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить отклик"
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Общие состояния (пусто / ошибка) — переиспользуются в ApplicationsView
// ─────────────────────────────────────────────────────────────────────────────

struct JobsEmptyState: View {
    let emoji: String
    let title: String
    let hint: String
    var body: some View {
        VStack(spacing: YMSpace.sm) {
            Text(emoji).font(.system(size: 44))
            Text(title).font(YMFont.title3).foregroundStyle(YMColor.text)
            Text(hint)
                .font(YMFont.callout).foregroundStyle(YMColor.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 64)
    }
}

struct JobsErrorState: View {
    var onRetry: () -> Void
    var body: some View {
        VStack(spacing: YMSpace.md) {
            Text("⚠️").font(.system(size: 44))
            Text("Не удалось загрузить").font(YMFont.title3).foregroundStyle(YMColor.text)
            // На «вы», как во всём приложении.
            Text("Проверьте соединение и попробуйте снова.")
                .font(YMFont.callout).foregroundStyle(YMColor.muted).multilineTextAlignment(.center)
            Button { Haptics.light(); onRetry() } label: {
                Text("Повторить").font(YMFont.headline).foregroundStyle(YMColor.accent)
                    .padding(.horizontal, YMSpace.xxl).padding(.vertical, YMSpace.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                            .strokeBorder(YMColor.accent.opacity(0.55), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .padding(.top, YMSpace.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, YMSpace.xxxl).padding(.top, 64)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - FlexibleWrap — простой перенос чипов по строкам (аналог FlowRow)
// ─────────────────────────────────────────────────────────────────────────────

/// Лёгкая обёртка на базе Layout (iOS 16+): раскладывает субвью в строки с переносом.
struct FlexibleWrap: Layout {
    var spacing: CGFloat = 8

    /// Размер чипа не шире строки: длинный график («5/2 с 9:00 до 21:00, …»)
    /// раньше мерился в одну линию и уезжал за край карточки — теперь переносится.
    private func chipSize(_ v: LayoutSubview, maxW: CGFloat) -> CGSize {
        let s = v.sizeThatFits(.unspecified)
        guard maxW.isFinite, s.width > maxW else { return s }
        return v.sizeThatFits(ProposedViewSize(width: maxW, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = chipSize(v, maxW: maxW)
            if x + s.width > maxW, x > 0 {
                x = 0; y += rowH + spacing; rowH = 0
            }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let maxW = bounds.width
        var x: CGFloat = bounds.minX, y: CGFloat = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = chipSize(v, maxW: maxW)
            if x + s.width > bounds.minX + maxW, x > bounds.minX {
                x = bounds.minX; y += rowH + spacing; rowH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
