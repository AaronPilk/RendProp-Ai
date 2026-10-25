import Foundation

/// Shipping availability is separate from stored entitlements and saved media.
/// Aerial prompting is still being tested; no runtime or simulator flag enables
/// new generation. Already accepted requests and saved clips remain readable.
enum LaunchFeatureAvailability {
    // The generic legacy request stays disabled. New front-of-home work uses
    // the separate quoted, scoped and explicitly accepted opening protocol.
    static let canGenerateAerial = false
    static let canCreateOpening = true
    static let openingMessage = "Choose an original front exterior photo in Aerial intro. Review its framing and processing terms, then create one opening clip. Use an accepted opening first in a new Listing or Social video."
    static let aerialMessage = "Aerial intro is Coming soon. Saved clips remain in your listing's files."
}
