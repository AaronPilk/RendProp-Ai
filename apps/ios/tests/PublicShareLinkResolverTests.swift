import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct PublicShareLinkResolverTests {
    static func main() async {
        let published = URL(string: "https://rendprop.com/f/published_123-abc")!
        let stable = URL(string: "https://rendprop.com/property/855-central-ave/published_123-abc")!
        let endpoint = URL(string: "https://rendprop.com/f/published_123-abc/share-link")!
        let addressOnly = URL(string: "https://rendprop.com/property/855-central-ave")!
        let dated = URL(string: "https://rendprop.com/property/855-central-ave/20261022.published_123-abc")!
        var checks = 0

        func verify(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            checks += 1
        }

        func response(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-a:listing-a", currentContext: true,
            cached: nil) == stable, "A tap can immediately share the published link during lookup")
        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-a:listing-a", currentContext: true,
            cached: ("account-a:listing-a", addressOnly)) == addressOnly,
            "A completed proof supplies the address-only link without another request")
        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-a:listing-a", currentContext: true,
            cached: ("account-a:listing-a", dated)) == dated,
            "A completed dated proof supplies the collision-safe branded link")
        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-b:listing-b", currentContext: true,
            cached: ("account-a:listing-a", addressOnly)) == stable,
            "An older listing's resolved address never carries into a new link")
        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-b:listing-b", currentContext: false,
            cached: ("account-b:listing-b", addressOnly)) == nil,
            "A changed account or workspace cannot use either cached or fallback link")
        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-a:listing-a", currentContext: true,
            cached: ("account-a:listing-a", dated), withdrawnKey: "account-a:listing-a") == nil,
            "A withdrawn publication cannot be shared even when its branded URL was cached")
        verify(PublicShareLinkResolver.linkForAction(
            fallbackURL: stable, linkKey: "account-b:listing-b", currentContext: true,
            cached: nil, withdrawnKey: "account-a:listing-a") == stable,
            "A withdrawn result for an old context cannot block a different publication")

        let verified = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { request in
            verify(request.url == endpoint && request.cachePolicy == .reloadIgnoringLocalCacheData,
                   "Lookup is keyed by the public slug and bypasses cache")
            return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true}")
        }
        verify(verified == .available(addressOnly), "Unique current address is shared without a token")

        let datedResult = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}")
        }
        verify(datedResult == .available(dated), "A dated address link for this exact published slug is shared")

        let redirected = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            (Data("{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}".utf8),
             HTTPURLResponse(url: URL(string: "https://other.example/share-link")!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        verify(redirected == .available(stable), "A redirected responder cannot assert ownership of a branded link")

        let redirectedNotFound = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            (Data("{\"error\":\"not_found\"}".utf8),
             HTTPURLResponse(url: URL(string: "https://other.example/share-link")!, statusCode: 404, httpVersion: nil, headerFields: nil)!)
        }
        verify(redirectedNotFound == .available(stable), "A redirected 404 cannot revoke this publication")

        let datedSource = await PublicShareLinkResolver.resolve(publishedURL: dated, fallbackURL: stable) { request in
            verify(request.url == endpoint, "A dated published URL still looks up its original publication slug")
            return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}")
        }
        verify(datedSource == .available(dated), "A dated canonical source can resolve its branded share URL")

        let legacySource = await PublicShareLinkResolver.resolve(publishedURL: stable, fallbackURL: stable) { request in
            verify(request.url == endpoint, "A legacy property token still looks up the same publication slug")
            return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}")
        }
        verify(legacySource == .available(dated), "A legacy property token can resolve its dated canonical URL")

        let duplicate = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            response(200, "{\"url\":\"https://rendprop.com/property/a-new-address/published_123-abc\",\"address_only\":false}")
        }
        verify(duplicate == .available(URL(string: "https://rendprop.com/property/a-new-address/published_123-abc")!),
               "A server-authoritative undated link keeps the same publication token")

        let noindex = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            response(200, "{\"url\":\"https://rendprop.com/property/current-server-address/published_123-abc\",\"address_only\":false}")
        }
        verify(noindex == .available(URL(string: "https://rendprop.com/property/current-server-address/published_123-abc")!),
               "A noindex listing can use the server's undated address-and-token link")

        for status in [404, 410] {
            let revoked = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
                response(status, "{\"error\":\"not_found\"}")
            }
            verify(revoked == .withdrawn, "A direct \(status) stops distribution of a withdrawn publication")
        }

        for (status, body, name) in [
            (503, "{\"error\":\"unavailable\"}", "Lookup outage"),
            (200, "{\"url\":\"https://evil.example/property/855-central-ave\",\"address_only\":true}", "Foreign host"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/other-token\",\"address_only\":true}", "Token URL posing as an address-only URL"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave?preview=1\",\"address_only\":true}", "Query-bearing response"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true,\"extra\":true}", "Extra response field"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":false}", "Unproved address-only response"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":1}", "Numeric proof"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.other-slug\",\"address_only\":false}", "Different publication slug"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/other-slug\",\"address_only\":false}", "Different undated publication slug"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/published_123-abc/extra\",\"address_only\":false}", "Extra undated path"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave-/published_123-abc\",\"address_only\":false}", "Malformed undated descriptor"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/published_123-abc?preview=1\",\"address_only\":false}", "Undated query"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/2026102.published_123-abc\",\"address_only\":false}", "Malformed publication date"),
            (200, "{\"url\":\"https://rendprop.com/f/published_123-abc\",\"address_only\":false}", "Token route posing as dated address"),
            (200, "{\"url\":\"https://evil.example/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}", "Foreign dated host"),
            (200, "{\"url\":\"http://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}", "Insecure dated scheme"),
            (200, "{\"url\":\"https://rendprop.com:443/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}", "Explicit dated port"),
            (200, "{\"url\":\"https://user@rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false}", "Dated userinfo"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc?preview=1\",\"address_only\":false}", "Dated query"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc#fragment\",\"address_only\":false}", "Dated fragment"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/%32%30%32%36%31%30%32%32.published_123-abc\",\"address_only\":false}", "Encoded dated path"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave//20261022.published_123-abc\",\"address_only\":false}", "Repeated dated separator"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave-/20261022.published_123-abc\",\"address_only\":false}", "Invalid dated descriptor"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":true}", "Dated URL posing as bare address"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/20261022.published_123-abc\",\"address_only\":false,\"extra\":true}", "Extra dated response field"),
            (200, "{broken", "Malformed response"),
        ] {
            let result = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
                response(status, body)
            }
            verify(result == .available(stable), "\(name) keeps the stable token URL")
        }

        enum Offline: Error { case unreachable }
        let offline = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            throw Offline.unreachable
        }
        verify(offline == .available(stable), "Transport failure keeps the stable token URL")

        var fetched = false
        let invalidSource = await PublicShareLinkResolver.resolve(
            publishedURL: URL(string: "https://evil.example/f/published_123-abc")!, fallbackURL: stable) { _ in
                fetched = true
                return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true}")
            }
        verify(invalidSource == .available(stable) && !fetched, "An untrusted source cannot trigger the lookup")
        for (source, name) in [
            ("https://rendprop.com/property/855-central-ave/20261022.other-slug?preview=1", "Queried source"),
            ("https://rendprop.com/property/855-central-ave/20261022.other-slug/extra", "Extra source path"),
            ("https://rendprop.com/property/855-central-ave-/20261022.other-slug", "Invalid source descriptor"),
            ("https://rendprop.com/property/855-central-ave/2026102.other-slug", "Invalid dated source"),
        ] {
            fetched = false
            let result = await PublicShareLinkResolver.resolve(publishedURL: URL(string: source)!, fallbackURL: stable) { _ in
                fetched = true
                return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true}")
            }
            verify(result == .available(stable) && !fetched, "\(name) cannot trigger the lookup")
        }
        print("Public share link resolver: \(checks) protocol and fallback checks passed")
    }
}
