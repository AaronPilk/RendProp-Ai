#!/usr/bin/env python3
"""Compile the actual text-only adapter and verify full-length prompt delivery.

The transport is closed in memory. No provider, live account or image is used.
"""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[3]
adapter = (root / "apps/ios/Rendprop/Networking/LiveAPIClient.swift").read_text()
start = adapter.index("    func aiImprovePrompt(rough:")
end = adapter.index("\n    func aiCopyScript", start)
method = adapter[start:end]
sheet = (root / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift").read_text()
custom_sheet = sheet[sheet.index("struct CustomEditSheet:"):sheet.index("// MARK: - AI edit suggestions")]
assert "onGenerate(preparedPrompt)" in custom_sheet
assert 'accessibilityIdentifier("customPhoto.preparedInstruction")' in custom_sheet
assert "onGenerate(text)" not in custom_sheet
assert "prefix(300)" not in custom_sheet
assert "Fresh white walls" not in custom_sheet
assert "freshly painted white" not in custom_sheet
assert "rough: rough" in custom_sheet
assert "customReview.isComplete" in sheet
assert "customReviewed: customReview.isComplete" in sheet
assert "customReview = PhotoVersionHistory.CustomReview()" in sheet
service = (root / "apps/ios/Rendprop/Photos/PhotoEditService.swift").read_text()
assert "if wasMain && version.canAutomaticallySelectForListing" in service
api_source = (root / "apps/ios/Rendprop/Networking/APIClient.swift").read_text()
api_error = api_source[api_source.index("enum APIError:"):api_source.index("// MARK: - Admin console models")]

source = r'''
import Foundation
''' + api_error + r'''
struct SpaceType { static let current = SpaceType(); let rawValue = "real_estate" }
enum Idempotency { case perAttempt }
struct Request { let body: [String: Any] }
@MainActor final class ClosedAdapter {
    var sent: [String: Any] = [:]
    var requests = 0
    var response = "Improve lighting only; preserve existing paint colors."
    let aiSession = "closed"
    func url(_ segments: [String]) -> URL { URL(string: "https://closed.invalid/" + segments.joined(separator: "/"))! }
    func makeRequest(url: URL, method: String, json: [String: Any], idempotency: Idempotency) -> Request {
        precondition(url.absoluteString == "https://closed.invalid/ai-copy/edit-prompt" && method == "POST")
        return Request(body: json)
    }
    func execute(_ request: Request, session: String) async throws -> Data {
        precondition(session == "closed")
        sent = request.body; requests += 1
        return try JSONSerialization.data(withJSONObject: ["prompt": response])
    }
    func decode<T: Decodable>(_ data: Data) throws -> T { try JSONDecoder().decode(T.self, from: data) }
''' + method + r'''
}
@main struct AdapterTests {
    @MainActor static func main() async throws {
        let client = ClosedAdapter()
        let suffix = " Keep the garage door, house trim and all paint colors unchanged."
        let whole = "Improve lighting only. " + String(repeating: "a", count: 600 - 23 - suffix.count) + suffix
        precondition(whole.count == 600)
        let listing = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let result = try await client.aiImprovePrompt(rough: whole, roomHint: "Garage", listingServerID: listing)
        precondition(client.requests == 1)
        precondition(client.sent["rough"] as? String == whole, "the last300 characters must reach the actual request body")
        precondition((client.sent["rough"] as! String).hasSuffix(suffix), "late protective color instructions must not be truncated")
        precondition(client.sent["listing_id"] as? String == listing.uuidString)
        precondition(client.sent["room_hint"] as? String == "Garage")
        precondition(result == client.response)
        _ = try await client.aiImprovePrompt(rough: "  Improve exposure only  ", roomHint: nil, listingServerID: nil)
        precondition(client.sent["rough"] as? String == "Improve exposure only")
        precondition(client.sent["listing_id"] == nil && client.sent["room_hint"] == nil, "missing listing identity is not invented")
        precondition(client.sent["image_base64"] == nil, "text assistance remains text-only")
        client.response = " "
        do {
            _ = try await client.aiImprovePrompt(rough: "Improve exposure", roomHint: nil, listingServerID: nil)
            preconditionFailure("empty model output must fail rather than become an approved instruction")
        } catch APIError.decoding { }
        let clarification = APIError.server(status: 409, code: "photo_clarification_required", message: "Choose a specific change. No edit has been charged.")
        precondition(clarification.isPhotoPromptRefusal && !clarification.isQuota && !clarification.isServiceUnavailable)
        precondition(clarification.recoverySuggestion?.contains("review the instruction") == true)
        let blocked = APIError.server(status: 400, code: "unsupported_edit", message: "We can't repaint a listing photo.")
        precondition(blocked.isPhotoPromptRefusal && !blocked.isQuota)
        let conflict = APIError.server(status: 409, code: "conflict", message: "Already submitted")
        precondition(!conflict.isPhotoPromptRefusal && conflict.isConflict, "ordinary duplicate/conflict behavior is preserved")
        print("Custom photo actual adapter/errors: 15 delivery/negative controls passed; 11 native review source gates passed")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="rendprop-custom-prompt-") as directory:
    path = pathlib.Path(directory)
    swift = path / "adapter.swift"
    swift.write_text(source)
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", str(swift), "-o", str(path / "checks")], check=True, timeout=120)
    subprocess.run([str(path / "checks")], check=True, timeout=20)
