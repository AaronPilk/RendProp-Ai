import Foundation

// Paste a listing link, get the address filled in.
//
// THE ASK: "when adding a new home the first option should be zillow link so it
// pulls all the data — if it's not on zillow then they can choose to add the
// address and add the home normally like we have it now."
//
// WHAT THIS DOES AND WHAT IT DELIBERATELY DOES NOT.
//
// It reads the address out of the URL STRING the agent pasted. Nothing is
// fetched. No request reaches Zillow, Redfin or Realtor, no page is downloaded,
// nothing is copied. A listing URL simply carries the address in its own path —
// `/homedetails/1401-45th-Ave-N-Saint-Petersburg-FL-33703/47212345_zpid/` — and
// parsing text somebody handed us is not scraping.
//
// That distinction is the whole design. Zillow's Terms of Use §5 prohibits
// automated queries, and listing PHOTOS belong to the photographer or the MLS,
// not to the portal and not to the agent — VHT v. Zillow was that exact fact
// pattern. Since these tours republish on rendprop.com, an automated pull would
// put the exposure on this company. So beds, baths, sqft, price and photos are
// NOT guessed and NOT fetched: they stay empty, and the screen says why.
//
// The owner's decision, in his words: "we will wire MLS API when we have our
// license and have our own API code from zillow." When those credentials land,
// a licensed provider fills the rest of `Parsed` and this file does not change
// — which is why `source` exists and why the parse and the fetch are separate
// ideas from the first commit.
//
// THE REAL WIN IS SMALLER THAN IT SOUNDS AND BIGGER THAN IT LOOKS: nobody minds
// typing "4 beds". They mind typing a full street address on a phone, standing
// in a driveway, before they can press Record.

