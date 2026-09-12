import Foundation

// These are explicit fixture credentials, never values loaded from the app,
// Keychain or environment. All actual request/decoder code comes from --root.
enum Config { static let supabaseAnonKey = "fixture-publishable-key-not-a-secret" }
enum AuthStore { static let currentAccessToken: String? = "fixture-token-not-a-jwt" }

final class RestartWireTransport {
    var requests: [URLRequest] = []
    var response: Data
    var loseNextReply = false
    init(_ text: String) { response = Data(text.utf8) }
    func execute(_ request: URLRequest) async throws -> Data {
        requests.append(request)
        if loseNextReply { loseNextReply = false; throw URLError(.timedOut) }
        return response
    }
}

struct WireFailure: Error, CustomStringConvertible { let description: String }

@main
enum UploadRestartWireTests {
    static var checks = 0
    static let parent = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    static let child = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    static let operation = UUID(uuidString: "ABCDEF01-2345-4678-8ABC-DEF012345678")!
    static let base = URL(string: "https://restart-wire.invalid/functions/v1")!

    static func check(_ value: Bool, _ message: String) throws {
        checks += 1
        if !value { throw WireFailure(description: message) }
    }
    static func json(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
    static func ticket(_ fields: [String: Any]) -> (LiveAPIClient, RestartWireTransport) {
        let transport = RestartWireTransport("{}")
        transport.response = try! json(fields) // All fields are constant synthetic JSON.
        return (LiveAPIClient(base: base, fixture: transport), transport)
    }
    static func requestChecks(_ request: URLRequest) throws {
        try check(request.httpMethod == "POST", "Restart method is POST")
        try check(request.url?.absoluteString == "https://restart-wire.invalid/functions/v1/uploads/\(parent)/restart", "Restart URL preserves the actual asset path")
        try check(request.value(forHTTPHeaderField: "Idempotency-Key") == operation.uuidString.lowercased(), "Restart header uses the saved operation UUID")
        try check(request.value(forHTTPHeaderField: "Content-Type") == "application/json", "Restart Content-Type is JSON")
        try check(request.value(forHTTPHeaderField: "Accept") == "application/json", "Restart Accept is JSON")
        try check(request.value(forHTTPHeaderField: "apikey") == Config.supabaseAnonKey, "Actual builder carries the fixture publishable key")
        try check(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token-not-a-jwt", "Actual builder carries the fixture bearer")
        try check(request.httpBody == Data(#"{"confirm_new_attempt":true}"#.utf8), "Restart body is exactly explicit confirmation")
    }

    static func run() async throws {
        let put = "https://upload.invalid/v2/cccccccc-cccc-4ccc-8ccc-cccccccccccc?expires=1800000000&signature=" + String(repeating: "a", count: 64)
        let (client, transport) = ticket([
            "asset_id": child, "mode": "single", "put_url": put,
            "storage_key": "uploads/fixture-org/fixture-listing/\(child).jpg",
            "transport_version": 2, "uploaded": false, "replayed": true,
            "restart_required": false, "restart_reason": NSNull(), "restart_generation": 1,
            "retry_after_seconds": NSNull()
        ])
        let fresh = try await client.restartUpload(assetID: parent, operationID: operation)
        try check(transport.requests.count == 1, "One adapter call dispatches one injected execute")
        try requestChecks(transport.requests[0])
        try check(fresh.assetID == child, "Snake-case asset_id maps to the replacement")
        try check(fresh.mode == .single && fresh.putURL?.absoluteString == put, "Single upload capability is decoded unchanged")
        try check(fresh.storageKey == "uploads/fixture-org/fixture-listing/\(child).jpg", "Snake-case storage_key is decoded")
        try check(fresh.transportVersion == 2 && fresh.uploaded == false && fresh.replayed == true, "Transport and replay metadata are decoded")
        try check(fresh.restartRequired == false && fresh.restartReason == nil, "Fresh child is not declared failed")
        try check(fresh.restartGeneration == 1, "Snake-case restart_generation survives the actual mapper")
        try check(fresh.retryAfterSeconds == nil, "Null retry metadata stays optional")

        transport.loseNextReply = true
        do {
            _ = try await client.restartUpload(assetID: parent, operationID: operation)
            throw WireFailure(description: "Lost response must propagate, not become a fake receipt")
        } catch let error as URLError {
            try check(error.code == .timedOut, "Injected lost response remains a timeout")
        }
        _ = try await client.restartUpload(assetID: parent, operationID: operation)
        try check(transport.requests.count == 3, "Lost response plus explicit replay issues exactly two more calls")
        try check(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Idempotency-Key") == operation.uuidString.lowercased() }, "Lost-response replay preserves the saved UUID header")
        try check(transport.requests.allSatisfy { $0.httpBody == transport.requests[0].httpBody && $0.url == transport.requests[0].url }, "Lost-response replay preserves exact route and body bytes")
        let next = UUID(uuidString: "DDDDDDDD-DDDD-4DDD-8DDD-DDDDDDDDDDDD")!
        _ = try await client.restartUpload(assetID: parent, operationID: next)
        try check(transport.requests.last?.value(forHTTPHeaderField: "Idempotency-Key") == next.uuidString.lowercased(), "Different explicit operation uses its own stable UUID")

        let (waitingClient, waitingTransport) = ticket([
            "asset_id": child, "mode": "single", "transport_version": 2, "uploaded": false,
            "restart_required": false, "restart_generation": 1, "retry_after_seconds": 15
        ])
        let waiting = try await waitingClient.restartUpload(assetID: parent, operationID: operation)
        try check(waitingTransport.requests.count == 1, "Waiting receipt still uses one execute")
        try check(waiting.retryAfterSeconds == 15, "Snake-case retry_after_seconds survives the actual mapper")
        try check(waiting.putURL == nil && waiting.uploaded == false, "Waiting receipt carries no invented PUT capability")

        let (failedClient, _) = ticket([
            "asset_id": child, "mode": "single", "transport_version": 2, "uploaded": false,
            "restart_required": true, "restart_reason": "interrupted", "restart_generation": 3
        ])
        let failed = try await failedClient.restartUpload(assetID: parent, operationID: operation)
        try check(failed.restartRequired == true, "Snake-case restart_required is decoded")
        try check(failed.restartReason == "interrupted" && failed.restartGeneration == 3, "Exhaustion reason and generation are preserved")
        try check(failed.putURL == nil && failed.retryAfterSeconds == nil, "Failed ticket invents neither URL nor retry timer")

        let (completedClient, _) = ticket([
            "asset_id": parent, "mode": "single", "uploaded": true, "replayed": true,
            "transport_version": 2, "restart_required": false, "restart_generation": 0
        ])
        let completed = try await completedClient.restartUpload(assetID: parent, operationID: operation)
        try check(completed.assetID == parent && completed.uploaded == true, "Original completion winner survives decoding")
        try check(completed.putURL == nil && completed.restartRequired == false, "Completed receipt needs no upload URL")

        let (multipartClient, _) = ticket([
            "asset_id": child, "mode": "multipart", "upload_id": "fixture-multipart-id",
            "part_size": 33_554_432, "part_count": 3, "transport_version": 2,
            "confirmed_parts": [["number": 1, "etag": "\"one\""], ["number": 3, "etag": "\"three\""]],
            "restart_generation": 2, "restart_required": false
        ])
        let multi = try await multipartClient.restartUpload(assetID: parent, operationID: operation)
        try check(multi.mode == .multipart, "Multipart mode is preserved")
        try check(multi.uploadID == "fixture-multipart-id", "Snake-case upload_id is preserved")
        try check(multi.partSize == 33_554_432 && multi.partCount == 3, "Multipart geometry is decoded")
        try check(multi.confirmedParts == [.init(number: 1, etag: "\"one\""), .init(number: 3, etag: "\"three\"")], "Confirmed part receipts are decoded exactly")
        try check(multi.restartGeneration == 2, "Multipart restart generation is retained")

        let (minimalClient, _) = ticket(["asset_id": child])
        let minimal = try await minimalClient.restartUpload(assetID: parent, operationID: operation)
        try check(minimal.assetID == child && minimal.mode == .single, "Existing minimal DTO compatibility remains explicit")
        try check(minimal.restartRequired == nil && minimal.restartReason == nil && minimal.restartGeneration == nil && minimal.retryAfterSeconds == nil, "Missing optional recovery metadata remains nil")

        let invalid: [[String: Any]] = [
            ["asset_id": child, "retry_after_seconds": "15"],
            ["asset_id": child, "restart_required": "true"],
            ["asset_id": child, "restart_generation": "1"],
            ["asset_id": 7], ["mode": "single"]
        ]
        for fields in invalid {
            let (invalidClient, invalidTransport) = ticket(fields)
            do {
                _ = try await invalidClient.restartUpload(assetID: parent, operationID: operation)
                throw WireFailure(description: "Malformed recovery metadata must fail actual decoding")
            } catch APIError.decoding {
                try check(invalidTransport.requests.count == 1, "Malformed response fails after exactly one execute")
            }
        }
    }
    static func main() async {
        do {
            try await run()
            print("PASS UploadRestartWireTests \(checks) assertions")
        } catch {
            print("FAIL \(error)")
            exit(1)
        }
    }
}
