import SwiftUI

/*
 ============================================================================
  «Мои поездки» — брони жилья клиента.

  Отдельный экран, а не вкладка в «Заказах»: бронь жилья технически ЯВЛЯЕТСЯ
  заказом (так устроена финансовая модель — orders + комиссии + кошелёк), но
  человеку от неё нужны даты, адрес и время заезда, а не состав заказа.
 ============================================================================
 */

@MainActor
final class LodgingTripsVM: ObservableObject {
    @Published var trips: [LodgingTrip] = []
    @Published var loading = true
    @Published var message: String?
    @Published var cancelling = false
    /// Ошибка загрузки. Раньше без сети писали «Поездок пока нет», а неудачное
    /// обновление жестом стирало уже показанный список.
    @Published var loadError: String?

    func load() async {
        loading = true
        // Отмена обновления жестом раньше опустошала список поездок (try? → []).
        do {
            trips = try await API.shared.lodgingTrips()
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = (error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить поездки"
        }
        loading = false
    }

    func cancel(_ trip: LodgingTrip) async {
        guard !cancelling else { return }
        cancelling = true
        defer { cancelling = false }
        do {
            let r = try await API.shared.lodgingCancel(bookingId: trip.identifier)
            message = LodgingText.cancelResult(r)
            await load()
        } catch {
            message = error.localizedDescription
            // Повторная отмена (уже отменена с другого устройства, хозяин
            // отклонил, брони нет) — карточка устарела: перечитываем список,
            // иначе «Отменить» оставалась и снова отвечала отказом.
            if let s = (error as? APIError)?.rejectStatus, [404, 409, 422].contains(s) { await load() }
        }
    }
}

struct LodgingTripsView: View {
    @EnvironmentObject private var session: Session
    @StateObject private var vm = LodgingTripsVM()

    /// Бронь, для которой спрашиваем подтверждение отмены.
    @State private var toCancel: LodgingTrip?

    /// ОДНО состояние навигации на экран (см. предупреждение в HomeView).
    private enum Route: Hashable {
        case unit(String)
        case auth
    }
    @State private var route: Route?

    /// Экран сняли со стека не своей кнопкой «Назад» (долгое нажатие «Назад»,
    /// вход, закрывший себя сам) — route мог остаться «висеть», и бронь больше
    /// не открывалась (как на Главной). Сначала сбрасываем, потом идём.
    private func go(_ r: Route) {
        if route == nil { route = r; return }
        route = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { route = r }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: YMSpace.md) {
                // Обновление не прошло, а брони уже на экране: раньше сбой был
                // незаметен — человек считал статусы актуальными.
                if let e = vm.loadError, !vm.trips.isEmpty, !vm.loading {
                    Text("Не удалось обновить: " + e)
                        .font(YMFont.caption)
                        .foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(vm.trips) { t in
                    LodgingTripCard(
                        trip: t,
                        onOpen: {
                            if let s = t.unit?.slug, !s.isEmpty {
                                Haptics.light()
                                go(.unit(s))
                            }
                        },
                        onCancel: { if !vm.cancelling { toCancel = t } }
                    )
                }

                if !session.isLoggedIn {
                    // Брони живут в аккаунте (сервер: ['auth']) — без входа
                    // показывать нечего, и пустой список тут врал бы.
                    VStack(alignment: .leading, spacing: YMSpace.sm) {
                        Text("Войдите в аккаунт")
                            .font(YMFont.headline).foregroundStyle(YMColor.text)
                        Text("Брони жилья хранятся в вашем профиле.")
                            .font(YMFont.callout).foregroundStyle(YMColor.muted)
                        Button("Войти") { go(.auth) }
                            .buttonStyle(YMPrimaryButtonStyle())
                            .padding(.top, YMSpace.sm)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, YMSpace.md)
                } else if vm.loading && vm.trips.isEmpty {
                    ForEach(0..<2, id: \.self) { _ in
                        SkeletonBox(radius: YMRadius.card).frame(height: 150)
                    }
                } else if !vm.loading && vm.trips.isEmpty, let e = vm.loadError {
                    Text(e + ". Потяните вниз, чтобы обновить.")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, YMSpace.md)
                } else if !vm.loading && vm.trips.isEmpty {
                    // Экран и так внутри «Жилья» (открыт из поиска): совет идти
                    // «на главную» уводил из раздела.
                    Text("Поездок пока нет. Найдите жильё в поиске — после брони поездка появится здесь.")
                        .font(YMFont.callout)
                        .foregroundStyle(YMColor.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, YMSpace.md)
                }

                Color.clear.frame(height: YMSpace.xxl)
            }
            .padding(.horizontal, YMSpace.xl)
            .padding(.top, YMSpace.md)
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои поездки")
        .navigationBarTitleDisplayMode(.inline)
        .task { if session.isLoggedIn { await vm.load() } }
        .onChange(of: session.isLoggedIn) { logged in
            if logged { Task { await vm.load() } }
            // Сессия кончилась (или выход) на открытом экране: брони прежнего
            // аккаунта оставались видны под надписью «Войдите в аккаунт».
            else { vm.trips = []; vm.loadError = nil }
        }
        .refreshable { if session.isLoggedIn { await vm.load() } }
        .confirmationDialog(
            "Отменить бронь?",
            isPresented: Binding(get: { toCancel != nil }, set: { if !$0 { toCancel = nil } }),
            titleVisibility: .visible
        ) {
            Button("Отменить бронь", role: .destructive) {
                if let t = toCancel {
                    toCancel = nil
                    Task { await vm.cancel(t) }
                }
            }
            Button("Оставить", role: .cancel) { toCancel = nil }
        } message: {
            Text(cancelWarning)
        }
        .alert(vm.message ?? "", isPresented: Binding(
            get: { vm.message != nil }, set: { if !$0 { vm.message = nil } }
        )) {
            Button("Понятно") { vm.message = nil }
        }
        .navigationDestination(isPresented: Binding(
            get: { route != nil }, set: { if !$0 { route = nil } }
        )) {
            switch route {
            case .unit(let s): LodgingUnitView(slug: s)
            case .auth:        AuthView()
            case .none:        EmptyView()
            }
        }
    }

