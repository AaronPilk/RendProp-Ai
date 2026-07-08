import SwiftUI

/// Rendprop design tokens — light, clean, white + purple.
/// Simple and friendly: big buttons, plain language, nothing techy.
enum Theme {
    static let accent  = Color(red: 124/255, green: 58/255,  blue: 237/255)  // #7C3AED purple
    static let bg      = Color(red: 250/255, green: 250/255, blue: 252/255)  // near-white
    static let card    = Color.white
    static let ink     = Color(red: 28/255,  green: 25/255,  blue: 45/255)   // near-black
    static let inkDim  = Color(red: 28/255,  green: 25/255,  blue: 45/255).opacity(0.55)
    static let border  = Color.black.opacity(0.08)
    static let fillSubtle = Color.black.opacity(0.04)
    static let accentSoft = Color(red: 124/255, green: 58/255, blue: 237/255).opacity(0.10)

    static let good = Color(red: 22/255,  green: 163/255, blue: 74/255)
    static let warn = Color(red: 202/255, green: 138/255, blue: 4/255)
    static let bad  = Color(red: 220/255, green: 38/255,  blue: 38/255)

    static let radius: CGFloat = 16
    static let spacing: CGFloat = 16
}

extension Listing.Status {
    var label: String {
        switch self {
        case .draft:      return "Not finished"
        case .uploading:  return "Uploading"
        case .processing: return "Working on it"
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
