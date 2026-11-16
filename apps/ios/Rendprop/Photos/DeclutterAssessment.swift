import Foundation
import CryptoKit

/// Advice never dispatches an edit. Invalid or inconclusive advice stays unselected.
struct AIPhotoDeclutterAssessment: Codable, Sendable, Equatable {
    enum Decision: String, Codable, Sendable { case needed, unnecessary, uncertain }
    static let protocolVersion = "declutter-assessment-v1"
    static let confidenceThreshold = 0.85
    static let allowedTargets: Set<String> = ["papers", "loose_items", "personal_items", "cords", "laundry", "trash", "dishes", "shoes", "bags", "small_countertop_items"]
    let decision: Decision
    let confidence: Double
    let reason: String
    let targets: [String]

    enum Failure: Error { case invalid }
    init(decision: Decision, confidence: Double, reason: String, targets: [String]) throws {
        guard confidence.isFinite, (0...1).contains(confidence), !reason.isEmpty, reason.count <= 160,
              !reason.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }),
              targets.count <= 6, Set(targets).count == targets.count,
              targets.allSatisfy(Self.allowedTargets.contains) else { throw Failure.invalid }
        self.confidence = confidence; self.reason = reason; self.targets = targets
        switch decision {
        case .needed:
            self.decision = confidence >= Self.confidenceThreshold && !targets.isEmpty ? .needed : .uncertain
        case .unnecessary:
            self.decision = confidence >= Self.confidenceThreshold && targets.isEmpty ? .unnecessary : .uncertain
        case .uncertain: self.decision = .uncertain
        }
    }
    private enum CodingKeys: String, CodingKey { case decision, confidence, reason, targets }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(decision: fields.decode(Decision.self, forKey: .decision),
                      confidence: fields.decode(Double.self, forKey: .confidence),
                      reason: fields.decode(String.self, forKey: .reason),
                      targets: fields.decode([String].self, forKey: .targets))
    }
    static var uncertain: Self {
        // The fixed local fallback is valid and can never automatically approve generation.
        try! Self(decision: .uncertain, confidence: 0, reason: "This photo could not be assessed. Review it yourself before choosing an edit.", targets: [])
    }
    static func decodeOrUncertain(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? .uncertain
    }
}

/// An explicit local choice bound to immutable source/prepared bytes and the
/// captured grant. It does not replace server authorization, quota or photo QC.
struct DeclutterGenerationApproval: Codable, Sendable, Equatable {
    let actor: String
    let library: UUID
    let listing: UUID
    let sourceVersionID: String
    let originalSHA256: String
    let preparedSHA256: String
    let consentRevision: UInt64
    let assessment: AIPhotoDeclutterAssessment
    let manualOverride: Bool
    var decision: AIPhotoDeclutterAssessment.Decision { assessment.decision }

    init(actor: String, library: UUID, listing: UUID, sourceVersionID: String,
         originalSHA256: String, preparedSHA256: String, consentRevision: UInt64,
         assessment: AIPhotoDeclutterAssessment, manualOverride: Bool) {
        self.actor = actor; self.library = library; self.listing = listing; self.sourceVersionID = sourceVersionID
        self.originalSHA256 = originalSHA256; self.preparedSHA256 = preparedSHA256
        self.consentRevision = consentRevision; self.assessment = assessment; self.manualOverride = manualOverride
    }
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func validSHA(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    func permits(actor: String, library: UUID, listing: UUID, sourceVersionID: String,
                 originalSHA256: String, preparedSHA256: String,
                 consentGranted: Bool, consentRevision: UInt64) -> Bool {
        guard consentGranted, consentRevision == self.consentRevision,
              UUID(uuidString: actor) != nil, actor == self.actor,
              library == self.library, listing == self.listing,
              !sourceVersionID.isEmpty, sourceVersionID == self.sourceVersionID,
              Self.validSHA(originalSHA256), Self.validSHA(preparedSHA256),
              originalSHA256 == self.originalSHA256, preparedSHA256 == self.preparedSHA256 else { return false }
        return assessment.decision == .needed || manualOverride
    }
}
