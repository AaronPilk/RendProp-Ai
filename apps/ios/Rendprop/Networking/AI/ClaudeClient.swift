import Foundation

/// Native Claude (Anthropic Messages API) client — the planner and quality
/// judge of the enhancement loop.
struct ClaudeClient {
    struct AIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func complete(blocks: [[String: Any]], maxTokens: Int = 1500) async throws -> String {
        let body: [String: Any] = [
            "model": Secrets.anthropicModel,
            "max_tokens": maxTokens,
            "messages": [["role": "user", "content": blocks]],
        ]
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Secrets.anthropicKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError(message: "Claude API: \(String(data: data, encoding: .utf8) ?? "unknown error")")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]] else {
            throw AIError(message: "Claude API: unexpected response shape")
        }
        // Join text blocks; thinking blocks have no "text" key and are skipped.
        return content.compactMap { $0["text"] as? String }.joined()
    }

    // MARK: - Content block builders

    static func text(_ t: String) -> [String: Any] {
        ["type": "text", "text": t]
    }

    static func image(jpegData: Data) -> [String: Any] {
        ["type": "image",
         "source": ["type": "base64", "media_type": "image/jpeg",
                    "data": jpegData.base64EncodedString()]]
    }

    static func image(url: String) -> [String: Any] {
        ["type": "image", "source": ["type": "url", "url": url]]
    }

    /// Pull the first {...} JSON object out of a model reply.
    static func extractJSON(_ reply: String) throws -> [String: Any] {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}") else {
            throw AIError(message: "No JSON in Claude reply")
        }
        let slice = String(reply[start...end])
        guard let obj = try JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any] else {
            throw AIError(message: "Claude reply JSON did not parse")
        }
        return obj
    }
}
