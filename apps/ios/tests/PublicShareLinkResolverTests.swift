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
        var checks = 0

        func verify(_ condition: Bool, _ name: String) {
            precondition(condition, name)
            checks += 1
        }

        func response(_ status: Int, _ body: String) -> (Data, URLResponse) {
            (Data(body.utf8), HTTPURLResponse(url: endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }

        let verified = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { request in
            verify(request.url == endpoint && request.cachePolicy == .reloadIgnoringLocalCacheData,
                   "Lookup is keyed by the public slug and bypasses cache")
            return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true}")
        }
        verify(verified == addressOnly, "Unique current address is shared without a token")

        let duplicate = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            response(200, "{\"url\":\"https://rendprop.com/property/a-new-address/published_123-abc\",\"address_only\":false}")
        }
        verify(duplicate == stable, "Duplicate address keeps the exact existing token URL")

        let noindex = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            response(200, "{\"url\":\"https://rendprop.com/property/current-server-address/published_123-abc\",\"address_only\":false}")
        }
        verify(noindex == stable, "Noindex listing keeps the exact existing token URL")

        for (status, body, name) in [
            (404, "{\"error\":\"not_found\"}", "Withdrawn publication"),
            (503, "{\"error\":\"unavailable\"}", "Lookup outage"),
            (200, "{\"url\":\"https://evil.example/property/855-central-ave\",\"address_only\":true}", "Foreign host"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave/other-token\",\"address_only\":true}", "Token URL posing as an address-only URL"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave?preview=1\",\"address_only\":true}", "Query-bearing response"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true,\"extra\":true}", "Extra response field"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":false}", "Unproved address-only response"),
            (200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":1}", "Numeric proof"),
            (200, "{broken", "Malformed response"),
        ] {
            let result = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
                response(status, body)
            }
            verify(result == stable, "\(name) keeps the stable token URL")
        }

        enum Offline: Error { case unreachable }
        let offline = await PublicShareLinkResolver.resolve(publishedURL: published, fallbackURL: stable) { _ in
            throw Offline.unreachable
        }
        verify(offline == stable, "Transport failure keeps the stable token URL")

        var fetched = false
        let invalidSource = await PublicShareLinkResolver.resolve(
            publishedURL: URL(string: "https://evil.example/f/published_123-abc")!, fallbackURL: stable) { _ in
                fetched = true
                return response(200, "{\"url\":\"https://rendprop.com/property/855-central-ave\",\"address_only\":true}")
            }
        verify(invalidSource == stable && !fetched, "An untrusted source cannot trigger the lookup")
        print("Public share link resolver: \(checks) protocol and fallback checks passed")
    }
}
