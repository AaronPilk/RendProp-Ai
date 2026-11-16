import Foundation

struct PropertyVideoCancellationIntent: Codable, Equatable, Sendable {
    let actorID: UUID
    let operationID: UUID
    let reason: String
    let createdAt: Date
    var isValid: Bool { ["ai_consent_revoked", "local_data_erasure"].contains(reason) }
}

/// Persist before sending. A replay stops the original set of jobs, and never
/// cancels a newer video that was accepted after the server's first receipt.
@MainActor final class PropertyVideoJobCancellation {
    static let shared = PropertyVideoJobCancellation()
    private var inFlight: [UUID: Task<Void, Error>] = [:]
    private var observedRevocation: UInt64 = 0
    private var savedStopsInFlight: [UUID: (id: UUID, task: Task<Void, Never>)] = [:]
    private static func key(_ actor: UUID) -> String { "property-video.cancel-intent." + actor.uuidString.lowercased() }
    private static func queue(actorID: UUID, defaults: UserDefaults) throws -> [PropertyVideoCancellationIntent] {
        guard let data = defaults.data(forKey: key(actorID)) else { return [] }
        guard data.count <= 16384 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        let intents = try JSONDecoder().decode([PropertyVideoCancellationIntent].self, from: data)
        guard intents.count <= 64, Set(intents.map(\.operationID)).count == intents.count,
              intents.allSatisfy({ $0.actorID == actorID && $0.isValid }) else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return intents
    }
    static func pending(actorID: UUID, defaults: UserDefaults = .standard) throws -> PropertyVideoCancellationIntent? {
        try queue(actorID: actorID, defaults: defaults).first
    }
    static func record(actorID: UUID, reason: String, defaults: UserDefaults = .standard) throws -> PropertyVideoCancellationIntent {
        var intents = try queue(actorID: actorID, defaults: defaults)
        let intent = PropertyVideoCancellationIntent(actorID: actorID, operationID: UUID(), reason: reason, createdAt: Date())
        guard intent.isValid, intents.count < 64 else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        intents.append(intent)
        let data = try JSONEncoder().encode(intents)
        defaults.set(data, forKey: key(actorID))
        guard defaults.data(forKey: key(actorID)) == data else { throw PropertyVideoJobStore.Failure.invalidReceipt }
        return intent
    }
    static func retire(_ intent: PropertyVideoCancellationIntent, defaults: UserDefaults = .standard) throws {
        var intents = try queue(actorID: intent.actorID, defaults: defaults)
        guard let index = intents.firstIndex(where: { $0.operationID == intent.operationID }) else { return }
        intents.remove(at: index)
        if intents.isEmpty { defaults.removeObject(forKey: key(intent.actorID)) }
        else { defaults.set(try JSONEncoder().encode(intents), forKey: key(intent.actorID)) }
    }
    func request(reason: String) async throws {
        guard AuthStore.shared.isIdentified, let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) else { return }
        _ = try Self.record(actorID: actor, reason: reason)
        try await acknowledgePending(actorID: actor)
    }
    func acknowledgePending(actorID: UUID) async throws {
        if let existing = inFlight[actorID] { try await existing.value; return }
        guard try Self.pending(actorID: actorID) != nil else { return }
        let task = Task { @MainActor in
            while let intent = try Self.pending(actorID: actorID) {
                try await PropertyVideoJobHTTP.stopOwnedJobs(intent)
                try Self.retire(intent)
            }
        }
        inFlight[actorID] = task
        defer { inFlight[actorID] = nil }
        try await task.value
    }
    func retryPending() {
        guard AuthStore.shared.isIdentified, let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) else { return }
        Task { try? await self.acknowledgePending(actorID: actor); await self.acknowledgeSavedStops(actorID: actor) }
    }
    /// Supplementary withdrawal stops only saved v2 operations. A legacy FAL/v1
    /// request never enters this journal merely because Kie was turned off.
    func processorWasRevoked() {
        guard AuthStore.shared.isIdentified, let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) else { return }
        do { try PropertyVideoJobStore.requestStop(actorID: actor, documents: FileStore.documents, processorOnly: true) }
        catch { return } // Nothing is retired; a later explicit retry remains safe.
        Task { await self.acknowledgeSavedStops(actorID: actor) }
    }
    func acknowledgeSavedStops(actorID: UUID) async {
        if let existing = savedStopsInFlight[actorID] { await existing.task.value; return }
        let identity = UUID()
        let task = Task { @MainActor in
            await self.processSavedStops(actorID: actorID)
            if self.savedStopsInFlight[actorID]?.id == identity { self.savedStopsInFlight[actorID] = nil }
        }
        savedStopsInFlight[actorID] = (identity, task)
        await task.value
    }
    private func processSavedStops(actorID: UUID) async {
        guard let api = LiveAPIClient(), let savedJobs = try? PropertyVideoJobStore.actorJobs(actorID: actorID, documents: FileStore.documents) else { return }
        for var saved in savedJobs where saved.stopRequested == true && saved.context.hasCurrentIdentity && saved.abandoned == nil && !saved.wasRefusedBeforeAdmission {
            if let reply = saved.reply, reply.isTerminal && !reply.mayResume { continue }
            do {
                if saved.reply == nil {
                    var lookup = try await api.propertyVideoOperation(saved, abandon: false)
                    if lookup.job == nil && !lookup.operationClosed { lookup = try await api.propertyVideoOperation(saved, abandon: true) }
                    if let job = lookup.job { saved.reply = try job.checked(request: saved.request) }
                    else if let closure = lookup.abandonment { saved.abandoned = closure }
                    else if lookup.operationClosed && lookup.closedReason == "capacity_refused" {
                        saved.capacityRefusal = .init(operationID: saved.request.operationID, listingID: saved.request.listingID,
                            selectedLibraryOrgID: saved.request.expectedOrgID, status: 402, code: "capacity_refused", operationClosed: true,
                            message: "This saved request was closed before video generation.", observedAt: Date())
                    } else { throw PropertyVideoProcessorFailure.operationPending }
                    try PropertyVideoJobStore.save(saved, documents: FileStore.documents)
                }
                if saved.reply != nil {
                    saved.reply = try await api.cancelPropertyVideoJob(saved)
                    try PropertyVideoJobStore.save(saved, documents: FileStore.documents)
                }
            } catch { continue } // Keep the exact stop for GET/cancel after loss.
        }
    }
    func consentWasRevoked() {
        // A new install with no grant is not a revocation. Only an explicit
        // Turn off event may cancel this actor's already-accepted work.
        let revision = AIConsent.shared.revocationRevision
        guard !AIConsent.shared.isGranted, revision > observedRevocation else { return }
        observedRevocation = revision
        guard AuthStore.shared.isIdentified, let actor = AuthStore.shared.userID.flatMap(UUID.init(uuidString:)) else { return }
        do {
            _ = try Self.record(actorID: actor, reason: "ai_consent_revoked")
            try PropertyVideoJobStore.requestStop(actorID: actor, documents: FileStore.documents)
        } catch { return }
        Task { try? await self.acknowledgePending(actorID: actor); await self.acknowledgeSavedStops(actorID: actor) }
    }
}
