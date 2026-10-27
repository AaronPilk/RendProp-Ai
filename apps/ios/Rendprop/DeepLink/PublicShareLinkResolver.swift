import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asks the public host for the current branded link of an already-published
/// slug. The host alone can prove whether a bare address is claimed or a dated
/// address link belongs to this publication. A failed or malformed lookup keeps
/// the existing token link.
enum PublicShareLinkResolver {
    /// A tap never waits for the lookup. Until a verified address link arrives,
    /// the already-published token link is immediately usable. A result from a
    /// previous listing/account key can never be used by a new presentation.
    static func linkForAction(fallbackURL: URL, linkKey: String, currentContext: Bool,
                              cached: (key: String, url: URL)?) -> URL? {
        guard currentContext else { return nil }
        return cached?.key == linkKey ? cached?.url ?? fallbackURL : fallbackURL
    }

    static func resolve(publishedURL: URL, fallbackURL: URL) async -> URL {
        await resolve(publishedURL: publishedURL, fallbackURL: fallbackURL) { request in
            try await URLSession.shared.data(for: request)
        }
    }

    /// Injected transport keeps the protocol and its failure paths testable
    /// without a live customer publication or a production request.
    static func resolve(
        publishedURL: URL,
        fallbackURL: URL,
        fetch: (URLRequest) async throws -> (Data, URLResponse)
    ) async -> URL {
        guard let slug = publicationSlug(publishedURL),
              let endpoint = URL(string: "https://rendprop.com/f/\(slug)/share-link") else { return fallbackURL }
        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url == endpoint,
                  data.count <= 2048,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object.count == 2,
                  let proof = object["address_only"] as? NSNumber,
                  CFGetTypeID(proof) == CFBooleanGetTypeID(),
                  let raw = object["url"] as? String,
                  let verified = URL(string: raw),
                  proof.boolValue ? validAddressOnlyURL(verified) : validDatedAddressURL(verified, slug: slug)
            else { return fallbackURL }
            return verified
        } catch {
            return fallbackURL
        }
    }

    private static func publicationSlug(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              ["rendprop.com", "www.rendprop.com"].contains((url.host ?? "").lowercased()),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == url.path else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.first == "" else { return nil }
        if parts.count == 3, ["f", "property"].contains(parts[1]), validSlug(parts[2]) {
            return parts[2]
        }
        if parts.count == 4, parts[1] == "property", validAddressPart(parts[2]) {
            let tail = parts[3]
            if validSlug(tail) { return tail } // Legacy address + token URL.
            let dated = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if dated.count == 2, validDatePart(dated[0]), validSlug(dated[1]) {
                return dated[1]
            }
        }
        return nil
    }

    private static func validAddressOnlyURL(_ url: URL) -> Bool {
        guard validBrandedResponseURL(url) else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return parts.count == 3 && parts[0] == "" && parts[1] == "property" && validAddressPart(parts[2])
    }

    private static func validDatedAddressURL(_ url: URL, slug: String) -> Bool {
        guard validBrandedResponseURL(url) else { return false }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4, parts[0] == "", parts[1] == "property", validAddressPart(parts[2]) else { return false }
        let dated = parts[3].split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return dated.count == 2 && validDatePart(dated[0]) && dated[1] == slug
    }

    private static func validBrandedResponseURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "rendprop.com",
              url.user == nil, url.password == nil, url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == url.path else { return false }
        return url.absoluteString == "https://rendprop.com\(url.path)"
    }

    private static func validAddressPart(_ address: String) -> Bool {
        address.range(of: "^[a-z0-9](?:[a-z0-9-]{0,118}[a-z0-9])?$", options: .regularExpression) != nil
    }

    private static func validDatePart(_ date: String) -> Bool {
        date.range(of: "^[0-9]{8}$", options: .regularExpression) != nil
    }

    private static func validSlug(_ slug: String) -> Bool {
        slug.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }
}
