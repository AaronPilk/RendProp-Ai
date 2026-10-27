import Foundation

@main struct NativePresentationPrivacyTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        guard value else { FileHandle.standardError.write(Data(("FAIL " + message + "\n").utf8)); exit(1) }
    }
    @MainActor static func waitFor(_ value: () -> Bool) async {
        for _ in 0..<200 {
            if value() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        check(false, "Fixture continuation did not arrive")
    }
    @MainActor static func main() async {
        let orgA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let orgB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let defaults = UserDefaults.standard
        defer { defaults.removePersistentDomain(forName: UserDefaults.suite) }
        AuthStore.shared.userID = "actor-a"; WorkspaceContext.selectedOrgID = orgA
        defaults.set(true, forKey: "tour.searchIndexing.default")
        defaults.set("actor-a", forKey: "tour.searchIndexing.defaultOwner")
        check(!SearchIndexingDefault.value, "Legacy actor-only indexing preference cannot opt a workspace in")
        SearchIndexingDefault.remember(true)
        check(SearchIndexingDefault.value, "Explicit indexing choice applies to the same account and workspace")
        WorkspaceContext.selectedOrgID = orgB
        check(!SearchIndexingDefault.value, "Indexing opt-in cannot carry into another workspace")
        SearchIndexingDefault.remember(false)
        WorkspaceContext.selectedOrgID = orgA
        check(SearchIndexingDefault.value, "Another workspace choice preserves the original workspace preference")
        AuthStore.shared.userID = "actor-b"
        check(!SearchIndexingDefault.value, "Indexing opt-in cannot carry into another account")
        AuthStore.shared.userID = nil
        check(!SearchIndexingDefault.value, "Signed-out indexing default stays off")
        let savedDefaults = defaults.persistentDomain(forName: UserDefaults.suite) ?? [:]
        SearchIndexingDefault.remember(true)
        check((defaults.persistentDomain(forName: UserDefaults.suite) ?? [:]) as NSDictionary == savedDefaults as NSDictionary,
              "An absent account cannot record an indexing opt-in")
        AuthStore.shared.userID = "actor-a"; WorkspaceContext.selectedOrgID = nil
        check(!SearchIndexingDefault.value, "No selected workspace means indexing off")
        SearchIndexingDefault.remember(true)
        check((defaults.persistentDomain(forName: UserDefaults.suite) ?? [:]) as NSDictionary == savedDefaults as NSDictionary,
              "An absent workspace cannot record an indexing opt-in")
        let scope = NativePresentationScope(actorID: "actor-a", orgID: orgA)
        check(scope.matches(actorID: "actor-a", orgID: orgA), "Same actor and workspace preserves presentation")
        check(scope == NativePresentationScope(actorID: "actor-a", orgID: orgA), "Token refresh does not create a different navigation identity")
        check(!scope.matches(actorID: "actor-b", orgID: orgA), "Another account invalidates presentation")
        check(!scope.matches(actorID: "actor-a", orgID: orgB), "Another workspace invalidates presentation")
        check(!scope.matches(actorID: nil, orgID: orgA), "Sign-out invalidates presentation")
        check(!scope.matches(actorID: "actor-a", orgID: nil), "Removed workspace invalidates presentation")

        func host() -> PresentationHarness {
            WorkspaceContext.selectedOrgID = orgA
            return PresentationHarness(scope: scope, auth: FixtureAuth(userID: "actor-a"))
        }
        let currentContact = host(); await currentContact.refreshClientContactIfCurrent()
        check(currentContact.model.contactCalls == 1, "Current account can refresh its listing contact")
        let staleAccountContact = host(); staleAccountContact.auth.userID = "actor-b"
        await staleAccountContact.refreshClientContactIfCurrent()
        check(staleAccountContact.model.contactCalls == 0, "Stale account cannot dispatch listing contact request")
        let staleOrgContact = host(); WorkspaceContext.selectedOrgID = orgB
        await staleOrgContact.refreshClientContactIfCurrent()
        check(staleOrgContact.model.contactCalls == 0, "Stale workspace cannot dispatch listing contact request")
        let cancelledContact = host()
        let contactTask = Task { await cancelledContact.refreshClientContactIfCurrent() }; contactTask.cancel()
        await contactTask.value
        check(cancelledContact.model.contactCalls == 0, "Cancelled detail cannot dispatch listing contact request")
        let valid = host(); valid.loadFiles()
        await waitFor { ScanFixture.pending.count == 1 }
        ScanFixture.pending.removeFirst().resume(returning: .init(stamp: 1, items: [11]))
        await waitFor { valid.mediaItems == [11] }
        check(valid.filesStamp == 1 && valid.dismissals == 0, "Current listing can display its local files")

        let switchedAccount = host(); switchedAccount.mediaItems = [99]; switchedAccount.loadFiles()
        switchedAccount.filePackageExtras = [101]; switchedAccount.packageError = "Old account package error"
        let oldPlayer = FixturePlayer(); switchedAccount.websiteVideoPlayer = oldPlayer
        switchedAccount.publishedVideoStatus = .live
        let oldVideoStatusTask = Task<Void, Never> { try? await Task.sleep(nanoseconds: 30_000_000_000) }
        switchedAccount.publishedVideoTask = oldVideoStatusTask
        let accountScan = switchedAccount.filesTask
        await waitFor { ScanFixture.pending.count == 1 }
        switchedAccount.auth.userID = "actor-b"
        ScanFixture.pending.removeFirst().resume(returning: .init(stamp: 2, items: [22]))
        await accountScan?.value
        check(switchedAccount.mediaItems == [99] && switchedAccount.filesStamp == nil,
              "Late file scan cannot publish after account switch")
        check(!switchedAccount.hasCurrentPresentationContext, "Old detail content is hidden immediately after account switch")
        switchedAccount.invalidatePresentation()
        check(oldPlayer.pauses == 1, "Account invalidation pauses the old property video")
        check(switchedAccount.websiteVideoPlayer == nil, "Account invalidation drops the old property video reference")
        check(oldVideoStatusTask.isCancelled && switchedAccount.publishedVideoTask == nil,
              "Invalidation cancels old published-video status fetch")
        check(switchedAccount.publishedVideoStatus == .unpublished,
              "Invalidation clears old published-video status")
        check(switchedAccount.filePackageExtras.isEmpty, "Account invalidation clears old listing package extras")
        check(switchedAccount.packageError == nil, "Account invalidation clears old listing package error")

        let switchedOrg = host(); switchedOrg.mediaItems = [99]; switchedOrg.loadFiles()
        switchedOrg.filePackageExtras = [202]; switchedOrg.packageError = "Old workspace package error"
        let orgScan = switchedOrg.filesTask
        await waitFor { ScanFixture.pending.count == 1 }
        WorkspaceContext.selectedOrgID = orgB
        ScanFixture.pending.removeFirst().resume(returning: .init(stamp: 3, items: [33]))
        await orgScan?.value
        check(switchedOrg.mediaItems == [99] && switchedOrg.filesStamp == nil,
              "Late file scan cannot publish after workspace switch")
        check(!switchedOrg.hasCurrentPresentationContext, "Old detail content is hidden immediately after workspace switch")
        switchedOrg.invalidatePresentation()
        check(switchedOrg.filePackageExtras.isEmpty && switchedOrg.packageError == nil,
              "Workspace invalidation clears old listing package state")

        let cleared = host(); cleared.mediaItems = [44]; cleared.openedFile = 1
        cleared.filePhotoExport = 1; cleared.filePhotoExportAdmission = { true }
        cleared.filePackageExtras = [303]; cleared.packageError = "Old package failure"
        cleared.provenance = [1]; cleared.provenanceCanExport = { true }; cleared.auditExport = 1
        cleared.showPhotosScreen = true; cleared.showReelStudio = true; cleared.showRoomTagger = true
        cleared.showRoomTagsWalkthroughHelp = true; cleared.showWalkthroughForRoomTags = true
        cleared.availableRoomTagAsset = 404
        cleared.showComplianceDetails = true
        cleared.availableRerenderSource = URL(fileURLWithPath: "/synthetic.mov")
        cleared.linkShareTarget = 777
        cleared.verifiedBuyerLink = ("old-link", URL(string: "https://old-buyer-link.invalid/")!)
        cleared.resolvingBuyerLinkKey = "old-link"
        cleared.withdrawnBuyerLinkKey = "old-link"
        cleared.loadFiles(); await waitFor { ScanFixture.pending.count == 1 }
        let cancelledScan = cleared.filesTask
        cleared.invalidatePresentation()
        check(cleared.mediaItems.isEmpty && cleared.openedFile == nil && cleared.filesStamp == nil,
              "Invalidation clears old local-file presentation")
        check(cleared.filePhotoExport == nil && cleared.filePhotoExportAdmission == nil && cleared.auditExport == nil,
              "Invalidation clears old export presentations")
        check(cleared.filePackageExtras.isEmpty && cleared.packageError == nil,
              "Invalidation clears package extras and package error alongside export presentation")
        check(cleared.provenance.isEmpty && cleared.provenanceCanExport == nil && cleared.availableRerenderSource == nil,
              "Invalidation clears old listing-derived details")
        check(!cleared.showPhotosScreen && !cleared.showReelStudio && !cleared.showRoomTagger && cleared.dismissals == 1,
              "Invalidation closes old feature presentation")
        check(!cleared.showComplianceDetails, "Invalidation collapses old listing disclosure presentation")
        check(!cleared.showRoomTagsWalkthroughHelp, "Invalidation closes old room-tag help")
        check(!cleared.showWalkthroughForRoomTags, "Invalidation closes old walkthrough destination")
        check(cleared.availableRoomTagAsset == nil, "Invalidation drops old room-tag source")
        check(cleared.linkShareTarget == nil, "Invalidation closes the old buyer-link share sheet")
        check(cleared.verifiedBuyerLink == nil, "Invalidation clears the old verified buyer link")
        check(cleared.resolvingBuyerLinkKey == nil, "Invalidation clears the old buyer-link lookup identity")
        check(cleared.withdrawnBuyerLinkKey == nil, "Invalidation clears the old withdrawn buyer link identity")
        check(cleared.sharedAdmittedJobs == 7, "Presentation invalidation leaves admitted shared jobs untouched")
        ScanFixture.pending.removeFirst().resume(returning: .init(stamp: 4, items: [55]))
        await cancelledScan?.value
        check(cleared.mediaItems.isEmpty, "Cancelled scan cannot restore files after invalidation")

        let stale = host(); WorkspaceContext.selectedOrgID = orgB
        stale.mediaItems = [66]; stale.loadFiles()
        check(ScanFixture.pending.isEmpty && stale.mediaItems.isEmpty && stale.dismissals == 1,
              "A stale screen cannot start another local-file scan")

        let overlapping = host(); overlapping.loadFiles()
        let olderScan = overlapping.filesTask
        await waitFor { ScanFixture.pending.count == 1 }
        overlapping.loadFiles(force: true)
        await waitFor { ScanFixture.pending.count == 2 }
        let old = ScanFixture.pending.removeFirst(), newest = ScanFixture.pending.removeFirst()
        newest.resume(returning: .init(stamp: 6, items: [77]))
        await waitFor { overlapping.mediaItems == [77] }
        old.resume(returning: .init(stamp: 5, items: [88]))
        await olderScan?.value
        check(overlapping.mediaItems == [77] && overlapping.filesStamp == 6,
              "Cancelled older scan cannot replace a newer current listing scan")
        print("PASS NativePresentationPrivacyTests \(checks) checks")
    }
}
