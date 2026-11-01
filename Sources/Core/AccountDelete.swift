import Foundation

/// Удаление аккаунта и деньги на кошельке (сервер А719, DELETE /api/v1/account).
///
/// Деньги удаление НЕ блокируют (App Store 5.1.1(v)) и не пропадают: остаток сохраняется
/// для возврата по заявке в поддержку, в ответе — wallet_left ("150.00", строка, только
/// если остаток больше нуля). Перед удалением предупреждаем по балансу GET /api/v1/wallet;
/// ошибка чтения баланса удаление не блокирует (предупреждения просто нет).
/// Паритет с Android (core/AccountDelete.kt).
enum AccountDelete {
    /// Предупреждение перед удалением; баланс неизвестен (nil) или не больше нуля → nil.
    static func walletWarning(_ balance: Decimal?) -> String? {
        guard let b = balance, b > 0 else { return nil }
        return "Остаток \(Money.format(b)) можно вернуть по заявке в поддержку — или потратьте его заранее"
    }

    /// Сообщение после удаления по wallet_left ответа; нет остатка → nil.
    static func walletLeftNote(_ left: Decimal?) -> String? {
        guard let l = left, l > 0 else { return nil }
        return "Остаток \(Money.format(l)) можно вернуть по заявке в поддержку"
    }
}

/// Ответ DELETE /api/v1/account: deleted + wallet_left (строка "150.00", только если остаток > 0).
/// Нет ключа (старый сервер) — nil.
struct AccountDeleteResult: Decodable {
    var walletLeft: Decimal?
    init() {}

    // Декодер API — convertFromSnakeCase: wallet_left приходит ключом walletLeft.
    private enum CodingKeys: String, CodingKey { case walletLeft }

    /// Удаление необратимо: аккаунт на сервере уже удалён, поэтому любая форма data
    /// (не объект, мусор в wallet_left) — успех без остатка, а не «Аккаунт не удалён».
    init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self),
              let left = try? c.decode(LenientDecimal.self, forKey: .walletLeft)
        else { walletLeft = nil; return }
        walletLeft = left.wrappedValue
    }
}
