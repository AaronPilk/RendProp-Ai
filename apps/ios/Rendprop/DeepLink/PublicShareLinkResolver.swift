import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Asks the public host for the current branded link of an already-published
/// slug. The host alone can prove that an address path is unique and allowed to
/// be discovered. A failed or malformed lookup keeps the existing token link.
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
                  data.count <= 2048,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object.count == 2,
                  let proof = object["address_only"] as? NSNumber,
                  CFGetTypeID(proof) == CFBooleanGetTypeID(), proof.boolValue,
                  let raw = object["url"] as? String,
                  let verified = URL(string: raw), validAddressOnlyURL(verified) else { return fallbackURL }
            return verified
        } catch {
            return fallbackURL
        }
    }

    private static func publicationSlug(_ url: URL) -> String? {
        guard url.scheme?.lowercased() == "https",
              ["rendprop.com", "www.rendprop.com"].contains((url.host ?? "").lowercased()),
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard (parts.count == 2 && ["f", "property"].contains(parts[0])) ||
                (parts.count == 3 && parts[0] == "property"),
              let slug = parts.last, validSlug(slug) else { return nil }
        return slug
    }

    private static func validAddressOnlyURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.host == "rendprop.com",
              url.user == nil, url.password == nil, url.port == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath == url.path else { return false }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        guard parts.first == "property", parts.count == 2,
              parts[1].range(of: "^[a-z0-9][a-z0-9-]{0,119}$", options: .regularExpression) != nil else { return false }
        return true
    }

    private static func validSlug(_ slug: String) -> Bool {
        slug.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil
    }
}
