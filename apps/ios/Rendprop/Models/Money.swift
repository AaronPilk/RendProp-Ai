import Foundation

/// Money is ALWAYS integer cents — never floats for currency (master spec guardrail).
struct Money: Codable, Hashable {
    var cents: Int

    static func dollars(_ d: Int) -> Money { Money(cents: d * 100) }

    var formatted: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
        return f.string(from: NSNumber(value: Double(cents) / 100.0)) ?? "$\(cents / 100)"
    }
}
