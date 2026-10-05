import Foundation

@main struct NativeUXAuditTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
            assertions += 1
            guard condition() else { fatalError("FAILED: \(label)") }
        }
        var queue = NativeIncomingQueue()
        let link = DeepLink.tour(slug: "synthetic-tour")
        expect(queue.enqueue(.link(link)), "link retained")
        expect(queue.enqueue(.link(link)), "duplicate acknowledged")
        expect(queue.routes.count == 1, "repeat coalesced")
        expect(queue.takeNext(canPresent: false) == nil && queue.hasPending, "capture modal retains link")
        expect(queue.enqueue(.leads), "push retained behind capture")
        expect(queue.takeNext(canPresent: true) == .link(link), "link resumes first")
        expect(queue.takeNext(canPresent: true) == .leads, "lead resumes second")
        expect(queue.takeNext(canPresent: true) == nil, "no replay")
        for n in 0..<NativeIncomingQueue.limit { expect(queue.enqueue(.link(.tour(slug: "tour-\(n)"))), "burst retained") }
        expect(!queue.enqueue(.leads), "bounded queue refuses excess")
        for _ in 0..<NativeIncomingQueue.limit { expect(queue.takeNext(canPresent: true) != nil, "retained burst drains") }
        expect(queue.takeNext(canPresent: true) == .invalidLink, "overflow reported")
        expect(!queue.hasPending, "overflow consumed once")
        expect(DeepLink.parse(URL(string: "https://rendprop.com/u/synthetic")!) == nil, "MLS unbranded stays external")
        expect(DeepLink.parse(URL(string: "https://untrusted.invalid/f/synthetic")!) == nil, "external host cannot become tour")

        let presenterRoot = UIViewController(), child = UIViewController(), nested = UIViewController()
        presenterRoot.children = [child]; child.children = [nested]
        expect(!NativePresentationAvailability.hasPresentedController(in: presenterRoot), "ordinary nested navigation can receive incoming route")
        nested.presentedViewController = UIViewController()
        expect(NativePresentationAvailability.hasPresentedController(in: presenterRoot), "nested capture controller keeps incoming route deferred")
        nested.presentedViewController = nil; presenterRoot.presentedViewController = UIViewController()
        expect(NativePresentationAvailability.hasPresentedController(in: presenterRoot), "root-owned form keeps incoming route deferred")
        presenterRoot.presentedViewController = nil
        expect(!NativePresentationAvailability.hasPresentedController(in: presenterRoot), "dismissed feature permits queue continuation")

        let router = PaywallRouter.shared
        let root = UUID(), modal = UUID()
        router.registerHost(root)
        router.present(reason: .upgrade)
        expect(router.ownsPresentation(root), "root upgrade visible")
        router.registerHost(modal)
        expect(router.ownsPresentation(modal) && !router.ownsPresentation(root), "modal owns upgrade")
        router.removeHost(root)
        expect(router.ownsPresentation(modal), "root disappearing cannot swallow modal upgrade")
        router.dismiss()
        expect(!router.ownsPresentation(modal), "single purchase dismissal")
        router.removeHost(modal)

        let form = FormFixture()
        AuthStore.shared.userID = nil; AuthStore.shared.isIdentified = false
        WorkspaceContext.selectedOrgID = nil
        form.bindFormContext(); form.text = "100 Typed Address"
        AuthStore.shared.userID = "guest"; AuthStore.shared.syncSessionRevision += 1
        WorkspaceContext.selectedOrgID = UUID()
        form.bindInitialFormContext()
        expect(form.formContextIsCurrent && form.text == "100 Typed Address", "initial readiness preserves typed form")
        let oldOrg = WorkspaceContext.selectedOrgID
        WorkspaceContext.selectedOrgID = UUID()
        form.bindInitialFormContext()
        expect(!form.formContextIsCurrent && form.formWorkspaceID == oldOrg, "team switch cannot silently rebind draft")
        form.bindFormContext()
        expect(form.formContextIsCurrent && form.text == "100 Typed Address", "explicit new destination preserves details")
        AuthStore.shared.userID = "different-named-user"; AuthStore.shared.isIdentified = true
        form.bindInitialFormContext()
        expect(!form.formContextIsCurrent, "named account switch requires deliberate rebind")

        var listing = Listing(address: "Synthetic archived house", beds: 0, baths: 0, sqft: 0, price: Money(cents: 0))
        listing.serverID = UUID(); listing.cloudArchived = true
        listing.factsSync = ListingFactsSyncState()
        listing.factsSync?.baseline = ["status": .text("archived"), "beds": .number(0), "baths": .number(0), "sqft": .number(0), "price_cents": .number(0)]
        expect(listing.isArchived && listing.isInactive && !listing.isSold, "Studio archive without soldAt excluded from active")
        let data = try JSONEncoder().encode(listing)
        let restored = try JSONDecoder().decode(Listing.self, from: data)
        expect(restored.isArchived && restored.cloudArchived == true, "archive persists across relaunch")
        var active = restored; active.cloudArchived = false
        ListingFactsSync.stage(from: restored, in: &active)
        expect(active.factsSync?.fields["status"]?.expected == .text("archived"), "unarchive CAS expects archived")
        expect(active.factsSync?.fields["status"]?.value == .text("ready"), "explicit mark active clears server archive")
        var edited = restored; edited.beds = 1; edited.baths = 1; edited.sqft = 1200; edited.price = Money(cents: 300_000)
        ListingFactsSync.stage(from: restored, in: &edited)
        for field in ["beds", "baths", "sqft", "price_cents"] {
            expect(edited.factsSync?.fields[field]?.expected == .number(0), "literal zero CAS baseline \(field)")
        }
        var unrelated = restored; unrelated.address = "Corrected address"
        ListingFactsSync.stage(from: restored, in: &unrelated)
        expect(unrelated.factsSync?.fields["beds"] == nil, "unrelated edit preserves Studio zero")

        let wireID = UUID(), wireOrg = UUID()
        let raw: [String: Any] = ["id": wireID.uuidString, "org_id": wireOrg.uuidString, "address": "Studio archive", "status": "archived", "beds": 0, "baths": 0, "sqft": 0, "price_cents": 0]
        let mapped = try ListingMappingFixture().mapJSON(JSONSerialization.data(withJSONObject: raw))
        expect(mapped.isArchived && !mapped.isSold, "live DTO archive maps independently of soldAt")
        expect(mapped.factsSync?.baseline["beds"] == .number(0), "DTO literal zero remains CAS baseline")
        var cached = mapped; cached.cloudArchived = false
        let merged = try CloudMergeFixture.merge(local: [cached], remote: [mapped], protected: [])
        expect(merged.count == 1 && merged[0].isArchived, "current cloud archive survives real merge")
        let protected = try CloudMergeFixture.merge(local: [cached], remote: [mapped], protected: [cached.id])
        expect(!protected[0].isArchived, "in-flight local completion remains protected")

        let photo = PhotoFixture()
        AIConsent.shared.isGranted = false
        photo.runPhotoAI { photo.dispatches += 1 }
        await settle()
        expect(photo.dispatches == 0 && photo.connection.calls == 0, "declined consent prevents AI dispatch")
        AIConsent.shared.isGranted = true
        photo.runPhotoAI { photo.dispatches += 1 }
        await settle()
        expect(photo.dispatches == 1 && photo.connection.calls == 1, "accepted current consent dispatches once")
        AIConsent.shared.wait = true
        photo.runPhotoAI { photo.dispatches += 1 }
        await settle()
        WorkspaceContext.selectedOrgID = UUID()
        AIConsent.shared.resume()
        await settle()
        expect(photo.dispatches == 1, "workspace change while disclosure waits cannot dispatch old photo")

        let player = PlayerFixture()
        player.showLoading()
        expect(player.statusOverlay?.isHidden == false && player.retryButton?.isHidden == true, "native loading state")
        player.showFailure()
        expect(player.retryButton?.isHidden == false && player.loadingIndicator?.animating == false, "offline exposes retry")
        expect(player.statusLabel?.text?.contains("Check your connection") == true, "failure is useful without secret URL")
        player.webView(WKWebView(), didFinish: WKNavigation())
        expect(player.statusOverlay?.isHidden == true, "successful retry clears loading")
        player.stop(); player.showFailure()
        expect(!player.isMounted && player.retry == nil, "dismantled preview cannot resume")
        print("Native UX actual bodies: \(assertions) assertions passed")
    }
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
}
