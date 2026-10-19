import Foundation

@main struct PublicWebsiteLinkTests {
    @MainActor static func main() {
        var assertions = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) {
            assertions += 1
            precondition(value(), message)
        }
        for host in ["rendprop.com", "www.rendprop.com"] {
            for path in ["f/owned-fixture", "u/owned-fixture", "a/fixture-agent", "property/owned-fixture"] {
                let url = URL(string: "https://\(host)/\(path)?view=gallery#photos")!
                let app = IncomingWebsiteFixture()
                UIApplication.shared.opened = []
                app.enqueueIncomingURL(url)
                expect(UIApplication.shared.opened == [url], "Buyer page must open unchanged in browser")
                expect(!app.incomingQueue.hasPending, "Buyer page must bypass app sign-in/viewer queue")
            }
        }
        for host in ["rendprop.com", "www.rendprop.com"] {
            let canonical = URL(string: "https://\(host)/f/published_123-abc?page=gallery#photos")!
            let buyer = URL(string: "https://\(host)/property/published_123-abc?page=gallery#photos")!
            expect(DeepLink.buyerWebsiteURL(from: canonical) == buyer, "Buyer alias preserves the existing token/query/fragment")
            expect(canonical.path == "/f/published_123-abc", "Canonical input remains unchanged")
        }
        for raw in ["https://rendprop.com/u/published", "https://foreign.invalid/f/published",
                    "https://rendprop.com/f/a/b", "https://rendprop.com/f/%2Fbad", "https://rendprop.com/f/a.b", "rendprop://f/published"] {
            expect(DeepLink.buyerWebsiteURL(from: URL(string: raw)!) == nil, "No alias from an unrelated route or invalid token")
        }
        let explicitPort = URL(string: "https://rendprop.com:443/f/owned-fixture")!
        expect(DeepLink.publicWebsiteURL(explicitPort) == explicitPort, "Explicit normal HTTPS port is allowed")
        for raw in ["http://rendprop.com/f/x", "https://untrusted.invalid/f/x", "https://rendprop.com.evil.invalid/f/x",
                    "https://rendprop.com:8443/f/x", "https://name:password@rendprop.com/f/x",
                    "rendprop://f/x", "https://rendprop.com/join/ABCD-EFGH-IJKL", "https://rendprop.com/auth/callback",
                    "https://rendprop.com/private-media/x", "https://rendprop.com/f", "https://rendprop.com/F/x"] {
            expect(DeepLink.publicWebsiteURL(URL(string: raw)!) == nil, "Only approved public HTTPS page routes reach browser")
        }
        for raw in ["https://rendprop.com:8443/f/x", "https://name:password@rendprop.com/f/x"] {
            expect(DeepLink.parse(URL(string: raw)!) == nil, "Malformed public URL cannot fall through to app viewer")
        }
        for raw in ["https://rendprop.com/join/abcd-efgh-ijkl", "rendprop://join/ABCD-EFGH-IJKL"] {
            let app = IncomingWebsiteFixture()
            UIApplication.shared.opened = []
            app.enqueueIncomingURL(URL(string: raw)!)
            expect(UIApplication.shared.opened.isEmpty, "Join must not hand account action to browser")
            expect(app.incomingQueue.takeNext(canPresent: true) == .link(.join(code: "ABCD-EFGH-IJKL")), "Existing invite normalization/routing is retained")
        }
        let custom = IncomingWebsiteFixture()
        UIApplication.shared.opened = []
        custom.enqueueIncomingURL(URL(string: "rendprop://f/owned-fixture")!)
        expect(UIApplication.shared.opened.isEmpty, "Explicit internal tour route remains internal")
        expect(custom.incomingQueue.takeNext(canPresent: true) == .link(.tour(slug: "owned-fixture")), "Internal push/viewer route preserved")
        let invalid = IncomingWebsiteFixture()
        invalid.enqueueIncomingURL(URL(string: "https://rendprop.com/join/not-a-code")!)
        expect(invalid.incomingQueue.takeNext(canPresent: true) == .invalidLink, "Malformed invite retains actionable error")
        let external = IncomingWebsiteFixture()
        UIApplication.shared.opened = []
        external.enqueueIncomingURL(URL(string: "https://untrusted.invalid/f/x")!)
        expect(UIApplication.shared.opened.isEmpty && !external.incomingQueue.hasPending, "Unrelated external host is never reopened or imported")
        print("PUBLIC_WEBSITE_LINK_ASSERTIONS=\(assertions)")
    }
}
