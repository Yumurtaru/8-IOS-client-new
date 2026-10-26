//
//  ApplicationsView.swift — Мои отклики (premium-клиент)
//
//  Список откликов пользователя на вакансии. Токены — только YM. Light + dark,
//  Dynamic Type. Тексты — русские литералы.
//
//  ПРИВЯЗКА К API (реальный путь, сверено с routes/api_v1.php и Android):
//    • GET api/v1/profile/applications → [Application]
//      Сервер: id, status, created_at, title (вакансии), shop (название магазина).
//
//  Состояния: загрузка (skeleton) / пусто («Откликов нет») / ошибка + «Повторить».
//  Переиспользуем JobsEmptyState / JobsErrorState из Features/Jobs/JobsView.swift.
//

import SwiftUI

struct ApplicationsView: View {
    @State private var items: [Application] = []
    @State private var phase: LoadPhase = .loading

    enum LoadPhase { case loading, content, empty, error }

    var body: some View {
        ScrollView {
            switch phase {
            case .loading:
                VStack(spacing: YMSpace.md) {
                    ForEach(0..<4, id: \.self) { _ in SkeletonBox(radius: YMRadius.card).frame(height: 92) }
                }
                .padding(.horizontal, YMSpace.xl).padding(.top, YMSpace.sm)

            case .error:
                JobsErrorState { Task { await load() } }

            case .empty:
                // На «вы», как во всём приложении (было «Откликнись»).
                JobsEmptyState(emoji: "📨",
                               title: "Откликов нет",
                               hint: "Откликнитесь на вакансию в разделе «Вакансии» — отклики появятся здесь.")
                // Путь к вакансиям прямо отсюда: раньше нужно было вернуться
                // в профиль и искать раздел самому.
                NavigationLink { JobsView() } label: { Text("Смотреть вакансии") }
                    .buttonStyle(YMPrimaryButtonStyle())
                    .padding(.horizontal, YMSpace.xxxl)
                    .padding(.top, YMSpace.lg)

            case .content:
                LazyVStack(spacing: YMSpace.md) {
                    ForEach(items) { app in ApplicationCard(app: app) }
                }
                .padding(.horizontal, YMSpace.xl)
                .padding(.top, YMSpace.sm)
                .padding(.bottom, YMSpace.xxxl)
            }
        }
        .background(YMColor.bg.ignoresSafeArea())
        .navigationTitle("Мои отклики")
        .navigationBarTitleDisplayMode(.large)
        .task { if items.isEmpty { await load() } }
    }

    private func load() async {
        phase = .loading
        do {
            let list: [Application] = try await API.shared.list("api/v1/profile/applications")
            await MainActor.run {
                items = list
                phase = list.isEmpty ? .empty : .content
            }
        } catch {
            await MainActor.run { phase = .error }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Статус отклика → подпись + Kind (паритет с Android appStatusView)
// ─────────────────────────────────────────────────────────────────────────────

private enum AppStatus {
    // Сервер (applications.status): new/pending, viewed, invited, accepted, rejected.
    static func view(_ status: String?) -> (label: String, kind: StatusPill.Kind) {
        switch status?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "new", "pending": return ("На рассмотрении", .pending)
        case "viewed":         return ("Просмотрен", .enRoute)
        case "invited":        return ("Приглашение", .done)
        case "accepted":       return ("Принят", .done)
        case "rejected":       return ("Отказ", .cancel)
        default:
            let s = status?.trimmingCharacters(in: .whitespaces)
            return ((s?.isEmpty == false ? s! : "Отклик"), .enRoute)
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Карточка отклика
// ─────────────────────────────────────────────────────────────────────────────

private struct ApplicationCard: View {
    let app: Application

    private var status: (label: String, kind: StatusPill.Kind) { AppStatus.view(app.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            HStack(alignment: .top, spacing: YMSpace.sm) {
                Text(titleText)
                    .font(YMFont.headline).foregroundStyle(YMColor.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                StatusPill(text: status.label, kind: status.kind, solid: false)
            }
            if let shop = app.shop, !shop.isEmpty {
                Label(shop, systemImage: "storefront")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .labelStyle(.titleAndIcon).lineLimit(1)
            }
            if let created = app.createdAt, !created.isEmpty {
                Label(DateFmt.short(created), systemImage: "clock")
                    .font(YMFont.caption).foregroundStyle(YMColor.muted)
                    .labelStyle(.titleAndIcon)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(titleText), \(status.label)")
    }

    private var titleText: String {
        if let t = app.title, !t.isEmpty { return t }
        return "Вакансия"
    }
}
