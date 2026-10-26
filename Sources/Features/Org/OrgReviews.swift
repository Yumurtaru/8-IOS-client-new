import SwiftUI

//
//  OrgReviews.swift — секция «Отзывы» карточки организации (премиум-стиль YM*).
//  1:1 с Android OrgReviews.kt.
//
//  Данные грузит OrgViewModel: GET api/v1/shops/{slug}/reviews -> [Review].
//  Review (Net/Models.swift): ratingOverall: Int?, text, author, isVerified: Int?,
//                             createdAt, photos: [String]?, reply, replyAt.
//
//  Состояния: загрузка (скелет) / ошибка (мягкая плашка) / пусто / список.
//  Средний рейтинг и кол-во оценок — из ShopDetail (rating + reviewsCount), крупно над списком.
//  Деньги здесь не участвуют. NULL-безопасность всюду.
//

// MARK: - Сводка отзывов (встраивается в sheet OrgView; тап → отдельный экран ReviewsScreen)

struct OrgReviewsSection: View {
    /// Slug организации — ключ загрузки полного экрана отзывов.
    let slug: String
    let reviews: [Review]
    let loading: Bool
    let error: String?
    let avgRating: Double?
    let reviewsCount: Int?
    /// «Повторить» после сбоя загрузки. nil — кнопки нет (как раньше).
    var onRetry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Нажимаемая строка «Отзывы · ★N · N отзывов ›» — push на полный экран.
            NavigationLink {
                ReviewsScreen(slug: slug, avgRating: avgRating, reviewsCount: reviewsCount)
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    Text("Отзывы")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(YMColor.text)
                    Spacer(minLength: 8)
                    let cnt = reviewsCount ?? 0
                    if cnt > 0 || (avgRating ?? 0) > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(YMColor.accent)
                            Text(fmtRating1(avgRating))
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(YMColor.text)
                            if cnt > 0 {
                                Text("· \(pluralReviews(cnt))")
                                    .font(.system(size: 13))
                                    .foregroundStyle(YMColor.muted)
                            }
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(YMColor.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Краткое превью: первые 2 отзыва (или состояние загрузки/пусто).
            Group {
                if loading {
                    VStack(spacing: 10) {
                        ForEach(0..<2, id: \.self) { _ in
                            SkeletonBox(radius: 16).frame(height: 96)
                        }
                    }
                } else if let e = error, !e.isEmpty {
                    // Сбой — с причиной и «Повторить»: раньше отзывы возвращались
                    // только после перезахода в заведение.
                    VStack(spacing: 8) {
                        ReviewsNotice(text: "Не удалось загрузить отзывы: \(e)")
                        if let retry = onRetry {
                            Button("Повторить", action: retry)
                                .font(.system(size: 14.5, weight: .bold))
                                .foregroundStyle(YMColor.accent)
                        }
                    }
                } else if reviews.isEmpty {
                    ReviewsNotice(text: "Пока нет отзывов. Будьте первым!")
                } else {
                    VStack(spacing: 10) {
                        // По позиции: Review.id («автор-дата») бывает одинаковым у разных отзывов.
                        ForEach(Array(reviews.prefix(2).enumerated()), id: \.offset) { _, r in OrgReviewCard(review: r) }
                    }
                    if reviews.count > 2 {
                        NavigationLink {
                            ReviewsScreen(slug: slug, avgRating: avgRating, reviewsCount: reviewsCount)
                        } label: {
                            Text("Все отзывы ›")
                                .font(.system(size: 14.5, weight: .bold))
                                .foregroundStyle(YMColor.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(YMColor.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Карточка отзыва

/// П-21.4: тело жалобы на отзыв — POST api/v1/complaints (snake_case сам).
private struct ReviewComplaintBody: Encodable {
    let targetType: String
    let targetId: Int
    let reason: String
}

/// П-21.4: причины жалобы — уходят текстом в reason.
private let reviewReportReasons = ["Спам", "Оскорбление", "Неправда", "Другое"]

struct OrgReviewCard: View {
    let review: Review

    // П-21.4: жалоба на отзыв. «Отправлено» помним по id отзыва, а не по
    // позиции карточки: после перезагрузки списка на месте может быть другой.
    @State private var showReport = false
    @State private var reportSending = false
    @State private var reportSentFor: Int?
    @State private var reportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Звёзды + «проверенный».
            HStack(spacing: 8) {
                StarRow(rating: review.ratingOverall ?? 0)
                if (review.isVerified ?? 0) == 1 {
                    VerifiedBadge()
                }
            }

            if let t = review.text, !t.isEmpty {
                Text(t)
                    .font(.system(size: 14.5))
                    .foregroundStyle(YMColor.text)
                    .padding(.top, 8)
            }

            // Фото отзыва (горизонтальная лента).
            let photos = (review.photos ?? []).filter { !$0.isEmpty }
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(photos.enumerated()), id: \.offset) { idx, ph in
                            PhotoPlaceholder(url: API.imageURL(ph),
                                             label: "ФОТО", radius: 12, tone: idx)
                                .frame(width: 84, height: 84)
                        }
                    }
                }
                .padding(.top, 10)
            }

            // Автор + дата.
            HStack {
                Text((review.author?.isEmpty == false ? review.author! : "Гость"))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(YMColor.muted)
                Spacer(minLength: 8)
                if let d = review.createdAt, !d.isEmpty {
                    Text(fmtReviewDate(d))
                        .font(.system(size: 11.5))
                        .foregroundStyle(YMColor.muted)
                }
            }
            .padding(.top, 10)

            // Ответ организации (аддитивно): показываем, если продавец ответил.
            if let reply = review.reply, !reply.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ответ организации")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(YMColor.accent)
                    Text(reply)
                        .font(.system(size: 12))
                        .foregroundStyle(YMColor.text)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .padding(.top, 10)
            }

            // П-21.4: «Пожаловаться» — только если сервер прислал id отзыва и
            // человек вошёл (жалоба гостя дала бы 401).
            if let rid = review.serverId, Session.shared.isLoggedIn {
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if reportSentFor == rid || ReviewComplaints.sent.contains(rid) {
                        Text("Жалоба отправлена")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(YMColor.statusDone)
                    } else if reportSending {
                        ProgressView()
                    } else {
                        Button { Haptics.light(); showReport = true } label: {
                            Text("Пожаловаться")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(YMColor.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 8)
                if let e = reportError {
                    Text(e)
                        .font(.system(size: 12))
                        .foregroundStyle(YMColor.statusCancel)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(YMColor.hairline, lineWidth: 1))
        .confirmationDialog("Пожаловаться на отзыв", isPresented: $showReport, titleVisibility: .visible) {
            ForEach(reviewReportReasons, id: \.self) { r in
                Button(r) { Task { await sendReport(reason: r) } }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    /// П-21.4: POST api/v1/complaints {target_type:"review", target_id, reason}.
    /// Повторное нажатие во время отправки не шлёт вторую жалобу.
    @MainActor
    private func sendReport(reason: String) async {
        guard let rid = review.serverId, !reportSending, reportSentFor != rid,
              !ReviewComplaints.sent.contains(rid) else { return }
        reportSending = true; reportError = nil
        defer { reportSending = false }
        do {
            // П-27.14: ключ повтора — повтор после обрыва связи не шлёт вторую жалобу.
            try await API.shared.postVoid("api/v1/complaints",
                body: ReviewComplaintBody(targetType: "review", targetId: rid, reason: reason),
                retryKey: true)
            Haptics.success()
            ReviewComplaints.sent.insert(rid)
            reportSentFor = rid
        } catch is CancellationError {
        } catch {
            Haptics.error()
            reportError = (error as? LocalizedError)?.errorDescription ?? "Не удалось отправить жалобу"
        }
    }
}

// MARK: - Ряд из 5 звёзд

struct StarRow: View {
    let rating: Int
    var size: CGFloat = 15

    var body: some View {
        let r = min(max(rating, 0), 5)
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                Image(systemName: i < r ? "star.fill" : "star")
                    .font(.system(size: size))
                    .foregroundStyle(i < r ? YMColor.accent : YMColor.muted)
            }
        }
    }
}

// MARK: - Бейдж «ПРОВЕРЕННЫЙ»

private struct VerifiedBadge: View {
    var body: some View {
        Text("ПРОВЕРЕННЫЙ")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.3)
            .foregroundStyle(YMColor.statusDone)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(YMColor.statusDone.opacity(0.16), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - Мягкая инфо-плашка (пусто / ошибка)

private struct ReviewsNotice: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14.5))
            .foregroundStyle(YMColor.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22).padding(.horizontal, 16)
            .background(YMColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(YMColor.hairline, lineWidth: 1))
    }
}

// MARK: - Хелперы

/// Средний рейтинг с одним знаком: 4 -> "4.0", 4.5 -> "4.5".
private func fmtRating1(_ r: Double?) -> String {
    let v = r ?? 0
    if v == v.rounded(.towardZero) { return "\(Int(v)).0" }
    return String(format: "%.1f", v)
}

/// Склонение «отзыв / отзыва / отзывов».
private func pluralReviews(_ n: Int) -> String {
    let mod10 = n % 10, mod100 = n % 100
    let word: String
    if mod10 == 1 && mod100 != 11 { word = "отзыв" }
    else if (2...4).contains(mod10) && !(12...14).contains(mod100) { word = "отзыва" }
    else { word = "отзывов" }
    return "\(n) \(word)"
}

/// "2026-07-03 14:22:10" / "2026-07-03T14:22:10" -> "03.07.2026". Толерантно к формату.
private func fmtReviewDate(_ raw: String) -> String {
    let datePart = raw.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "T", with: " ")
        .split(separator: " ").first.map(String.init) ?? raw
    let p = datePart.split(separator: "-").map(String.init)
    if p.count == 3, p[0].count == 4 { return "\(p[2]).\(p[1]).\(p[0])" }
    return datePart
}

/// Отзывы, на которые уже пожаловались в этом запуске. Карточка на странице заведения
/// и полный список — разные экземпляры: без общего списка можно было отправить
/// вторую жалобу на тот же отзыв.
enum ReviewComplaints {
    static var sent = Set<Int>()
}
