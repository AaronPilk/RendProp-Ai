import SwiftUI
import UIKit

/// Rendprop design tokens — clean white + purple in light mode, deep
/// indigo-black + luminous purple in dark mode. Every token is ADAPTIVE
/// (resolves per trait collection), so screens that use Theme.* re-theme for
/// free. The Settings "Appearance" picker (System / Light / Dark) drives the
/// scheme via @AppStorage("appearance") in RendpropApp.
enum Theme {

    // MARK: Adaptive helper

    /// A Color that resolves differently in light vs dark trait environments.
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    // MARK: Core palette (adaptive)

    /// Brand purple — a touch brighter in dark so it glows instead of muddying.
    static let accent = dynamic(light: rgb(124, 58, 237),   // #7C3AED
                                dark:  rgb(155, 109, 255))  // #9B6DFF

    /// App background — near-white ↔ deep indigo-black.
    static let bg = dynamic(light: rgb(250, 250, 252),
                            dark:  rgb(14, 13, 20))         // #0E0D14

    /// Card / elevated surface.
    static let card = dynamic(light: .white,
                              dark:  rgb(26, 24, 37))       // #1A1825

    /// Primary text — near-black ↔ near-white.
    static let ink = dynamic(light: rgb(28, 25, 45),
                             dark:  rgb(242, 240, 250))

    /// Secondary text.
    static let inkDim = dynamic(light: rgb(28, 25, 45, 0.55),
                                dark:  rgb(242, 240, 250, 0.60))

    /// Hairline borders.
    static let border = dynamic(light: UIColor.black.withAlphaComponent(0.08),
                                dark:  UIColor.white.withAlphaComponent(0.12))

    /// Subtle fills (chips, tool tiles, list rows).
    static let fillSubtle = dynamic(light: UIColor.black.withAlphaComponent(0.04),
                                    dark:  UIColor.white.withAlphaComponent(0.07))

    /// Soft purple wash (badges, selected states, secondary buttons).
    static let accentSoft = dynamic(light: rgb(124, 58, 237, 0.10),
                                    dark:  rgb(155, 109, 255, 0.20))

    // MARK: Status colors (brightened in dark for contrast)

    static let good = dynamic(light: rgb(22, 163, 74),  dark: rgb(74, 222, 128))
    static let warn = dynamic(light: rgb(202, 138, 4),  dark: rgb(251, 191, 36))
    static let bad  = dynamic(light: rgb(220, 38, 38),  dark: rgb(248, 113, 113))

    // MARK: Metrics

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
