import Foundation

/// Native Higgsfield platform client — async queue pattern:
/// POST /{model_id} → poll /requests/{id}/status until completed.
/// One platform, every model (Seedream edit, Seedance i2v, nano banana, Kling…).
struct HiggsfieldClient {
    struct AIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let base = "https://platform.higgsfield.ai"
    private var auth: String { "Key \(Secrets.higgsfieldKey):\(Secrets.higgsfieldSecret)" }

    private func request(_ url: URL, payload: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = payload == nil ? "GET" : "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(auth, forHTTPHeaderField: "Authorization")
        if let payload {
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        return req
    }

    private func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("not_enough_credits") {
                throw AIError(message: "Your Higgsfield account has no API credits. Add them at cloud.higgsfield.ai.")
            }
            if code == 404 {
                throw AIError(message: "Model not found — check the model ID in Secrets.plist against cloud.higgsfield.ai's Models Gallery.")
            }
            throw AIError(message: "Higgsfield API \(code): \(body.prefix(200))")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Submit a generation and poll until it finishes.
    func submitAndWait(model: String, payload: [String: Any],
                       timeout: TimeInterval = 420) async throws -> [String: Any] {
        let submitted = try await json(request(URL(string: "\(base)/\(model)")!, payload: payload))
        guard let statusURL = submitted["status_url"] as? String, let url = URL(string: statusURL) else {
            throw AIError(message: "Higgsfield: no status_url in response")
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let status = try await json(request(url))
            switch status["status"] as? String {
            case "completed":
                return status
            case "failed":
                throw AIError(message: "Higgsfield generation failed (credits were refunded). Try again.")
            case "nsfw":
                throw AIError(message: "Content was flagged by moderation (credits refunded).")
            default:
                continue // queued / in_progress
            }
        }
        throw AIError(message: "Higgsfield generation timed out.")
    }

    /// Edit an image (declutter / restage). Returns the result image URL.
    func editImage(imageURL: String, prompt: String) async throws -> String {
        let result = try await submitAndWait(model: Secrets.imageEditModel, payload: [
            "image_url": imageURL,
            "prompt": prompt,
        ])
        guard let images = result["images"] as? [[String: Any]],
              let url = images.first?["url"] as? String else {
            throw AIError(message: "Higgsfield: no image in result")
        }
        return url
    }

    /// Animate an approved frame (Seedance image-to-video). Returns video URL.
    func imageToVideo(imageURL: String, motionPrompt: String, seconds: Int = 5) async throws -> String {
        let result = try await submitAndWait(model: Secrets.i2vModel, payload: [
            "image_url": imageURL,
            "prompt": motionPrompt,
            "duration": seconds,
        ])
        guard let video = result["video"] as? [String: Any],
              let url = video["url"] as? String else {
            throw AIError(message: "Higgsfield: no video in result")
        }
        return url
    }
}
