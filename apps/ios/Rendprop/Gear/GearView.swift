import SwiftUI

// MARK: - Gear we recommend — the list screen
//
// A plain grouped list, one Section per category, filtered to the current
// SpaceType. Both entry points (Settings' "Legal & support" row, Home's
// `GearHomeLink` below) already check `GearStore.isAvailable` before this view
// is ever pushed, so this file does not re-check it and carries no "the whole
// section is off" state of its own — the only empty state it owns is the rare
// case where the catalog is available overall but every ASIN'd item's `for`
// list names OTHER business types (see `emptyRow`).
//
// AMAZON'S RULES this view is built around (Associates Operating Agreement —
// the full story, and the owner's approval steps, are in docs/GEAR-STORE.md;
// Gear/GearStore.swift's header has the rest of them):
//   • The disclosure sits in its own banner ABOVE the List, outside the
//     scrolling content, so it is on screen before any product regardless of
//     scroll position — never something a scroll can hide.
//   • A row never shows a price, a rating or a stock status — there is no
//     field for one on `GearItem`.
//   • Tapping a row calls `GearStore.open`, which hands the Associates link to
//     `UIApplication.shared` (Safari, or the Amazon app via its universal
//     link) — this file never opens a URL itself and there is no WebView.
struct GearView: View {
    /// Where this screen was opened from — carried only into the `gear_opened`
    /// analytics event (vocabulary: `Analytics/Analytics.swift`; server-side
    /// whitelist: `services/supabase/functions/events/schema.ts`) so the owner
    /// can tell the Settings row from the Home tile apart. Never shown to the
    /// user, and it is the only thing this event carries.
    enum Source: String {
        case settings, home
    }

    let source: Source

    @ObservedObject private var store = GearStore.shared
    @AppStorage("space.type") private var spaceTypeRaw = SpaceType.realEstate.rawValue

    private var currentType: SpaceType { SpaceType(rawValue: spaceTypeRaw) ?? .realEstate }
    private var sections: [GearStore.Section] { store.sections(for: currentType) }

    var body: some View {
        VStack(spacing: 0) {
            disclosureBanner
            List {
                if sections.isEmpty {
                    emptyRow
                } else {
                    ForEach(sections) { section in
                        Section {
                            Text(section.category.why)
                                .font(.rpCaption)
                                .foregroundStyle(Theme.inkDim)
                            ForEach(section.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            Text(section.category.title)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationTitle("Gear we recommend")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            Analytics.track("gear_opened", ["source": source.rawValue])
            await store.refreshIfNeeded()
        }
    }

    // MARK: Disclosure — Amazon Operating Agreement, verbatim, always visible

    private var disclosureBanner: some View {
        Text(store.disclosure)
            .font(.rpCaption)
            .foregroundStyle(Theme.inkDim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.fillSubtle)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 0.5)
            }
    }

    // MARK: One row per item — the whole row is the tap target

    private func itemRow(_ item: GearItem) -> some View {
        Button {
            store.open(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name)
                        .font(.rpBody.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text(item.blurb)
                        .font(.rpCaption)
                        .foregroundStyle(Theme.inkDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Label("Opens Amazon", systemImage: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.inkDim)
                    .fixedSize()
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Empty state — available overall, nothing `for` this business type

    private var emptyRow: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Nothing here yet", systemImage: "bag")
                    .font(.rpHeadline)
                    .foregroundStyle(Theme.ink)
                Text("No gear is listed for this business type yet. Check back later.")
                    .font(.rpCaption)
                    .foregroundStyle(Theme.inkDim)
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Home tile (hook: RendpropApp.swift → HomeDashboardView.body)
//
// Self-contained on purpose: it reads `GearStore.shared` itself and renders
// nothing until `isAvailable`, so the Home hook is the one line that adds this
// view — no state, no parameters, nothing else for HomeDashboardView to own.
//
// Holding the store here is also what makes GearStore's own init comment true
// ("First access is Home's first render"): Home is the first tab drawn on
// launch (RootTabView), so mounting this tile is what starts the catalog's
// first fetch for the launch, and the tile can still turn on later THIS
// launch once that fetch lands.
struct GearHomeLink: View {
    @ObservedObject private var store = GearStore.shared

    var body: some View {
        if store.isAvailable {
            NavigationLink {
                GearView(source: .home)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "bag.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.accent)
                        .frame(width: 42, height: 42)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gear we recommend")
                            .font(.rpHeadline).foregroundStyle(Theme.ink)
                        Text("Gimbals, mics, lights & more for a better walkthrough")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.rpCaption.weight(.bold)).foregroundStyle(Theme.inkDim)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.fillSubtle, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(ScalePressStyle())
        }
    }
}
