import Foundation

enum CreditText {
    // Legacy provider balances are strings; only format unambiguous numbers.
    // Currency-formatted balances and provider labels retain their units.
    static func formatted(_ raw: String, locale: Locale = .current) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.range(of: "^[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?$", options: .regularExpression) != nil,
              let number = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else { return raw }
        let threshold = Decimal(string: "0.01")!
        if number > 0, number < threshold { return "<" + threshold.formatted(.number.precision(.fractionLength(2)).locale(locale)) }
        if number < 0, number > -threshold { return ">−" + threshold.formatted(.number.precision(.fractionLength(2)).locale(locale)) }
        return number.formatted(.number.precision(.fractionLength(0...2)).locale(locale))
    }
}

extension UsageSnapshot {
    var formattedCreditBalance: String? { creditBalance.map { CreditText.formatted($0) } }
}
