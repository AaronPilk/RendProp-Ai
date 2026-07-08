import Foundation

/// Native KIE.ai client — one API for every generative model we use.
/// Verified live against the real API:
///   Upload : POST https://kieai.redpandaai.co/api/file-base64-upload   (free)
///   Create : POST https://api.kie.ai/api/v1/jobs/createTask
///   Status : GET  https://api.kie.ai/api/v1/jobs/recordInfo?taskId=…
/// States: waiting → queuing → generating → success | fail.
/// Failed tasks are NOT charged — pairs perfectly with the QC retry loop.
struct KieClient {
    struct AIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let apiBase = "https://api.kie.ai"
    private let uploadBase = "https://kieai.redpandaai.co"

    private func request(_ urlString: String, payload: [String: Any]? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: urlString)!)
        req.httpMethod = payload == nil ? "GET" : "POST"
        req.timeoutInterval = 90
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(Secrets.kieKey)", forHTTPHeaderField: "Authorization")
        if let payload {
            req.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        }
        return req
    }

    private func json(_ req: URLRequest) async throws -> [String: Any] {
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(message: "KIE: unexpected response")
        }
        let code = obj["code"] as? Int ?? (obj["success"] as? Bool == true ? 200 : -1)
        guard code == 200 else {
            let msg = obj["msg"] as? String ?? "unknown error"
            if msg.lowercased().contains("credit") {
                throw AIError(message: "Your KIE.ai account is out of credits — top up at kie.ai/billing.")
            }
            throw AIError(message: "KIE: \(msg)")
        }
        return obj["data"] as? [String: Any] ?? [:]
    }

    // MARK: - Frame hosting (free, expires in 3 days — plenty for a render job)

    /// Upload a JPEG frame; returns a URL the generation models can fetch.
    func uploadFrame(jpegData: Data, name: String = "frame-\(Int(Date().timeIntervalSince1970)).jpg") async throws -> String {
        let data = try await json(request("\(uploadBase)/api/file-base64-upload", payload: [
            "base64Data": "data:image/jpeg;base64,\(jpegData.base64EncodedString())",
            "uploadPath": "rendprop",
            "fileName": name,
        ]))
        guard let url = (data["downloadUrl"] ?? data["fileUrl"]) as? String else {
            throw AIError(message: "KIE upload: no file URL returned")
        }
        return url
    }

    // MARK: - Async task pattern

    /// Create a generation task and poll until it finishes. Returns result URLs.
    func run(model: String, input: [String: Any], timeout: TimeInterval = 420) async throws -> [String] {
        let created = try await json(request("\(apiBase)/api/v1/jobs/createTask",
                                             payload: ["model": model, "input": input]))
        guard let taskID = created["taskId"] as? String else {
            throw AIError(message: "KIE: no taskId returned")
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let status = try await json(request("\(apiBase)/api/v1/jobs/recordInfo?taskId=\(taskID)"))
            switch status["state"] as? String {
            case "success":
                guard let resultJSON = status["resultJson"] as? String,
                      let parsed = try? JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any],
                      let urls = parsed["resultUrls"] as? [String], !urls.isEmpty else {
                    throw AIError(message: "KIE: task succeeded but no result URLs")
                }
                return urls
            case "fail":
                let why = status["failMsg"] as? String ?? "generation failed"
                throw AIError(message: "KIE: \(why) (failed tasks are not charged — retrying is free)")
            default:
                continue // waiting / queuing / generating
            }
        }
        throw AIError(message: "KIE: generation timed out")
    }

    // MARK: - Convenience wrappers

    /// Edit an image (declutter / restage) — Nano Banana 2 by default.
    func editImage(imageURL: String, prompt: String) async throws -> String {
        let urls = try await run(model: Secrets.kieImageEditModel, input: [
            "prompt": prompt,
            "image_input": [imageURL],
            "aspect_ratio": "16:9",
            "resolution": "2K",
            "output_format": "png",
        ])
        return urls[0]
    }

    /// Animate an approved frame — Seedance 2.0 (bytedance/seedance-2).
    func imageToVideo(imageURL: String, motionPrompt: String, seconds: Int = 5) async throws -> String {
        let urls = try await run(model: Secrets.kieI2VModel, input: [
            "prompt": motionPrompt,
            "image_input": [imageURL],
            "duration": seconds,
            "resolution": "1080p",
            "aspect_ratio": "16:9",
        ], timeout: 600)
        return urls[0]
    }
}