    /// Предупреждение про срок бесплатной отмены — текст собирает LodgingText,
    /// он же проверяется тестами на реальных бронях.
    private var cancelWarning: String {
        guard let t = toCancel else { return "" }
        return LodgingText.cancelWarning(t)
    }
}

private struct LodgingTripCard: View {
    let trip: LodgingTrip
    let onOpen: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            info
                .contentShape(Rectangle())
                .onTapGesture(perform: onOpen)

            HStack {
                Text(Money.format(trip.totalValue))
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                Spacer()
                if trip.cancellable {
                    Button("Отменить") {
                        Haptics.warning()
                        onCancel()
                    }
                    .font(YMFont.subhead)
                    .foregroundStyle(YMColor.statusCancel)
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, YMSpace.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.md)
        .ymCard()
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(trip.unit?.title ?? "Объект")
                        .font(YMFont.headline).foregroundStyle(YMColor.text)
                        .multilineTextAlignment(.leading)
                    Text(LodgingText.join([trip.unit?.subtypeLabel, trip.shop?.name]))
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                Spacer(minLength: YMSpace.sm)
                StatusPill(text: trip.statusText, kind: pillKind, solid: false)
            }

            Text(LodgingText.tripDates(trip))
                .font(YMFont.body).foregroundStyle(YMColor.text)
                .padding(.top, YMSpace.sm)

            Text(LodgingText.tripStay(trip))
                .font(YMFont.caption).foregroundStyle(YMColor.muted)

            if let ph = trip.shop?.phone, !ph.isEmpty {
                // Номер был простым текстом: ни позвонить, ни скопировать —
                // перед заездом гость перепечатывал его вручную.
                let digits = ph.filter { $0.isNumber || $0 == "+" }
                if !digits.isEmpty, let url = URL(string: "tel:" + digits) {
                    Link(destination: url) {
                        Text("Телефон объекта: " + ph)
                            .font(YMFont.caption).foregroundStyle(YMColor.accent)
                    }
                } else {
                    Text("Телефон объекта: " + ph)
                        .font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Цвет бейджа по коду состояния брони (подпись даёт сервер).
    /// Сам разбор кодов — в LodgingText.tone, он под тестами.
    private var pillKind: StatusPill.Kind {
        switch LodgingText.tone(trip.status) {
        case .cancel:  return .cancel
        case .done:    return .done
        case .active:  return .enRoute
        case .pending: return .pending
        }
    }
}
