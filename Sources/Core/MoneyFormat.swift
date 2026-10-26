import Foundation

/*
  Деньги: толерантный разбор строк API и формат для показа.

  Переехало из DesignSystem.swift без изменений поведения — здесь только
  Foundation, поэтому этот файл собирается и проверяется тестами там, где
  SwiftUI нет. Все суммы — ТОЛЬКО Decimal, никаких Double/Float для денег.
 */

enum Money {
    /// Парсит суммы из API, которые приходят строками ("0.00", "1 310,00", "590 ₽", 590).
    /// Возвращает Decimal. Никогда не использует Double.
    static func parse(_ raw: Any?) -> Decimal {
        switch raw {
        case let d as Decimal: return d
        case let i as Int:     return Decimal(i)
        case let d as Double:  return Decimal(string: String(format: "%.2f", d)) ?? 0
        case let s as String:
            var cleaned = s
                .replacingOccurrences(of: "\u{00A0}", with: "") // NBSP
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "₽", with: "")
                .replacingOccurrences(of: ",", with: ".")       // 1310,00 → 1310.00
                .trimmingCharacters(in: .whitespaces)
            // если несколько точек (тысячные разделители) — оставляем последнюю как дробную
            let parts = cleaned.components(separatedBy: ".")
            if parts.count > 2 {
                cleaned = parts.dropLast().joined() + "." + parts.last!
            }
            return Decimal(string: cleaned) ?? 0
        default:
            return 0
        }
    }

    /// Псевдоним `parse` — экраны (Org/Product/Listing) вызывают `Money.dec(...)`.
    /// Ничего в денежной логике не меняет: это тот же толерантный парсинг в Decimal.
    static func dec(_ raw: Any?) -> Decimal { parse(raw) }

    /// Форматирование в рубли: 1310 → "1 310 ₽", 1310.50 → "1 310,50 ₽".
    ///
    /// Разделители заданы ЯВНО и не зависят от локали устройства: раньше
    /// groupingSeparator был прибит к неразрывному пробелу, а decimalSeparator
    /// брался у системы — на телефоне с английской локалью копейки печатались
    /// через точку («1 310.5 ₽») посреди русского интерфейса. И дробную часть
    /// теперь показываем целиком: «1 310,5 ₽» для денег выглядит обрезанным.
    /// Целые суммы, как и прежде, идут без копеек — так на всех экранах.
    static func format(_ value: Decimal) -> String {
        // Сначала до копеек «от нуля» (как PHP round на сервере и итог корзины):
        // NumberFormatter округлял 72,465 и 0,125 «к чётному» через Double, и цена
        // на карточке товара расходилась с корзиной и заказом на копейку.
        let v = value.rounded(2)
        let whole = v == v.rounded(0)
        let f = whole ? rubWhole : rubFrac
        let n = f.string(from: v as NSDecimalNumber) ?? "\(v)"
        return "\(n)\u{00A0}₽"
    }

    // Форматтеры создаются один раз: format вызывается в каждой строке списков
    // при каждой перерисовке, а NumberFormatter создавать дорого.
    private static func rub(fraction: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "ru_RU")
        f.groupingSeparator = "\u{00A0}"
        f.decimalSeparator = ","
        f.minimumFractionDigits = fraction
        f.maximumFractionDigits = fraction
        return f
    }
    private static let rubWhole = rub(fraction: 0)
    private static let rubFrac = rub(fraction: 2)
    private static let wireFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.groupingSeparator = ""
        f.usesGroupingSeparator = false
        f.decimalSeparator = "."
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f
    }()

    /// Деньги НА ПРОВОД: всегда "0.00" — точка разделителем, два знака, без
    /// пробелов и ₽ (канон SKILL.md, так же как number_format на сервере).
    /// `format` для этого не годится: он печатает «1 000,50 ₽» под русскую
    /// локаль, и сервер разобрал бы такую строку как 1.
    static func wire(_ value: Decimal) -> String {
        // Копейки — тем же округлением «от нуля», что и format (см. выше).
        wireFmt.string(from: value.rounded(2) as NSDecimalNumber) ?? "0.00"
    }
}

private extension Decimal {
    func rounded(_ scale: Int) -> Decimal {
        var result = Decimal()
        var v = self
        NSDecimalRound(&result, &v, scale, .plain)
        return result
    }
}

