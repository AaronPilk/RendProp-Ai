import Foundation

/// The server rejected a displayed credit quote before admission, and a
/// current-authority operation lookup found no saved job. The frozen operation
/// can be re-quoted for explicit Review without creating a second operation.
struct PropertyVideoCreditQuoteChanged: Error, LocalizedError, Sendable {
    let operationID: UUID
    var errorDescription: String? { "The Photo motion price changed before your video started. Review the updated price and try again." }
}

/// Current-authority lookup. A plain missing job is not proof of refusal:
/// only the server's durable, operation-locked closure permits a new recipe.
struct PropertyVideoOperationLookup: Decodable, Sendable {
    let operationID: UUID
    let listingID: UUID
    let selectedLibraryOrgID: UUID
    let operationClosed: Bool
    let job: PropertyVideoJobReply?
    let closedReason: String?
    enum CodingKeys: String, CodingKey {
        case operationID = "operation_id", listingID = "listing_id"
        case selectedLibraryOrgID = "selected_library_org_id", operationClosed = "operation_closed", job, closedReason = "closed_reason"
    }
    init(operationID: UUID, listingID: UUID, selectedLibraryOrgID: UUID, operationClosed: Bool, job: PropertyVideoJobReply?, closedReason: String? = nil) {
        self.operationID = operationID; self.listingID = listingID; self.selectedLibraryOrgID = selectedLibraryOrgID
        self.operationClosed = operationClosed; self.job = job; self.closedReason = closedReason
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.job) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        operationID = try c.decode(UUID.self, forKey: .operationID)
        listingID = try c.decode(UUID.self, forKey: .listingID)
        selectedLibraryOrgID = try c.decode(UUID.self, forKey: .selectedLibraryOrgID)
        operationClosed = try c.decodeIfPresent(Bool.self, forKey: .operationClosed) ?? false
        closedReason = try c.decodeIfPresent(String.self, forKey: .closedReason)
        job = try c.decodeIfPresent(PropertyVideoJobReply.self, forKey: .job)
    }
}

struct PropertyVideoCapacityRefusal: Error, LocalizedError, Codable, Equatable, Sendable {
    let operationID: UUID
    let listingID: UUID
    let selectedLibraryOrgID: UUID
    let status: Int
    let code: String
    let operationClosed: Bool
    let message: String
    let observedAt: Date
    var errorDescription: String? { message }
    func provesNoAdmission(for request: PropertyVideoJobRequest) -> Bool {
        status == 402 && code == "capacity_refused" && operationClosed &&
        operationID == request.operationID && listingID == request.listingID && selectedLibraryOrgID == request.expectedOrgID
    }
}

enum PropertyVideoAdmissionResolution {
    case accepted(PropertyVideoJobReply)
    case refused(PropertyVideoCapacityRefusal)
    static func resolve(status: Int, code: String?, message: String, request: PropertyVideoJobRequest,
                        lookup: PropertyVideoOperationLookup) throws -> Self? {
        guard status == 402 && code == "capacity_refused" else { return nil }
        guard lookup.operationID == request.operationID, lookup.listingID == request.listingID,
              lookup.selectedLibraryOrgID == request.expectedOrgID else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if let job = lookup.job { return .accepted(try job.checked(request: request)) }
        guard lookup.operationClosed else { return nil }
        return .refused(.init(operationID: request.operationID, listingID: request.listingID,
            selectedLibraryOrgID: request.expectedOrgID, status: status, code: "capacity_refused", operationClosed: true,
            message: message, observedAt: Date()))
    }
}

struct PropertyVideoOperationClosure: Codable, Equatable, Sendable {
    let operationID: UUID; let listingID: UUID; let selectedLibraryOrgID: UUID; let closedReason: String
    func matches(_ request: PropertyVideoJobRequest) -> Bool {
        operationID == request.operationID && listingID == request.listingID && selectedLibraryOrgID == request.expectedOrgID && closedReason == "abandoned"
    }
}
extension PropertyVideoOperationLookup {
    func checked(request: PropertyVideoJobRequest) throws -> Self {
        guard operationID == request.operationID, listingID == request.listingID, selectedLibraryOrgID == request.expectedOrgID,
              !operationClosed || job == nil, !operationClosed || ["abandoned", "capacity_refused"].contains(closedReason ?? "") else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        if let job { _ = try job.checked(request: request) }
        return self
    }
    var abandonment: PropertyVideoOperationClosure? {
        guard operationClosed, job == nil, closedReason == "abandoned" else { return nil }
        return .init(operationID: operationID, listingID: listingID, selectedLibraryOrgID: selectedLibraryOrgID, closedReason: "abandoned")
    }
}