struct ListingLink: Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case zillow, redfin, realtor
        var label: String {
            switch self {
            case .zillow:  return "Zillow"
            case .redfin:  return "Redfin"
            case .realtor: return "Realtor.com"
            }
        }
    }

    /// Street line only — "1401 45th Ave N".
    var street: String
    var city: String
    var state: String
    var zip: String
    var source: Source

    /// The one line the address field wants.
    var formatted: String {
        var out = street
        if !city.isEmpty { out += ", \(city)" }
        if !state.isEmpty { out += ", \(state)" }
        if !zip.isEmpty { out += " \(zip)" }
        return out
    }

    // MARK: - Parsing

    /// Street-type tokens, which is how a slug's street is told from its city.
    /// "1401-45th-Ave-N-Saint-Petersburg-FL-33703" has no other marker: both
    /// halves are just words.
    ///
    /// THE LAST street type wins, and that choice has a known cost. Neither
    /// rule is universally right, because a street-type word can appear on
    /// either side:
    ///
    ///   "100-Court-St-Boston-MA"      last wins  -> "100 Court St" / "Boston"  ✓
    ///                                 first wins -> "100 Court" / "St Boston"  ✗
    ///   "12-Maple-St-Court-House-VA"  last wins  -> "12 Maple St Court" / "House" ✗
    ///                                 first wins -> "12 Maple St" / "Court House" ✓
    ///
    /// A street named after a street type ("Court St", "Park Way") is ordinary;
    /// a CITY named after one ("Court House, VA") is rare. So last-wins is the
    /// better default and the rare case is accepted as wrong rather than papered
    /// over with a city list this app has no business shipping.
    ///
    /// What makes that acceptable is where the answer lands: in the ADDRESS
    /// FIELD, on screen, editable, before the agent presses anything. A parse
    /// this gets wrong is one they can see and fix in two taps — which is why
    /// the result fills a visible field instead of being saved silently.
    private static let streetTypes: Set<String> = [
        "st", "street", "ave", "avenue", "rd", "road", "dr", "drive", "ln", "lane",
        "blvd", "boulevard", "ct", "court", "pl", "place", "ter", "terrace",
        "way", "cir", "circle", "pkwy", "parkway", "hwy", "highway", "trl", "trail",
        "loop", "run", "pass", "path", "row", "walk", "bnd", "bend", "xing", "crossing",
        "sq", "square", "aly", "alley", "plz", "plaza", "pt", "point", "ridge", "rdg",
    ]

    /// Directionals that legitimately follow the street type ("45th Ave N").
    private static let directionals: Set<String> = [
        "n", "s", "e", "w", "ne", "nw", "se", "sw",
        "north", "south", "east", "west",
        "northeast", "northwest", "southeast", "southwest",
    ]

    /// Parse whatever the agent pasted. nil when it is not a listing link this
    /// build understands, or when the address cannot be read with confidence —
    /// and nil is a fine answer, because the manual field is right underneath.
    /// Guessing a wrong address onto a real listing is worse than typing one.
    static func parse(_ raw: String) -> ListingLink? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 2048 else { return nil }
        // Accept a bare "zillow.com/..." paste as well as a full URL.
        let candidate = text.lowercased().hasPrefix("http") ? text : "https://\(text)"
        guard let url = URL(string: candidate), let host = url.host?.lowercased() else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }

        if host.contains("zillow.") { return parseZillow(parts) }
        if host.contains("redfin.") { return parseRedfin(parts) }
        if host.contains("realtor.") { return parseRealtor(parts) }
        return nil
    }

    /// zillow.com/homedetails/<street-city-ST-ZIP>/<zpid>_zpid/
    private static func parseZillow(_ parts: [String]) -> ListingLink? {
        guard let slug = parts.first(where: { $0.contains("-") && $0.count > 8 && !$0.hasSuffix("_zpid") })
        else { return nil }
        return fromHyphenSlug(slug, source: .zillow)
    }

    /// redfin.com/<ST>/<City>/<street-ZIP>/home/<id> — the state and city are
    /// their own path components here, so only the street needs teasing apart.
    private static func parseRedfin(_ parts: [String]) -> ListingLink? {
        guard parts.count >= 3 else { return nil }
        let state = parts[0].uppercased()
        guard state.count == 2, state.allSatisfy({ $0.isLetter }) else { return nil }
        let city = titleCase(parts[1].replacingOccurrences(of: "-", with: " "))
        var tokens = parts[2].split(separator: "-").map(String.init)
        var zip = ""
        if let last = tokens.last, last.count == 5, last.allSatisfy({ $0.isNumber }) {
            zip = last; tokens.removeLast()
        }
        let street = titleCase(tokens.joined(separator: " "))
        guard !street.isEmpty, street.rangeOfCharacter(from: .letters) != nil else { return nil }
        return ListingLink(street: street, city: city, state: state, zip: zip, source: .redfin)
    }

    /// realtor.com/realestateandhomes-detail/<Street>_<City>_<ST>_<ZIP>_M...
    /// Underscore-separated, so this one is unambiguous and needs no heuristic.
    private static func parseRealtor(_ parts: [String]) -> ListingLink? {
        guard let slug = parts.first(where: { $0.contains("_") }) else { return nil }
        let f = slug.split(separator: "_").map(String.init)
        guard f.count >= 4 else { return nil }
        let street = titleCase(f[0].replacingOccurrences(of: "-", with: " "))
        let city = titleCase(f[1].replacingOccurrences(of: "-", with: " "))
        let state = f[2].uppercased()
        let zip = f[3].allSatisfy({ $0.isNumber }) ? f[3] : ""
        guard state.count == 2, !street.isEmpty else { return nil }
        return ListingLink(street: street, city: city, state: state, zip: zip, source: .realtor)
    }

    /// The shared shape: `<street>-<city>-<ST>-<ZIP>`, all hyphens, no other
    /// separator. Read from the RIGHT, because that end is unambiguous: a
    /// trailing 5-digit group is the ZIP, a 2-letter group before it is the
    /// state, and what remains splits at the last street-type token.
    private static func fromHyphenSlug(_ slug: String, source: Source) -> ListingLink? {
        var tokens = slug.split(separator: "-").map(String.init)
        guard tokens.count >= 4 else { return nil }
        // A real address slug opens with the house number. Requiring it is what
        // makes junk fail CLOSED: "no-street-type-here-FL-33703" otherwise
        // parses, because "street" is itself a street-type token, and hands
        // back "no street" as an address.
        guard let first = tokens.first, first.first?.isNumber == true else { return nil }

        var zip = ""
        if let last = tokens.last, last.count == 5, last.allSatisfy({ $0.isNumber }) {
            zip = last; tokens.removeLast()
        }
        var state = ""
        if let last = tokens.last, last.count == 2, last.allSatisfy({ $0.isLetter }) {
            state = last.uppercased(); tokens.removeLast()
        }
        guard !state.isEmpty, tokens.count >= 2 else { return nil }

        // The last street type, plus a directional if one follows it.
        var cut = -1
        for (i, t) in tokens.enumerated() where streetTypes.contains(t.lowercased()) { cut = i }
        guard cut >= 0 else { return nil }
        if cut + 1 < tokens.count, directionals.contains(tokens[cut + 1].lowercased()) { cut += 1 }
        guard cut < tokens.count - 1 else { return nil }   // nothing left for a city

        let street = titleCase(tokens[0...cut].joined(separator: " "))
        let city = titleCase(tokens[(cut + 1)...].joined(separator: " "))
        guard !street.isEmpty, !city.isEmpty else { return nil }
        return ListingLink(street: street, city: city, state: state, zip: zip, source: source)
    }

    /// "saint petersburg" -> "Saint Petersburg", leaving "45th" and a
    /// single-letter directional alone. `.capitalized` would give "45Th".
    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ").map { word -> String in
            let w = String(word)
            if w.count <= 2, directionals.contains(w.lowercased()) { return w.uppercased() }
            if w.first?.isNumber == true { return w.lowercased() }        // 1401, 45th
            return w.prefix(1).uppercased() + w.dropFirst().lowercased()
        }.joined(separator: " ")
    }
}
