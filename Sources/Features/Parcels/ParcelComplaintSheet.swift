import SwiftUI

// «Пожаловаться на курьера» по посылке (волна А81) — двойник openComplaint из
// assets/js/parcel.js. Причины — complaint_reasons.courier из GET /api/v1/pool/rules
// (кэш в PoolRulesInfo.cached), отправка — POST /api/v1/parcels/{id}/complaint
// {reason, comment}. Жалоба без денег: это не «Проблема с доставкой».

struct ParcelComplaintSheet: View {
    let parcelId: Int
    /// Жалоба принята: свежая карточка посылки из ответа.
    let onSent: (Parcel) -> Void
    /// 409 complaint_exists: жалоба уже есть — окно закрыто, текст показать, карточку перечитать.
    let onExists: (String) -> Void
    /// Отказ, после которого карточка могла устареть (no_courier, too_old, not_found): перечитать.
    let onStale: () -> Void

    /// Как на сервере (complaintIn): comment режется до 500, при other нужно ≥ 3 знаков.
    private static let maxComment = 500
    private static let ruleFallback = "Сервис только для грузов и посылок, пассажиров не перевозим"

    @Environment(\.dismiss) private var dismiss
    @State private var rules: PoolRulesInfo?
    @State private var loadError: String?
    @State private var loadTick = 0
    // Ввод не сбрасывается при ошибке отправки.
    @State private var reason = ""
    @State private var comment = ""
    @State private var sending = false
    @State private var reasonError: String?
    @State private var commentError: String?
    @State private var sendError: String?
    @FocusState private var focus: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: YMSpace.md) {
                    if let r = rules {
                        form(r)
                    } else if let e = loadError {
                        VStack(spacing: YMSpace.md) {
                            ParcelErrorLine(text: e)
                            Button("Повторить") { loadError = nil; loadTick += 1 }
                                .font(YMFont.headline).foregroundStyle(YMColor.accent)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .padding(.top, 30)
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                    }
                }
                .padding(YMSpace.xl)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(YMColor.bg.ignoresSafeArea())
            .navigationTitle("Пожаловаться на курьера")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }.disabled(sending)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { focus = false }
                }
            }
            .task(id: loadTick) { await loadRules() }
        }
        // Пока отправляем — смахнуть нельзя: исход должен дойти до карточки.
        .interactiveDismissDisabled(sending)
    }

    @ViewBuilder
    private func form(_ r: PoolRulesInfo) -> some View {
        Text("Что случилось").font(YMFont.subhead).foregroundStyle(YMColor.muted)
        VStack(spacing: 0) {
            ForEach(r.courierReasons, id: \.code) { item in
                Button {
                    Haptics.selection()
                    reason = item.code; reasonError = nil
                    if item.code != "other" { commentError = nil }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: reason == item.code ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 20)).foregroundStyle(reason == item.code ? YMColor.accent : YMColor.muted)
                        Text(item.label)
                            .font(item.code == "passenger" ? YMFont.callout.weight(.semibold) : YMFont.callout)
                            .foregroundStyle(YMColor.text).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(sending)
            }
        }
        if let e = reasonError { ParcelErrorLine(text: e) }

        Text(reason == "other" ? "Подробности (обязательно)" : "Подробности")
            .font(YMFont.subhead).foregroundStyle(YMColor.muted).padding(.top, 4)
        TextField("Что произошло и когда", text: $comment, axis: .vertical)
            .lineLimit(3...6)
            .focused($focus)
            .font(YMFont.body)
            .disabled(sending)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: YMRadius.control, style: .continuous)
                .strokeBorder(commentError != nil ? YMColor.statusCancel : Color.clear, lineWidth: 1))
            .ymMaxLength($comment, Self.maxComment)
            .onChange(of: comment) { _ in commentError = nil }
        HStack {
            if let e = commentError { ParcelErrorLine(text: e) }
            Spacer()
            Text("\(comment.count) / \(Self.maxComment)").font(YMFont.caption2).foregroundStyle(YMColor.muted)
        }
        Text((r.text.isEmpty ? Self.ruleFallback : r.text) + ". Жалобу рассмотрит администратор площадки. Курьер не видит, кто пожаловался.")
            .font(YMFont.caption).foregroundStyle(YMColor.muted)
            .fixedSize(horizontal: false, vertical: true)
        if let e = sendError {
            Text(e).font(YMFont.callout).foregroundStyle(YMColor.statusCancel)
                .padding(YMSpace.md).frame(maxWidth: .infinity, alignment: .leading)
                .background(YMColor.statusCancel.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        Button { send(r) } label: {
            HStack(spacing: 8) {
                if sending { ProgressView().tint(YMColor.onAccent) }
                Text(sending ? "Отправляем…" : "Отправить жалобу")
            }
        }
        .buttonStyle(YMPrimaryButtonStyle())
        .disabled(sending)
        .padding(.top, YMSpace.sm)
    }

    @MainActor private func loadRules() async {
        do {
            rules = try await ParcelAPI.rules()
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.userMessage ?? "Не удалось загрузить причины жалобы"
        }
    }

    private func send(_ r: PoolRulesInfo) {
        guard !sending else { return }
        focus = false
        reasonError = nil; commentError = nil; sendError = nil
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        // Проверка как на сервере, чтобы не гонять заведомый 422.
        guard r.courierReasons.contains(where: { $0.code == reason }) else { reasonError = "Выберите, что случилось"; return }
        if reason == "other" && text.count < 3 { commentError = "Опишите, что случилось"; return }
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do {
                let p = try await ParcelAPI.complain(parcelId, reason: reason, comment: text)
                Haptics.success()
                onSent(p)
                dismiss()
            } catch let f as ParcelFailure {
                Haptics.error()
                switch f.code {
                case "complaint_exists":
                    onExists(f.message)
                    dismiss()
                case "validation" where !f.fields.isEmpty:
                    // Текст сервера по reason — список кодов (passenger, rude…): человеку он
                    // ничего не скажет. Причины на сервере поменялись — перечитываем их.
                    if f.fields["reason"] != nil {
                        reasonError = "Выберите причину из списка"
                        PoolRulesInfo.cached = nil
                        loadTick += 1
                    }
                    commentError = f.fields["comment"]
                    if reasonError == nil && commentError == nil { sendError = f.message }
                default:
                    sendError = f.message
                    // Курьера сняли, срок вышел, посылки нет — кнопка в карточке могла пропасть.
                    if f.status == 404 || f.status == 409 { onStale() }
                }
            } catch is CancellationError {
            } catch {
                Haptics.error()
                sendError = error.userMessage ?? "Не удалось отправить жалобу"
            }
        }
    }
}
