import SwiftUI

/// Rendprop design tokens — matches the web player aesthetic
/// (near-black #0B0D10, ink #F2F3F5, gold accent #D9A441, radius 16).
enum Theme {
    static let accent  = Color(red: 217/255, green: 164/255, blue: 65/255)   // #D9A441
    static let bg      = Color(red: 11/255,  green: 13/255,  blue: 16/255)   // #0B0D10
    static let ink     = Color(red: 242/255, green: 243/255, blue: 245/255)  // #F2F3F5
    static let inkDim  = Color.white.opacity(0.62)
    static let good    = Color(red: 84/255,  green: 200/255, blue: 120/255)
    static let warn    = Color(red: 235/255, green: 170/255, blue: 60/255)
    static let bad     = Color(red: 235/255, green: 90/255,  blue: 90/255)

    static let radius: CGFloat = 16
    static let spacing: CGFloat = 16
}

extension Listing.Status {
    var label: String {
        switch self {
        case .draft:      return "Draft"
        case .uploading:  return "Uploading"
        case .processing: return "Processing"
        case .ready:      return "Ready"
        case .expired:    return "Expired"
        }
    }

    var color: Color {
        switch self {
        case .draft:      return Theme.inkDim
        case .uploading:  return Theme.warn
        case .processing: return Theme.accent
        case .ready:      return Theme.good
        case .expired:    return Theme.bad
        }
    }

    var systemImage: String {
        switch self {
        case .draft:      return "square.and.pencil"
        case .uploading:  return "arrow.up.circle"
        case .processing: return "gearshape.2"
        case .ready:      return "play.circle.fill"
        case .expired:    return "clock.badge.exclamationmark"
        }
    }
}
