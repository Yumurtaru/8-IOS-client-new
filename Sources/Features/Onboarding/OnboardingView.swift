import SwiftUI

/// Определение города по геолокации ещё не реализовано.
private let onboardingGeoEnabled = false

/// Онбординг premium-клиента (1:1 с OnboardingPhone.dc.html): welcome → city.
/// По завершении вызывает onFinish (в YumurtaApp он выставляет @AppStorage onboarded).
/// Выбранный город сохраняется в Session (cityId/cityName) — единый фильтр по городу
/// для всего каталога. Экран показывается пока онбординг не пройден.
struct OnboardingView: View {
    var onFinish: () -> Void

    @EnvironmentObject private var session: Session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step { case welcome, city }
    @State private var step: Step = .welcome
    @State private var showAuth = false

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                WelcomeStep(
                    onStart: { advanceToCity() },
                    onHasAccount: { showAuth = true }   // вход по телефону/паролю
                )
                .transition(.opacity)
            case .city:
                CityStep(onContinue: { finish() })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .sheet(isPresented: $showAuth) {
            NavigationStack {
                AuthView(onAuthed: { showAuth = false; advanceToCity() })
            }
            // sheet не наследует окружение автоматически — пробрасываем session явно.
            .environmentObject(session)
        }
    }

    private func advanceToCity() {
        withAnimation(YMMotion.adaptive(YMMotion.spring, reduceMotion: reduceMotion)) {
            step = .city
        }
    }

    private func finish() {
        Haptics.success()
        onFinish()
    }
}

// MARK: - Welcome

private struct WelcomeStep: View {
    var onStart: () -> Void
    var onHasAccount: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var floatUp = false

    var body: some View {
        ZStack {
            // Тёплый радиальный фон (welcomeBg из макета).
            LinearGradient(
                colors: [Color(hex: "#1A1712"), Color(hex: "#0B0B0D")],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
            // Золотое свечение из правого верхнего угла.
            Circle()
                .fill(
                    RadialGradient(colors: [YMPalette.gold.opacity(0.35), .clear],
                                   center: .center, startRadius: 4, endRadius: 180)
                )
                .frame(width: 280, height: 280)
                .offset(x: 120, y: -300)
                .ignoresSafeArea()

            VStack {
                Spacer()
                // Лого-плитка 104×104 r30 с золотым градиентом и float.
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(LinearGradient(colors: [Color(hex: "#E8B44A"), Color(hex: "#D69528")],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 104, height: 104)
                    .overlay(
                        Text("Y")
                            .font(.system(size: 52, weight: .heavy))
                            .foregroundStyle(YMPalette.goldInk)
                    )
                    .shadow(color: YMPalette.gold.opacity(0.5), radius: 30, y: 24)
                    .offset(y: floatUp ? -10 : 0)

                Text("Yumurta")
                    .font(.system(size: 38, weight: .heavy))
                    .tracking(-1)
                    .foregroundStyle(Color(hex: "#F6F5F1"))
                    .padding(.top, 34)

                Text("Рестораны, магазины и услуги вашего города — в одном приложении.")
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color(hex: "#B8B7BD"))
                    .frame(maxWidth: 280)
                    .padding(.top, 14)

                Spacer()

                VStack(spacing: YMSpace.md) {
                    Button("Начать", action: { Haptics.light(); onStart() })
                        .buttonStyle(YMPrimaryButtonStyle())
                    Button("У меня есть аккаунт", action: onHasAccount)
                        .buttonStyle(YMGhostButtonStyle(color: Color(hex: "#B8B7BD")))
                }
                .padding(.horizontal, YMSpace.xxl)
                .padding(.bottom, 48)
            }
            .padding(.horizontal, YMSpace.lg)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                floatUp = true
            }
        }
    }
}

// MARK: - City picker

private struct CityStep: View {
    var onContinue: () -> Void

    @EnvironmentObject private var session: Session

    @State private var cities: [City] = []          // города С ОРГАНИЗАЦИЯМИ (с сервера)
    @State private var query = ""
    @State private var selectedName: String = ""
    @State private var selectedId: Int? = nil
    // Список городов не загрузился (первый запуск без сети): раньше «Продолжить»
    // оставалась выключенной навсегда, повтора не было — человек застревал на
    // онбординге до перезапуска. Теперь можно продолжить без города: Главная
    // сама возьмёт первый город, когда появится связь.
    @State private var citiesFailed = false
    /// Список ещё грузится. Без сети запрос ждёт связь до 40 с, и всё это время
    /// под заголовком было пусто — казалось, что городов нет.
    @State private var citiesLoading = false

