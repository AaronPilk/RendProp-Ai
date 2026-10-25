import SwiftUI

/// SF Pro via system fonts; everything scales with Dynamic Type.
extension Font {
    static let rpLargeTitle = Font.largeTitle.weight(.bold)
    static let rpTitle      = Font.title2.weight(.semibold)
    static let rpHeadline   = Font.headline
    static let rpBody       = Font.body
    static let rpCaption    = Font.caption
    static let rpKicker     = Font.caption.weight(.semibold)
    static let rpMono       = Font.system(.footnote, design: .monospaced)
}
