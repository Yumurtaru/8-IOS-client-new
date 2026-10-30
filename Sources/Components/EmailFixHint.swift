import SwiftUI

/// А114: ответ сервера 422 `email_invalid` у поля почты (регистрация, смена почты):
/// текст сервера («Похоже на опечатку в почте: «gmial.com»…») и, если сервер
/// предложил исправленный адрес (`suggestion`), кнопка «Исправить на …».
/// У неживого адреса подсказки нет — только текст.
struct EmailFixHint: View {
    let message: String
    let suggestion: String?
    let onFix: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message)
                .font(YMFont.caption)
                .foregroundStyle(YMColor.statusCancel)
                .fixedSize(horizontal: false, vertical: true)
            if let s = suggestion, !s.isEmpty {
                Button {
                    Haptics.light()
                    onFix(s)
                } label: {
                    Text("Исправить на \(s)")
                        .font(YMFont.subhead)
                        .foregroundStyle(YMColor.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
