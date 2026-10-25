import UIKit

/// Lightweight haptics wrappers. Selection on room-tag, success on capture
/// finish + upload complete, warning on quality issues, tick as pace metronome.
enum Haptics {
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }

    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func tick() {
        let g = UIImpactFeedbackGenerator(style: .light)
        g.impactOccurred(intensity: 0.55)
    }

    static func heavy() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
}
