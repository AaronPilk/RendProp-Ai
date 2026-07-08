import Foundation

/// Dev-mode API keys, loaded from Resources/Secrets.plist (gitignored).
/// ⚠️ SHIP GATE: before App Store release these calls move behind the Rendprop
/// backend — keys embedded in a shipped binary can be extracted and drained.
/// For development/TestFlight this keeps everything in the app with no server.
enum Secrets {
    private static let dict: [String: String] = {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { return [:] }
        return plist
    }()

    static var anthropicKey: String { dict["ANTHROPIC_API_KEY"] ?? "" }
    static var anthropicModel: String { dict["ANTHROPIC_MODEL"] ?? "claude-fable-5" }
    static var higgsfieldKey: String { dict["HIGGSFIELD_API_KEY"] ?? "" }
    static var higgsfieldSecret: String { dict["HIGGSFIELD_API_SECRET"] ?? "" }
    static var imageEditModel: String { dict["HF_IMAGE_EDIT_MODEL"] ?? "bytedance/seedream/v4/edit" }
    static var i2vModel: String { dict["HF_I2V_MODEL"] ?? "bytedance/seedance/v1/pro/image-to-video" }

    /// AI features light up only when keys are present.
    static var aiEnabled: Bool { !anthropicKey.isEmpty && !higgsfieldKey.isEmpty }
}
