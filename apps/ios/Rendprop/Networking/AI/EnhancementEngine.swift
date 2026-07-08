import AVFoundation
import UIKit

/// The "perfect every time" loop, running natively in the app:
///
///   keyframe → PLAN (Claude) → EDIT (Higgsfield) → JUDGE (Claude)
///                    ▲                                  │
///                    └── retry with the judge's feedback (max 2)
///                                                       │
///                            fail after retries → keep ORIGINAL footage
///
/// Hard rules: architecture never changes; a failed edit never ships;
/// every active enhancement carries the "Virtually staged" disclosure.
@MainActor
final class EnhancementEngine: ObservableObject {

    enum Phase: Equatable {
        case idle
        case extracting
        case planning
        case editing(attempt: Int)
        case judging(attempt: Int)
        case done
        case failed(String)

        var label: String {
            switch self {
            case .idle:                return "Ready"
            case .extracting:          return "Grabbing a frame from your video…"
            case .planning:            return "Claude is studying the room…"
            case .editing(let a):      return a == 1 ? "Creating the new look…" : "Improving it (try \(a))…"
            case .judging(let a):      return a == 1 ? "Double-checking quality…" : "Re-checking quality…"
            case .done:                return "Done"
            case .failed(let msg):     return msg
            }
        }
    }

    struct Result {
        let before: UIImage
        let afterURL: URL
        let structure: Int
        let completeness: Int
        let artifacts: Int
        let attempts: Int
        let roomType: String
    }

    @Published var phase: Phase = .idle
    @Published var result: Result?

    private let claude = ClaudeClient()
    private let higgsfield = HiggsfieldClient()
    private let maxRetries = 2
    private let passScore = 80

    private static let styleRecipes: [DesignStyle: String] = [
        .modern: "clean-lined contemporary furniture, low-profile charcoal sectional, walnut and matte-black accents, minimal abstract wall art, modern area rug",
        .rustic: "warm farmhouse furniture, natural woods, cozy layered textiles, vintage-style decor, warm earth tones",
        .minimalist: "very few carefully chosen pieces, neutral palette, clean surfaces, airy negative space, simple line art",
        .scandinavian: "light oak furniture, soft whites and greys, hygge textures, simple functional pieces, green plants",
    ]

    // MARK: - Public entry

    func run(videoURL: URL, atSecond t: Double, declutter: Bool, style: DesignStyle) async {
        do {
            phase = .extracting
            let frame = try await Self.keyframe(from: videoURL, at: t)
            guard let jpeg = frame.jpegData(compressionQuality: 0.82) else {
                throw ClaudeClient.AIError(message: "Could not read a frame from the video.")
            }

            phase = .planning
            let plan = try await makePlan(jpeg: jpeg, declutter: declutter, style: style)

            let inputURL = "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
            var prompt = basePrompt(from: plan)
            var attempts = 0

            while attempts <= maxRetries {
                attempts += 1
                phase = .editing(attempt: attempts)
                let candidateURL = try await higgsfield.editImage(imageURL: inputURL, prompt: prompt)

                phase = .judging(attempt: attempts)
                let verdict = try await judge(beforeJPEG: jpeg, afterURL: candidateURL, plan: plan)
                let minScore = min(verdict.structure, verdict.completeness, verdict.artifacts)

                if verdict.pass && minScore >= passScore {
                    result = Result(before: frame,
                                    afterURL: URL(string: candidateURL)!,
                                    structure: verdict.structure,
                                    completeness: verdict.completeness,
                                    artifacts: verdict.artifacts,
                                    attempts: attempts,
                                    roomType: plan["room_type"] as? String ?? "Room")
                    phase = .done
                    return
                }
                prompt = basePrompt(from: plan) + " Fix from the last attempt: \(verdict.feedback)"
            }
            phase = .failed("Quality check didn't pass — your original video stays untouched. (That's the safety net working.)")
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Plan (Claude vision)

    private func makePlan(jpeg: Data, declutter: Bool, style: DesignStyle) async throws -> [String: Any] {
        let styleLine = style == .asIs
            ? "No restaging — keep all furniture as-is."
            : "Plan a virtual restage in \(style.displayName.uppercased()) style: \(Self.styleRecipes[style] ?? "")."
        let clutterLine = declutter
            ? "List every removable clutter item (boxes, mess, cords, laundry, papers, dishes)."
            : "Do not remove anything."

        let reply = try await claude.complete(blocks: [
            ClaudeClient.image(jpegData: jpeg),
            ClaudeClient.text("""
            You are Rendprop's real-estate video enhancement planner.
            Analyze this room frame. \(clutterLine) \(styleLine)

            Rules: architecture is untouchable (walls, windows, doors, floors, ceilings, \
            fixtures, views). Never hide property defects. Furniture and decor only.

            Reply with ONLY JSON:
            {"room_type": "...", "clutter_items": ["..."], "keep_identical": ["..."],
             "edit_prompt": "one complete instruction for an image-edit model"}
            """),
        ])
        return try ClaudeClient.extractJSON(reply)
    }

    private func basePrompt(from plan: [String: Any]) -> String {
        let keep = (plan["keep_identical"] as? [String] ?? []).joined(separator: ", ")
        let edit = plan["edit_prompt"] as? String ?? ""
        return edit + " CRITICAL: keep architecture pixel-identical — same walls, windows, "
             + "doors, floors, ceiling, camera angle, lighting. Keep identical: \(keep)."
    }

    // MARK: - Judge (Claude compares before/after)

    private struct Verdict {
        let structure: Int, completeness: Int, artifacts: Int
        let pass: Bool
        let feedback: String
    }

    private func judge(beforeJPEG: Data, afterURL: String, plan: [String: Any]) async throws -> Verdict {
        let planJSON = (try? JSONSerialization.data(withJSONObject: plan)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let reply = try await claude.complete(blocks: [
            ClaudeClient.text("BEFORE:"),
            ClaudeClient.image(jpegData: beforeJPEG),
            ClaudeClient.text("AFTER:"),
            ClaudeClient.image(url: afterURL),
            ClaudeClient.text("""
            You are Rendprop's quality judge for real-estate media. The edit plan was: \(planJSON)

            Score the AFTER image:
            1. structure (0-100): walls, windows, doors, floors, ceiling, layout, view \
            IDENTICAL to BEFORE? Any moved/added/removed architecture = below 50.
            2. completeness (0-100): planned edit fully done?
            3. artifacts (0-100): free of warping, smears, impossible geometry?

            Reply ONLY JSON:
            {"structure": 0, "completeness": 0, "artifacts": 0,
             "verdict": "pass|retry|fail", "feedback": "specific fix for next attempt"}
            """),
        ])
        let json = try ClaudeClient.extractJSON(reply)
        return Verdict(structure: json["structure"] as? Int ?? 0,
                       completeness: json["completeness"] as? Int ?? 0,
                       artifacts: json["artifacts"] as? Int ?? 0,
                       pass: (json["verdict"] as? String) == "pass",
                       feedback: json["feedback"] as? String ?? "improve fidelity")
    }

    // MARK: - Keyframe extraction

    static func keyframe(from videoURL: URL, at seconds: Double) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let asset = AVURLAsset(url: videoURL)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 1600, height: 1600)
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
                do {
                    let cg = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 600),
                                                       actualTime: nil)
                    continuation.resume(returning: UIImage(cgImage: cg))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
