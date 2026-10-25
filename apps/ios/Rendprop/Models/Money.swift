import Foundation

/// Money is ALWAYS integer cents — never floats for currency (master spec guardrail).
struct Money: Codable, Hashable {
    var cents: Int

    /// Whole dollars → cents. Clamps instead of trapping on overflow (a pasted
    /// 17+ digit "price" used to crash the card that rendered it).
    static func dollars(_ d: Int) -> Money {
        let (value, overflow) = d.multipliedReportingOverflow(by: 100)
        if overflow { return Money(cents: d < 0 ? Int.min : Int.max) }
        return Money(cents: value)
    }

    /// Parse a user-typed dollar amount ("1,200,000", "$49", "3500.00") into
    /// whole dollars. Strips everything that isn't a digit before the first
    /// decimal point; nil when nothing numeric is left. Values beyond ~14
    /// digits are refused (a real price never is).
    static func parseDollars(_ raw: String) -> Int? {
        let head = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let digits = head.filter { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 14 else { return nil }
        return Int(digits)
    }

    var formatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        // Fixed locale so the app and the hosted page (en-US) print the same
        // string — "US$1,175,000" outside the US read as a different currency.
        f.locale = Locale(identifier: "en_US")
        f.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
        return f.string(from: NSNumber(value: Double(cents) / 100.0)) ?? "$\(cents / 100)"
    }
}
