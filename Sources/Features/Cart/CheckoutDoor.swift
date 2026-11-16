import SwiftUI

//
//  CheckoutDoor.swift — П-83 пп. 7 и 9 на оформлении (только доставка):
//  «Оставить у двери» (leave_at_door) и «Заказ для другого человека»
//  (recipient_name ≤ 100, recipient_phone → сервер приводит к 7XXXXXXXXXX; плохой — 422).
//

enum DoorLogic {
    static let nameMax = 100
    static let hint = "Курьер оставит заказ у двери и пришлёт фото"

    /// Ввод телефона: цифры и «+», как на экране входа; не длиннее 12 знаков.
    static func filterPhone(_ raw: String) -> String {
        String(raw.filter { ($0.isASCII && $0.isNumber) || $0 == "+" }.prefix(12))
    }

    private static func digits(_ s: String) -> String { s.filter { $0.isASCII && $0.isNumber } }

    /// Пусто — допустимо (получатель не задан); иначе 10 цифр или 11 с 7/8 в начале — как на экране входа.
    static func phoneValid(_ phone: String) -> Bool {
        let d = digits(phone)
        if d.isEmpty { return true }
        return d.count == 10 || (d.count == 11 && (d.hasPrefix("7") || d.hasPrefix("8")))
    }

    /// +7XXXXXXXXXX или nil, если поле пусто / неверно.
    static func phoneWire(_ phone: String) -> String? {
        let d = digits(phone)
        if d.isEmpty || !phoneValid(phone) { return nil }
        if d.count == 11 && d.hasPrefix("8") { return "+7" + String(d.dropFirst()) }
        if d.count == 10 { return "+7" + d }
        return "+" + d
    }

    static func nameWire(_ name: String) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(nameMax))
    }

    /// Строки для сводки «что ушло».
    static func summary(leave: Bool, name: String, phone: String) -> [String] {
        var out: [String] = []
        if leave { out.append("Оставить у двери") }
        let parts = [nameWire(name), phoneWire(phone)].compactMap { $0 }
        if !parts.isEmpty { out.append("Получатель: " + parts.joined(separator: ", ")) }
        return out
    }
}

struct DoorRecipientBlock: View {
    @Binding var leave: Bool
    @Binding var name: String
    @Binding var phone: String
    let phoneInvalid: Bool
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: YMSpace.sm) {
            Toggle(isOn: $leave) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Оставить у двери").font(YMFont.body).foregroundStyle(YMColor.text)
                    Text(DoorLogic.hint).font(YMFont.caption).foregroundStyle(YMColor.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(YMColor.accent)
            Button {
                open.toggle()
            } label: {
                HStack {
                    Text("Заказ для другого человека").font(YMFont.callout).foregroundStyle(YMColor.accent)
                    Spacer(minLength: 0)
                    Text(open ? "Свернуть" : "Указать").font(YMFont.caption).foregroundStyle(YMColor.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open || !name.isEmpty || !phone.isEmpty {
                fields
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(YMSpace.lg)
        .ymCard(radius: YMRadius.card)
    }

    @ViewBuilder private var fields: some View {
        TextField("Имя получателя", text: $name)
            .font(YMFont.body)
            .textContentType(.name)
            .padding(.horizontal, YMSpace.md).padding(.vertical, 10)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: name) { v in
                if v.count > DoorLogic.nameMax { name = String(v.prefix(DoorLogic.nameMax)) }
            }
        TextField("+7 900 000-00-00", text: $phone)
            .font(YMFont.body)
            .keyboardType(.phonePad)
            .padding(.horizontal, YMSpace.md).padding(.vertical, 10)
            .background(YMColor.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .onChange(of: phone) { v in
                let f = DoorLogic.filterPhone(v)
                if f != v { phone = f }
            }
        if phoneInvalid {
            Text("Введите телефон получателя полностью")
                .font(YMFont.caption).foregroundStyle(Color.red)
        }
    }
}
