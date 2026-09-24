import Foundation
import Combine

/// Retained beyond a screen's lifetime. One writer per property/account avoids
/// an old view's reply overwriting a newly reopened view's local edits.
@MainActor final class ProductionPlanSyncStore: ObservableObject {
    static let shared = ProductionPlanSyncStore()
    struct Context: Hashable {
        let owner: String
        let listingID: UUID
        var key: String { "\(owner)|\(listingID.uuidString.lowercased())" }
    }
    @Published private(set) var drafts: [String: ProductionPlanCache.Draft] = [:]
    @Published private(set) var saving = Set<String>()
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var notices: [String: String] = [:]
    private var debounces: [String: Task<Void, Never>] = [:]

    func load(_ context: Context, serverID: UUID?) throws {
        guard drafts[context.key] == nil else { return }
        drafts[context.key] = try ProductionPlanCache.load(owner: context.owner, listingID: context.listingID)
            ?? .init(plan: .starter(listingID: serverID ?? context.listingID), revision: 0, dirty: false)
    }

    func replace(_ draft: ProductionPlanCache.Draft, context: Context) throws {
        try ProductionPlanCache.save(draft, owner: context.owner, listingID: context.listingID)
        drafts[context.key] = draft
    }
    func acceptRemote(_ draft: ProductionPlanCache.Draft, context: Context) throws {
        cancelPending(context)
        try replace(draft, context: context)
        errors[context.key] = nil; notices[context.key] = nil
    }

    func cancelPending(_ context: Context) {
        debounces[context.key]?.cancel(); debounces[context.key] = nil
    }

    func schedule(_ context: Context, serverID: UUID, orgID: UUID, api: ProductionSyncAPI, identity: String) {
        cancelPending(context)
        guard drafts[context.key]?.dirty == true || drafts[context.key]?.pendingWrite != nil else { return }
        debounces[context.key] = Task {
            do { try await Task.sleep(nanoseconds: 700_000_000) }
            catch { return }
            self.debounces[context.key] = nil
            _ = await self.save(context, serverID: serverID, orgID: orgID, api: api, identity: identity)
        }
    }

    @discardableResult func save(_ context: Context, serverID: UUID, orgID: UUID, api: ProductionSyncAPI, identity: String) async -> Bool {
        guard !saving.contains(context.key), identityMatches(context, identity), var currentDraft = drafts[context.key] else { return false }
        if !currentDraft.dirty && currentDraft.revision > 0 && currentDraft.pendingWrite == nil { return true }
        guard currentDraft.revision == 0 || UUID(uuidString: currentDraft.plan.listingId) == serverID else {
            errors[context.key] = "This plan belongs to a different cloud property. Your local draft is kept."
            return false
        }
        currentDraft.plan.listingId = serverID.uuidString.lowercased()
        if currentDraft.pendingWrite == nil {
            currentDraft.pendingWrite = .init(plan: currentDraft.plan, revision: currentDraft.revision)
        }
        guard let pending = currentDraft.pendingWrite else { return false }
        let attempt = ProductionPlanCache.Draft(plan: pending.plan, revision: pending.revision, dirty: true)
        // Retain the exact attempted payload even if the user keeps typing or
        // the process dies before GET can reconcile a lost POST reply. A later
        // retry settles this same attempt before sending newer local content.
        do { try replace(currentDraft, context: context) }
        catch { errors[context.key] = "The local plan couldn’t be saved. Free some storage before syncing."; return false }
        saving.insert(context.key); errors[context.key] = nil; notices[context.key] = nil
        var accepted = false
        defer {
            saving.remove(context.key)
            if accepted, identityMatches(context, identity), drafts[context.key]?.dirty == true {
                schedule(context, serverID: serverID, orgID: orgID, api: api, identity: identity)
            }
        }
        do {
            let document: CloudProductionDocument
            do {
                document = try await api.saveProductionPlan(attempt.plan, listingID: serverID, orgID: orgID, revision: attempt.revision)
            } catch {
                // POST can succeed while its reply is lost. Only the exact
                // payload at the immediate next revision proves this write.
                guard identityMatches(context, identity) else { return false }
                if let remote = try? await api.productionPlan(listingID: serverID, orgID: orgID),
                   ProductionPlanAcknowledgement.accepts(remote, attempt: attempt) {
                    document = remote
                } else {
                    errors[context.key] = "Studio couldn’t confirm these changes. Your phone draft is safe. Retry sync; if another device edited the plan, compare its Studio version before replacing your draft."
                    return false
                }
            }
            guard identityMatches(context, identity), let current = drafts[context.key] else { return false }
            let next = try ProductionPlanAcknowledgement.apply(document, attempt: attempt, current: current)
            try replace(next, context: context)
            notices[context.key] = next.dirty ? "Your latest changes are waiting to sync…" : "Plan synced to Studio. Media upload progress is shown separately."
            accepted = true
            return true
        } catch {
            if identityMatches(context, identity) {
                errors[context.key] = "Studio’s reply couldn’t be confirmed. Your phone draft is kept. Retry sync when connected."
            }
            return false
        }
    }

    func remove(_ listingID: UUID) {
        let suffix = "|\(listingID.uuidString.lowercased())"
        for key in drafts.keys where key.hasSuffix(suffix) {
            debounces[key]?.cancel(); debounces[key] = nil
            drafts[key] = nil; errors[key] = nil; notices[key] = nil
        }
    }

    private func identityMatches(_ context: Context, _ identity: String) -> Bool {
        !Task.isCancelled && AuthStore.shared.isIdentified && AuthStore.shared.userID == context.owner &&
            "\(context.owner):\(AuthStore.shared.syncSessionRevision)" == identity
    }
}
