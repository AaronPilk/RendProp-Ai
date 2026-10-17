import Foundation

/// Shipping availability is separate from stored entitlements and saved media.
/// Aerial prompting is still being tested; no runtime or simulator flag enables
/// new generation. Already accepted requests and saved clips remain readable.
enum LaunchFeatureAvailability {
    static let canGenerateAerial = false
    static let aerialMessage = "Aerial intro is Coming soon. Saved clips remain in your listing's files."
}
