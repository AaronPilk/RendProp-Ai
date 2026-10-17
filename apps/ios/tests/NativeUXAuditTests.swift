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
        let planListing = UUID(), planOrg = UUID(), planAsset = UUID(), planNow = Date(timeIntervalSince1970: 1_800_000_000)
        let planStamp = DateFormatter(); planStamp.locale = Locale(identifier: "en_US_POSIX"); planStamp.timeZone = TimeZone(secondsFromGMT: 0); planStamp.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let planURL = URL(string: "https://" + String(repeating: "a", count: 32) + ".r2.cloudflarestorage.com/bucket/renders/\(planOrg.uuidString.lowercased())/\(planListing.uuidString.lowercased())/plan.jpg?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-SignedHeaders=host&X-Amz-Signature=" + String(repeating: "b", count: 64) + "&X-Amz-Expires=600&X-Amz-Date=" + planStamp.string(from: planNow))!
        let planExpiry = ISO8601DateFormatter().string(from: planNow.addingTimeInterval(600))
        let planPhoto = CloudMediaPage.Photo(id: planAsset, listing_id: planListing, url: planURL, expires_at: planExpiry, caption: nil, is_staged: false, is_altered: false, original_url: nil)
        let planDetails = ["floorplan_asset_id": planAsset.uuidString, "floorplan_url": "https://cdn.rendprop.com/renders/old.jpg"]
        expect(CloudFloorPlanLink.resolve(details: planDetails, photos: [planPhoto], listingID: planListing, orgID: planOrg, now: planNow) == planURL, "attached floorplan uses scoped signed media URL")
        expect(CloudFloorPlanLink.resolve(details: planDetails, photos: [], listingID: planListing, orgID: planOrg, now: planNow) == nil, "missing plan never falls back to raw R2")
        expect(CloudFloorPlanLink.resolve(details: planDetails, photos: [planPhoto], listingID: UUID(), orgID: planOrg, now: planNow) == nil, "foreign listing plan refused")
        expect(CloudFloorPlanLink.resolve(details: planDetails, photos: [planPhoto], listingID: planListing, orgID: UUID(), now: planNow) == nil, "foreign org plan refused")
        expect(CloudFloorPlanLink.resolve(details: planDetails, photos: [planPhoto], listingID: planListing, orgID: planOrg, now: planNow.addingTimeInterval(601)) == nil, "expired floorplan refuses before link")
        expect(CloudFloorPlanLink.resolve(details: ["floorplan_url":"https://plans.fixture.invalid/external.png"], photos: [], listingID: planListing, orgID: planOrg, now: planNow)?.host == "plans.fixture.invalid", "external no-asset attachment survives")
        expect(CloudFloorPlanLink.resolve(details: ["floorplan_url":"https://cdn.fixture.invalid/renders/old.jpg"], photos: [], listingID: planListing, orgID: planOrg, now: planNow) == nil, "legacy private alias refused")
        expect(CloudFloorPlanLink.resolve(details: ["floorplan_url":"https://pub-fixture.r2.dev/old.jpg"], photos: [], listingID: planListing, orgID: planOrg, now: planNow) == nil, "managed R2 legacy alias refused")
        let priorIndustry = UserDefaults.standard.object(forKey: "space.type")
        for industry in SpaceType.allCases {
            UserDefaults.standard.set(industry.rawValue, forKey: "space.type")
            let guide = AppGuideTopic.allCases.flatMap { $0.steps.map { $0.1 } }.joined(separator: " ")
            expect(AppGuideTopic.listing.title == "Start a \(industry.spaceNoun)", "guide title follows selected industry")
            expect(guide.contains("MLS") == (industry == .realEstate), "guide MLS instructions are housing only")
            expect(AppGuideTopic.allCases.allSatisfy { $0.steps.count == 3 }, "every industry retains complete offline feature guide")
        }
        if let priorIndustry { UserDefaults.standard.set(priorIndustry, forKey: "space.type") }
        else { UserDefaults.standard.removeObject(forKey: "space.type") }
        // Compile and execute the actual root admission and drain bodies. These
        // mutable closed UI/session states never create credentials or a user.
        let routes = RootRouteFixture()
        AuthStore.shared.userID = nil; AuthStore.shared.isSignedIn = false; AuthStore.shared.isIdentified = false
        routes.hasOnboarded = true
        for route in [NativeIncomingRoute.link(link), .leads, .pushPermission, .invalidLink] { routes.incomingQueue.enqueue(route) }
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.routes.count == 4 && routes.incomingLink == nil && routes.rootSheet == nil && !routes.incomingLinkError, "required account keeps queued private routes unpresented")
        AuthStore.shared.userID = UUID().uuidString; AuthStore.shared.isSignedIn = true
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.routes.count == 4 && routes.incomingLink == nil, "legacy guest keeps queued private routes unpresented")
        AuthStore.shared.isIdentified = true; routes.hasOnboarded = false
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.routes.count == 4 && routes.incomingLink == nil, "business onboarding keeps queued private routes unpresented")
        routes.hasOnboarded = true; routes.scenePhase = .background
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.routes.count == 4, "background cannot cover required account or business screens")
        routes.scenePhase = .active; NativePresentationAvailability.hasPresentedController = true
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.routes.count == 4, "actual root drain preserves link behind a feature modal")
        NativePresentationAvailability.hasPresentedController = false; PaywallRouter.shared.present(reason: .upgrade)
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.routes.count == 4, "actual root drain preserves link behind purchase presentation")
        PaywallRouter.shared.dismiss(); routes.drainIncomingRoutes()
        expect(routes.incomingLink == link && routes.incomingQueue.routes.count == 3, "identified onboarded account receives retained link once")
        routes.incomingLink = nil; routes.drainIncomingRoutes()
        expect(routes.rootSheet == .leadsInbox && routes.incomingQueue.routes.count == 2, "identified account receives retained lead after link")
        routes.rootSheet = nil; routes.drainIncomingRoutes()
        expect(routes.rootSheet == .pushPrePrompt && routes.incomingQueue.routes.count == 1, "identified account receives retained permission after lead")
        routes.rootSheet = nil; routes.drainIncomingRoutes()
        expect(routes.incomingLinkError && !routes.incomingQueue.hasPending, "identified account sees retained invalid-link error once")
        routes.incomingLinkError = false; routes.incomingQueue.enqueue(.leads); AuthStore.shared.isSignedIn = false
        routes.drainIncomingRoutes()
        expect(routes.incomingQueue.hasPending && routes.rootSheet == nil, "signout regates subsequent root routes")

        print("Native UX actual bodies: \(assertions) assertions passed")
    }
    @MainActor static func settle() async { for _ in 0..<20 { await Task.yield() } }
}
