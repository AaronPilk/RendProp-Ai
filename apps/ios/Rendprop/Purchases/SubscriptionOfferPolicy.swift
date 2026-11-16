import Foundation

/// Presentation only. Apple confirms the subscription and the server verifies
/// its signed transaction before granting any trial or paid allowance.
enum SubscriptionOfferPolicy {
    enum PeriodUnit { case day, week, month, year, unknown }
    static func isSevenDayFreeTrial(eligible: Bool, free: Bool, value: Int,
                                   unit: PeriodUnit, count: Int) -> Bool {
        guard eligible, free, count == 1 else { return false }
        switch unit {
        case .day: return value == 7
        case .week: return value == 1
        default: return false
        }
    }

    static func disclosure(sevenDayTrial: Bool, price: String, period: String) -> String {
        if sevenDayTrial {
            return "Confirm your subscription with Apple to start 7 days free. Then \(price)\(period), automatically renewed until cancelled. Cancel at least 24 hours before the trial ends to avoid the first charge."
        }
        return "\(price)\(period), automatically renewed until cancelled. Apple shows any available offer and confirms the charge before you subscribe."
    }
}
