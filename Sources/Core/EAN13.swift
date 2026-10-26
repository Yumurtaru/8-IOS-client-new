import Foundation

/*
 EAN-13 — карта клиента.

 В профиле показывается личный штрихкод: кассир в магазине спрашивает «есть
 наше приложение?», человек показывает код, кассовый сканер его считывает — и
 покупка привязывается к аккаунту (баллы, кешбэк, счётчики акций). Это надёжнее
 ввода телефона руками: чужой номер можно набрать по памяти, а код показывает
 сам владелец аккаунта.

 EAN-13 читает ЛЮБОЙ кассовый сканер без настройки. Кодировку считаем сами:
 в CoreImage генератора EAN-13 нет (только Code128/QR/Aztec/PDF417), а тянуть
 зависимость ради 95 палочек незачем. Здесь только Foundation — рисование
 живёт в Components/ClientCardBlock.swift.
*/

enum EAN13 {
    /// Левые кодировки (нечётная чётность).
    private static let l = ["0001101", "0011001", "0010011", "0111101", "0100011",
                            "0110001", "0101111", "0111011", "0110111", "0001011"]
    /// Левые кодировки (чётная чётность).
    private static let g = ["0100111", "0110011", "0011011", "0100001", "0011101",
                            "0111001", "0000101", "0010001", "0001001", "0010111"]
    /// Правые кодировки.
    private static let r = ["1110010", "1100110", "1101100", "1000010", "1011100",
                            "1001110", "1010000", "1000100", "1001000", "1110100"]
    /// Первая цифра задаётся чередованием L/G в левой половине.
    private static let parity = ["LLLLLL", "LLGLGG", "LLGGLG", "LLGGGL", "LGLLGG",
                                 "LGGLLG", "LGGGLL", "LGLGLG", "LGLGGL", "LGGLGL"]

    /// Тихие зоны по стандарту: 11 модулей слева, 7 справа. Без них сканер
    /// часто не берёт код: ему не за что «зацепиться» перед стартовой парой.
    static let quietLeft = 11
    static let quietRight = 7
    /// Полная ширина картинки в модулях: 11 + 95 + 7.
    static let totalModules = quietLeft + 95 + quietRight

    /// Контрольная цифра по первым 12 цифрам (та же формула, что на сервере).
    static func checkDigit(_ digits12: [Int]) -> Int {
        var sum = 0
        for (i, d) in digits12.enumerated() { sum += i % 2 == 0 ? d : d * 3 }
        return (10 - sum % 10) % 10
    }

    /// Строго 13 обычных цифр 0–9. Никаких «похожих на цифры» символов:
    /// Character.wholeNumberValue считает и римские, и иероглифические числа,
    /// а такое значение уронило бы обращение по индексу в таблицах.
    static func digits(_ code: String) -> [Int]? {
        guard code.count == 13 else { return nil }
        var ds: [Int] = []
        ds.reserveCapacity(13)
        for ch in code {
            guard ch.isASCII, let d = ch.wholeNumberValue, (0...9).contains(d) else { return nil }
            ds.append(d)
        }
        guard checkDigit(Array(ds[0..<12])) == ds[12] else { return nil }
        return ds
    }

    static func isValid(_ code: String?) -> Bool {
        guard let code else { return false }
        return digits(code) != nil
    }

    /// Модули картинки: тихая зона + 3 (старт) + 42 + 5 (центр) + 42 + 3 (стоп)
    /// + тихая зона. true — чёрный.
    static func modules(_ code: String) -> [Bool]? {
        guard let d = digits(code) else { return nil }
        var bits = String(repeating: "0", count: quietLeft)
        bits += "101"
        let p = Array(parity[d[0]])
        for i in 1...6 { bits += (p[i - 1] == "L" ? l[d[i]] : g[d[i]]) }
        bits += "01010"
        for i in 7...12 { bits += r[d[i]] }
        bits += "101"
        bits += String(repeating: "0", count: quietRight)
        return bits.map { $0 == "1" }
    }

    /// Код группами, как печатают на упаковке: 2 96836 557734 7
    static func pretty(_ code: String) -> String {
        guard digits(code) != nil else { return code }
        let a = Array(code)
        return "\(a[0]) \(String(a[1...6])) \(String(a[7...12]))"
    }
}
