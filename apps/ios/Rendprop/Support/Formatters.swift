import Foundation

enum Formatters {
    static func duration(_ seconds: Double) -> String {
        guard let total = roundedNonnegativeInteger(seconds) else { return "—" }
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    static func frameRate(_ framesPerSecond: Double) -> String {
        guard let frames = roundedNonnegativeInteger(framesPerSecond) else { return "— fps" }
        return "\(frames) fps"
    }

    // Saved or imported metadata can contain nonfinite or out-of-range values.
    // An exact optional conversion displays unknown data without trapping or
    // silently inventing a duration/frame rate.
    private static func roundedNonnegativeInteger(_ value: Double) -> Int? {
        guard value.isFinite, value >= 0 else { return nil }
        return Int(exactly: value.rounded())
    }

    static func bytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}