    // Список для отображения: только города, где есть заведения (+ поиск по ним).
    private var shownNames: [String] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = cities.compactMap { $0.name }
        if q.isEmpty { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Заголовок.
            VStack(alignment: .leading, spacing: 8) {
                Text("Ваш город")
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.6)
                    .foregroundStyle(YMColor.text)
                Text("Покажем рестораны, магазины и услуги рядом с вами.")
                    .font(.system(size: 14.5))
                    .lineSpacing(2)
                    .foregroundStyle(YMColor.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, YMSpace.xxl)
            .padding(.top, 14)

            // Определить автоматически (гео). Кнопка пока ничего не делает
            // (определение по CLLocation не сделано) — скрыта, чтобы не выглядеть
            // сломанной (и не ловить отказ App Review за нерабочий элемент).
            if onboardingGeoEnabled {
            // Определить автоматически (гео).
            Button {
                Haptics.light()
                // TODO(geo): определение города по CLLocation (следующая волна).
            } label: {
                HStack(spacing: YMSpace.md) {
                    Text("📍")
                        .font(.system(size: 19))
                        .frame(width: 40, height: 40)
                        .background(YMColor.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Определить автоматически")
                            .font(.system(size: 14.5, weight: .heavy))
                            .foregroundStyle(YMColor.text)
                        Text("По вашей геолокации")
                            .font(.system(size: 12))
                            .foregroundStyle(YMColor.muted)
                    }
                    Spacer()
                    Text("›").font(.system(size: 20)).foregroundStyle(YMColor.accent)
                }
                .padding(14)
                .background(YMColor.accent.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(YMColor.accent.opacity(0.3), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, YMSpace.xxl)
            .padding(.top, 14)
            }

            // Поиск города.
            SearchField(placeholder: "Поиск города", text: $query)
                .padding(.horizontal, YMSpace.xxl)
                .padding(.top, 16)

            // Список городов.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("ГОРОДА С ЗАВЕДЕНИЯМИ")
                            .font(.system(size: 12, weight: .heavy))
                            .tracking(0.6)
                            .foregroundStyle(YMColor.muted)
                            .padding(.horizontal, YMSpace.xxl)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                    }
                    ForEach(shownNames, id: \.self) { name in
                        cityRow(name)
                    }
                    // Паритет с Android: поиск ничего не нашёл — говорим об этом,
                    // а не оставляем пустой список без слова.
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty && shownNames.isEmpty && !cities.isEmpty {
                        Text("Город не найден. Пока Yumurta работает только в городах из списка")
                            .font(.system(size: 14))
                            .foregroundStyle(YMColor.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, YMSpace.xxl)
                            .padding(.top, 12)
                    }
                    if citiesLoading && cities.isEmpty {
                        ProgressView()
                            .tint(YMColor.accent)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 24)
                    }
                    // Первый запуск без сети: раньше под заголовком было пусто и без
                    // объяснения, повторить загрузку было нельзя до перезапуска.
                    if citiesFailed && cities.isEmpty {
                        VStack(alignment: .leading, spacing: YMSpace.sm) {
                            Text("Не удалось загрузить список городов. Проверьте интернет или продолжите — город можно выбрать позже на главной.")
                                .font(.system(size: 14))
                                .foregroundStyle(YMColor.muted)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Повторить") { Task { await loadCities() } }
                                .font(.system(size: 14.5, weight: .bold))
                                .foregroundStyle(YMColor.accent)
                        }
                        .padding(.horizontal, YMSpace.xxl)
                        .padding(.top, 12)
                    }
                }
                .padding(.bottom, 120)
            }

            Spacer(minLength: 0)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            // Нижняя закреплённая кнопка «Продолжить · <город>».
            Button(selectedName.isEmpty ? "Продолжить" : "Продолжить · \(selectedName)") {
                commitSelection()
                onContinue()
            }
            .buttonStyle(YMPrimaryButtonStyle())
            .disabled(selectedName.isEmpty && !citiesFailed && !cities.isEmpty)   // пустой список городов не запирает экран
            .padding(.horizontal, YMSpace.xxl)
            .padding(.top, 14)
            .padding(.bottom, 30)
            .background(.ultraThinMaterial)
            .overlay(Rectangle().fill(YMColor.hairline).frame(height: 1), alignment: .top)
        }
        .task { await loadCities() }
    }

    private func cityRow(_ name: String) -> some View {
        let selected = name == selectedName
        return Button {
            Haptics.selection()
            selectedName = name
            selectedId = cities.first { $0.name == name }?.id
        } label: {
            HStack(spacing: YMSpace.md) {
                Text("🏙️").font(.system(size: 18))
                Text(name)
                    .font(.system(size: 15.5, weight: selected ? .heavy : .semibold))
                    .foregroundStyle(YMColor.text)
                Spacer()
                if selected {
                    Text("✓")
                        .font(.system(size: 14, weight: .black))
                        .foregroundStyle(YMPalette.goldInk)
                        .frame(width: 24, height: 24)
                        .background(YMColor.accent, in: Circle())
                }
            }
            .padding(.horizontal, YMSpace.xxl)
            .padding(.vertical, 14)
            .overlay(Rectangle().fill(YMColor.hairline).frame(height: 1), alignment: .bottom)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func loadCities() async {
        // Только города, где есть активные организации.
        citiesFailed = false
        citiesLoading = true
        defer { citiesLoading = false }
        guard let list: [City] = try? await API.shared.list("api/v1/cities", query: ["with_orgs": "1"]) else {
            citiesFailed = true
            return
        }
        cities = list
        // Паритет с Android: после выхода из аккаунта онбординг повторяется —
        // отмечаем уже выбранный город, а не первый в списке: иначе «Продолжить»
        // молча переносил человека в другой город.
        if selectedName.isEmpty, let cur = session.cityId,
           let mine = list.first(where: { $0.id == cur }), let nm = mine.name, !nm.isEmpty {
            selectedName = nm
            selectedId = mine.id
        } else if let match = list.first(where: { $0.name == selectedName }) {
            selectedId = match.id
        } else if let first = list.first {
            selectedName = first.name ?? ""
            selectedId = first.id
        }
    }

    private func commitSelection() {
        // Пустое имя не пишем: иначе Главная показала бы город без названия.
        if !selectedName.isEmpty { session.cityName = selectedName }
        // id может отсутствовать (сеть недоступна) — Home тогда возьмёт первый город из /cities.
        if let id = selectedId ?? cities.first(where: { $0.name == selectedName })?.id {
            session.cityId = id
        }
    }
}
