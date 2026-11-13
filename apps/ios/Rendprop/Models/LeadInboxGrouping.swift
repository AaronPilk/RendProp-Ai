import Foundation

enum LeadInboxFilter: Hashable {
    case all, listing(UUID), unassigned

    func includes(_ lead: Lead) -> Bool {
        switch self {
        case .all: return true
        case .listing(let id): return lead.listingID == id
        case .unassigned: return lead.listingID == nil
        }
    }
}

struct LeadInboxSection: Identifiable {
    let listingID: UUID?
    let title: String
    let leads: [Lead]
    var id: String { listingID?.uuidString ?? "unassigned" }
    var filter: LeadInboxFilter { listingID.map(LeadInboxFilter.listing) ?? .unassigned }
}

/// The API already scopes inquiries to the authenticated account and library.
/// Only visible local listings may supply labels; an unknown listing keeps its
/// server-provided address and is never matched to another member's metadata.
enum LeadInboxGrouping {
    static func visibleListings(_ listings: [Listing], canView: (Listing) -> Bool) -> [Listing] {
        listings.filter { !$0.isSample && canView($0) }
    }

    static func current<Context: Equatable>(_ leads: [Lead], responseContext: Context?,
                                            currentContext: Context) -> [Lead] {
        responseContext == currentContext ? leads : []
    }

    static func sections(_ leads: [Lead], listings: [Listing], includeEmpty: Bool = false) -> [LeadInboxSection] {
        var groups = Dictionary(grouping: leads, by: \.listingID)
        if includeEmpty {
            for listing in listings {
                if let id = listing.serverID, groups[id] == nil { groups[id] = [] }
            }
        }
        return groups.map { id, values in
            let sorted = values.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            }
            let localAddress = id.flatMap { key in listings.first { $0.serverID == key }?.address }
            let recordedAddress = sorted.compactMap(\.listingAddress).first {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let address = [localAddress, recordedAddress].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return LeadInboxSection(listingID: id,
                                    title: address ?? (id == nil ? "Other inquiries" : "Listing unavailable"),
                                    leads: sorted)
        }.sorted {
            let left = $0.leads.first?.createdAt ?? .distantPast
            let right = $1.leads.first?.createdAt ?? .distantPast
            if left != right { return left > right }
            return $0.title == $1.title ? $0.id < $1.id : $0.title < $1.title
        }
    }
}
