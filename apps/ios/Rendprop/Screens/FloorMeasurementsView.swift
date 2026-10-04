import SwiftUI
import UIKit
import SceneKit

/// A plan drawn from the user's dimensions. It is separate from the RoomPlan
/// archive, so measuring a furnished room never replaces a saved phone scan.
struct FloorMeasurementsView: View {
    let listing: Listing
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var auth = AuthStore.shared
    @State private var plan: FloorMeasurementPlan
    @State private var floor = 0
    @State private var roomEditor: MeasurementRoomEditor?
    @State private var outlineEditor: MeasurementOutlineEditor?
    @State private var export: MeasurementExport?
    @State private var show3D = false
    @State private var error: String?
    @State private var ownerAtOpen: String?
    @State private var revisionAtOpen: UInt64 = 0
    @State private var workspaceAtOpen: UUID?
    @State private var didOpen = false
    @State private var confirmPhoneDetails = false

    init(listing: Listing) {
        self.listing = listing
        _plan = State(initialValue: listing.floorMeasurements ?? FloorMeasurementPlan())
    }

    private var rooms: [FloorMeasurementRoom] { plan.rooms.filter { $0.floor == floor } }
    private var outlines: [FloorMeasurementOutline] { plan.outlines.filter { $0.floor == floor } }
    private var floors: [Int] { Array(Set(plan.rooms.map(\.floor) + plan.outlines.map(\.floor) + [floor])).sorted() }
    private var hasFloorGeometry: Bool { !rooms.isEmpty || !outlines.isEmpty }
    private var unsupported: Bool {
        let current = model.listings.first(where: { $0.id == listing.id }) ?? listing
        return current.floorMeasurements == nil && FloorMeasurementPlan.hasUnreadableValue(in: current.details)
    }
    private var currentContext: Bool {
        didOpen && auth.userID == ownerAtOpen && auth.syncSessionRevision == revisionAtOpen &&
        WorkspaceContext.selectedOrgID == workspaceAtOpen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introduction
                if model.listings.first(where: { $0.id == listing.id })?.measurementSync?.factsReviewRequired == true {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Review older saved edits").font(.rpHeadline)
                        Text("Your measurements are kept on this iPhone. Choose which listing details to keep before older changes sync.")
                            .font(.rpBody).foregroundStyle(Theme.inkDim)
                        Button("Use shared listing details") {
                            Task {
                                do {
                                    guard currentContext else { throw CloudSyncError.identityChanged }
                                    try await model.reloadSharedMeasurements(listing.id, includeListingDetails: true)
                                    plan = model.listings.first(where: { $0.id == listing.id })?.floorMeasurements ?? FloorMeasurementPlan()
                                    error = nil
                                } catch { self.error = error.localizedDescription }
                            }
                        }.accessibilityIdentifier("measurements.useSharedDetails")
                        Button("Use this iPhone's listing details") { confirmPhoneDetails = true }
                            .accessibilityIdentifier("measurements.usePhoneDetails")
                    }.padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                }
                if let current = model.listings.first(where: { $0.id == listing.id }), current.measurementSync?.conflict == true {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(FloorMeasurementSyncError.conflict.localizedDescription).font(.rpBody).foregroundStyle(Theme.warn)
                        Button("Load shared measurements") {
                            Task {
                                do {
                                    try await model.reloadSharedMeasurements(listing.id)
                                    plan = model.listings.first(where: { $0.id == listing.id })?.floorMeasurements ?? FloorMeasurementPlan()
                                    error = nil
                                } catch { self.error = error.localizedDescription }
                            }
                        }.accessibilityIdentifier("measurements.reloadShared")
                        Text("Your local version is kept on this iPhone. You can restore it after loading the shared version.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }.padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                } else if let backup = model.listings.first(where: { $0.id == listing.id })?.measurementSync?.savedLocalCopy,
                          let saved = FloorMeasurementPlan.decodeWireValue(backup) {
                    Button("Restore my saved local measurements") {
                        do { try persist(saved) } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("measurements.restoreLocal")
                }
                if unsupported {
                    Text("This listing has measurements in a format this version cannot open. Update the app before editing them.")
                        .font(.rpBody).foregroundStyle(Theme.warn)
                        .padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                } else {
                    settings
                    outlineLayout
                    outlineList
                    Button { addOutline() } label: {
                        Label("Draw a floor outline", systemImage: "pencil.and.outline")
                            .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(15)
                            .background(plan.outlines.count < FloorMeasurementPlan.maximumOutlines ? Theme.accent : Theme.disabledFill)
                            .foregroundStyle(plan.outlines.count < FloorMeasurementPlan.maximumOutlines ? Color.white : Theme.disabledInk)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }.disabled(plan.outlines.count >= FloorMeasurementPlan.maximumOutlines)
                        .accessibilityIdentifier("measurements.addOutline")
                    if !rooms.isEmpty { layout }
                    roomList
                    Button { addRoom() } label: {
                        Label("Add a room", systemImage: "plus")
                            .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(15)
                            .background(plan.rooms.count < 24 ? Theme.accent : Theme.disabledFill)
                            .foregroundStyle(plan.rooms.count < 24 ? Color.white : Theme.disabledInk)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(plan.rooms.count >= 24)
                    .accessibilityIdentifier("measurements.addRoom")
                    if hasFloorGeometry { outputActions }
                }
                if let error {
                    Text(error).font(.rpBody).foregroundStyle(Theme.warn)
                        .accessibilityIdentifier("measurements.error")
                }
                Text(FloorMeasurementProvenance.disclosure)
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    .accessibilityIdentifier("measurements.sourceDisclosure")
                Text("Measurements are saved on this iPhone and sync to the selected workspace. Conflicting edits stay on this phone until you choose the shared version.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.padding()
        }
        .background(Theme.bg)
        .navigationTitle("Measurements")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard !didOpen else { return }
            didOpen = true; ownerAtOpen = auth.userID
            revisionAtOpen = auth.syncSessionRevision; workspaceAtOpen = WorkspaceContext.selectedOrgID
            floor = plan.outlines.first?.floor ?? plan.rooms.first?.floor ?? 0
        }
        .sheet(item: $outlineEditor) { item in
            MeasurementOutlineForm(outline: item.outline, unit: plan.unit,
                                   otherOutlines: plan.outlines.filter { $0.id != item.outline.id },
                                   isNew: item.isNew) { outline in
                var changed = plan
                if let index = changed.outlines.firstIndex(where: { $0.id == outline.id }) {
                    changed.outlines[index] = outline
                } else { changed.outlines.append(outline) }
                changed.version = 2
                try persist(changed); floor = outline.floor; outlineEditor = nil
            } onDelete: {
                var changed = plan
                changed.outlines.removeAll { $0.id == item.outline.id || $0.deductionFromID == item.outline.id }
                try persist(changed); outlineEditor = nil
            }
        }
        .sheet(item: $roomEditor) { item in
            MeasurementRoomForm(room: item.room, unit: plan.unit,
                                otherRooms: plan.rooms.filter { $0.floor == item.room.floor && $0.id != item.room.id },
                                isNew: item.isNew) { room in
                var changed = plan
                if let index = changed.rooms.firstIndex(where: { $0.id == room.id }) {
                    changed.rooms[index] = room
                } else { changed.rooms.append(room) }
                try persist(changed)
                roomEditor = nil
            } onDelete: {
                var changed = plan; changed.rooms.removeAll { $0.id == item.room.id }
                try persist(changed); roomEditor = nil
            }
        }
        .sheet(item: $export) { item in
            PlanExportSheet(image: item.image, address: listing.address,
                            disclosure: FloorMeasurementProvenance.disclosure,
                            additionalFile: item.pdfURL, canExport: { isFresh(item.plan) && isFresh(plan) })
        }
        .sheet(isPresented: $show3D) {
            NavigationStack {
                VStack(spacing: 14) {
                    MeasurementModelView(rooms: rooms, outlines: outlines)
                    Text("Shapes from your entered dimensions. Unentered heights use 2.4 m for this preview; doors, windows and wall thickness are not inferred.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim).padding()
                }.background(Theme.bg)
                    .navigationTitle("3D measurement layout")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { show3D = false } } }
            }
        }
        .onChange(of: auth.syncSessionRevision) { _ in invalidateContext() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in invalidateContext() }
        .alert("Replace the shared listing details?", isPresented: $confirmPhoneDetails) {
            Button("Cancel", role: .cancel) {}
            Button("Use iPhone details") {
                do {
                    guard currentContext else { throw CloudSyncError.identityChanged }
                    try model.confirmLocalListingDetails(listing.id)
                } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("This saves this iPhone's address, price, square footage and other listing details over the shared version. Measurement conflicts must be resolved first.")
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Turn measurements into a floor plan", systemImage: "ruler")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Draw the outside of a floor by entering each wall's length and direction. Add a garage, porch or opening separately. For a quick room layout, enter length and width instead.")
                .font(.rpBody).foregroundStyle(Theme.inkDim)
            Text("Works with furnished rooms and on phones without LiDAR.")
                .font(.rpCaption).foregroundStyle(Theme.accent)
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var settings: some View {
        VStack(spacing: 12) {
            Picker("Measurement units", selection: Binding(get: { plan.unit }, set: { unit in
                var changed = plan; changed.unit = unit
                do { try persist(changed) } catch { self.error = error.localizedDescription }
            })) {
                Text("Feet & inches").tag(FloorMeasurementUnit.feet)
                Text("Metres").tag(FloorMeasurementUnit.meters)
            }.pickerStyle(.segmented).accessibilityIdentifier("measurements.units")
            HStack {
                Menu {
                    ForEach(floors, id: \.self) { value in
                        Button(floorLabel(value)) { floor = value }
                    }
                    if (floors.max() ?? 0) < 20 {
                        Button("Add next floor") { floor = (floors.max() ?? 0) + 1 }
                    }
                    if !floors.contains(-1) { Button("Add basement") { floor = -1 } }
                } label: { Label(floorLabel(floor), systemImage: "square.3.layers.3d") }
                Spacer()
                Text("\(outlines.count) outline\(outlines.count == 1 ? "" : "s") · \(rooms.count) room\(rooms.count == 1 ? "" : "s")").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
        }
    }

    @ViewBuilder private var outlineLayout: some View {
        if !outlines.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Floor outlines").font(.rpHeadline).foregroundStyle(Theme.ink)
                Text("Wall lengths stay in your chosen units. Tap an outline below to edit it.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                FloorMeasurementDrawing(plan: plan, floor: floor, showWallLengths: true)
                    .frame(height: 320).background(Theme.fillSubtle)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityIdentifier("measurements.outlineLayout")
            }.padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
        }
    }

    private var outlineList: some View {
        VStack(spacing: 0) {
            ForEach(outlines) { outline in
                Button { outlineEditor = MeasurementOutlineEditor(outline: outline, isNew: false) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: outline.category == .openBelow ? "square.dashed" : "pentagon")
                            .foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(outline.name).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text("\(outline.category.label) · \(areaText(outline.areaMeters2))")
                                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                            if outline.closingWallCalculated {
                                Text("Calculated closing wall — verify").font(.rpCaption).foregroundStyle(Theme.warn)
                            }
                            if outline.source == .phoneEstimate {
                                Text("Includes phone estimates").font(.rpCaption).foregroundStyle(Theme.warn)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkDim)
                    }.padding(14)
                }.accessibilityIdentifier("measurements.outline.\(outline.id.uuidString)")
                if outline.id != outlines.last?.id { Divider().padding(.horizontal, 14) }
            }
        }.background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var layout: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Arrange your rooms").font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Drag a room into place. Tap it to change its measurements. Edges snap together; rooms cannot overlap.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            MeasurementPlanDiagram(rooms: rooms, unit: plan.unit, onSelect: { room in
                roomEditor = MeasurementRoomEditor(room: room, isNew: false)
            }, onMove: moveRoom)
            .frame(height: 320).background(Theme.fillSubtle)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("measurements.layout")
        }.padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var roomList: some View {
        VStack(spacing: 0) {
            ForEach(rooms) { room in
                Button { roomEditor = MeasurementRoomEditor(room: room, isNew: false) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "square.dashed").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(room.name).font(.rpBody.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(room.displayDimensions(unit: plan.unit)).font(.rpCaption).foregroundStyle(Theme.inkDim)
                        }
                        Spacer()
                        Text(room.source == .phoneEstimate ? "Phone estimate" : "Entered")
                            .font(.caption2).foregroundStyle(Theme.inkDim)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkDim)
                    }.padding(14)
                }.accessibilityIdentifier("measurements.room.\(room.id.uuidString)")
                if room.id != rooms.last?.id { Divider().padding(.horizontal, 14) }
            }
        }.background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
    }

    private var outputActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            FloorMeasurementWorksheetView(plan: plan, floor: floor)
                .accessibilityIdentifier("measurements.worksheet")
            Button { makeExport() } label: {
                Label("Download plan · image or PDF", systemImage: "square.and.arrow.down")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }.accessibilityIdentifier("measurements.export").disabled(!isFresh(plan))
            Button { show3D = true } label: {
                Label("View measurement layout in 3D", systemImage: "cube.transparent")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                    .background(Theme.fillSubtle).foregroundStyle(Theme.ink)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }.accessibilityIdentifier("measurements.view3D")
        }
    }

    private func persist(_ candidate: FloorMeasurementPlan) throws {
        guard !unsupported, currentContext,
              let current = model.listings.first(where: { $0.id == listing.id }),
              !current.isSample, current.cloudUnavailable != true,
              current.serverID == listing.serverID, current.serverOrgID == listing.serverOrgID else {
            throw MeasurementUIError(message: "This listing or account changed. Reopen Measurements before saving.")
        }
        guard current.floorMeasurements != nil || !FloorMeasurementPlan.hasUnreadableValue(in: current.details) else {
            throw MeasurementUIError(message: "These measurements changed to a format this app cannot open. Reopen the listing before editing.")
        }
        // Reject a cloud/local replacement rather than overwriting unseen work.
        // Date metadata may be normalized during a round trip; compare the
        // actual geometry and editing preferences before replacing a plan.
        var expected = plan
        var saved = current.floorMeasurements ?? (plan.isEmpty ? plan : FloorMeasurementPlan())
        expected.updatedAt = Date(timeIntervalSince1970: 0); saved.updatedAt = expected.updatedAt
        guard saved == expected else {
            throw MeasurementUIError(message: "These measurements changed elsewhere. Reopen this screen to use the latest version.")
        }
        var changed = candidate
        if !changed.outlines.isEmpty { changed.version = 2 }
        changed.updatedAt = Date()
        try changed.validate()
        let wire = try changed.encodedWireValue()
        var checkedListing = current; checkedListing.floorMeasurements = changed
        _ = try ListingWireDetails.merged(checkedListing)
        _ = wire // encoding/size checked before the local mutation
        try model.saveMeasurements(changed, for: listing.id)
        plan = changed; error = nil
    }

    private func addRoom() {
        guard currentContext else { invalidateContext(); return }
        let edge = rooms.map { $0.xMeters + $0.rotatedWidthMeters }.max() ?? 0
        let room = FloorMeasurementRoom(name: "", floor: floor, widthMeters: 3.6576,
                                       lengthMeters: 3.048, xMeters: edge, yMeters: 0)
        roomEditor = MeasurementRoomEditor(room: room, isNew: true)
    }

    private func addOutline() {
        guard currentContext else { invalidateContext(); return }
        guard plan.outlines.count < FloorMeasurementPlan.maximumOutlines else { return }
        outlineEditor = MeasurementOutlineEditor(outline: FloorMeasurementOutline(name: "", floor: floor, vertices: []), isNew: true)
    }

    private func moveRoom(_ id: UUID, _ x: Double, _ y: Double) {
        guard let index = plan.rooms.firstIndex(where: { $0.id == id }) else { return }
        var changed = plan
        let room = plan.rooms[index]
        let others = rooms.filter { $0.id != id }
        let xs = [0.0] + others.flatMap { [$0.xMeters, $0.xMeters + $0.rotatedWidthMeters,
                                          $0.xMeters - room.rotatedWidthMeters] }
        let ys = [0.0] + others.flatMap { [$0.yMeters, $0.yMeters + $0.rotatedLengthMeters,
                                          $0.yMeters - room.rotatedLengthMeters] }
        func snap(_ value: Double, _ edges: [Double]) -> Double {
            if let edge = edges.min(by: { abs($0 - value) < abs($1 - value) }), abs(edge - value) < 0.20 { return edge }
            let grid = plan.unit == .feet ? 0.1524 : 0.1
            return (value / grid).rounded() * grid
        }
        changed.rooms[index].xMeters = snap(x, xs)
        changed.rooms[index].yMeters = snap(y, ys)
        do { try persist(changed) } catch { self.error = error.localizedDescription }
    }

    private func makeExport() {
        do {
            guard isFresh(plan) else { throw MeasurementUIError(message: "These measurements, listing or workspace changed. Load the current measurements before exporting.") }
            try plan.validate()
            let result = try FloorMeasurementExport.make(plan: plan, floor: floor, address: listing.address)
            export = MeasurementExport(image: result.image, pdfURL: result.pdfURL, plan: plan)
        } catch { self.error = error.localizedDescription }
    }

    /// Read-only export admission; it never stages a mutation or clears a conflict.
    private func isFresh(_ snapshot: FloorMeasurementPlan) -> Bool {
        FloorMeasurementExportSafety.isFresh(snapshot: snapshot,
            current: model.listings.first(where: { $0.id == listing.id }),
            captured: listing, contextMatches: !unsupported && currentContext)
    }

    private func areaText(_ squareMeters: Double) -> String {
        plan.unit == .feet ? String(format: "%.1f sq ft", squareMeters / 0.09290304) : String(format: "%.2f m²", squareMeters)
    }
    private func invalidateContext() {
        guard didOpen, !currentContext else { return }
        roomEditor = nil; outlineEditor = nil; export = nil; show3D = false
        error = "Your account or workspace changed. Reopen Measurements to continue."
    }
}

/// Export the displayed revision only. Date normalization alone is harmless,
/// but a geometry/source/unit replacement or an unresolved CAS conflict is not.
enum FloorMeasurementExportSafety {
    static func isFresh(snapshot: FloorMeasurementPlan, current: Listing?,
                        captured: Listing, contextMatches: Bool) -> Bool {
        guard contextMatches, let current,
              current.id == captured.id, !current.isSample, current.cloudUnavailable != true,
              current.serverID == captured.serverID, current.serverOrgID == captured.serverOrgID,
              current.cloudDraftOrgID == captured.cloudDraftOrgID, current.address == captured.address,
              current.measurementSync?.conflict != true,
              current.measurementSync?.factsReviewRequired != true,
              let savedPlan = current.floorMeasurements,
              (try? snapshot.validate()) != nil, (try? savedPlan.validate()) != nil else { return false }
        var expected = snapshot, saved = savedPlan
        expected.updatedAt = Date(timeIntervalSince1970: 0); saved.updatedAt = expected.updatedAt
        return saved == expected
    }
}

private struct MeasurementUIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct MeasurementRoomEditor: Identifiable {
    let id = UUID()
    let room: FloorMeasurementRoom
    let isNew: Bool
}

private struct MeasurementOutlineEditor: Identifiable {
    let id = UUID()
    let outline: FloorMeasurementOutline
    let isNew: Bool
}

private struct MeasurementExport: Identifiable {
    let id = UUID()
    let image: UIImage
    let pdfURL: URL
    let plan: FloorMeasurementPlan
}

private func floorLabel(_ value: Int) -> String {
    if value == -1 { return "Basement" }
    if value < -1 { return "Lower level \(abs(value))" }
    return "Floor \(value + 1)"
}

private struct MeasurementRoomForm: View {
    let room: FloorMeasurementRoom
    let unit: FloorMeasurementUnit
    let otherRooms: [FloorMeasurementRoom]
    let isNew: Bool
    let onSave: (FloorMeasurementRoom) throws -> Void
    let onDelete: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var length = ""
    @State private var lengthInches = ""
    @State private var width = ""
    @State private var widthInches = ""
    @State private var height = ""
    @State private var heightInches = ""
    @State private var rotation = 0
    @State private var source: FloorMeasurementSource = .manual
    @State private var anchorID: UUID?
    @State private var side = "Right"
    @State private var measure: MeasurementTarget?
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var initialized = false
    @State private var references: [String: FloorMeasurementFieldReference] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section("Room") {
                    TextField("Room name", text: $name).accessibilityIdentifier("measurements.roomName")
                    if isNew {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack { ForEach(["Living room", "Kitchen", "Bedroom", "Bathroom", "Office"], id: \.self) { value in
                                Button(value) { name = value }.buttonStyle(.bordered).tint(Theme.accent)
                            } }
                        }
                    }
                }
                Section("Room dimensions") {
                    dimension("Length", primary: $length, inches: $lengthInches, id: "length")
                    dimension("Width", primary: $width, inches: $widthInches, id: "width")
                    dimension("Height (optional)", primary: $height, inches: $heightInches, id: "height")
                    Text("Measure wall to wall. Use your tape or laser measurements, or select the ruler for a phone estimate.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    if unit == .feet {
                        Text("Enter feet and inches separately, for example 12 ft and 6 in. Decimal feet are also accepted: 12.5 ft means 12 ft 6 in, not 12 ft 5 in.")
                            .font(.rpCaption).foregroundStyle(Theme.inkDim)
                    }
                    if source == .phoneEstimate {
                        Text("This room includes phone estimates. Check them against a tape before publishing.")
                            .font(.rpCaption).foregroundStyle(Theme.warn)
                    }
                }
                Section("Position on \(floorLabel(room.floor))") {
                    Picker("Place beside", selection: $anchorID) {
                        Text(isNew ? "At the end of the layout" : "Keep its position").tag(Optional<UUID>.none)
                        ForEach(otherRooms) { item in Text(item.name).tag(Optional(item.id)) }
                    }
                    if anchorID != nil {
                        Picker("Side", selection: $side) {
                            ForEach(["Right", "Left", "Above", "Below"], id: \.self) { Text($0).tag($0) }
                        }
                    }
                    Toggle("Rotate room 90°", isOn: Binding(get: { rotation % 2 == 1 }, set: { rotation = $0 ? 1 : 0 }))
                    Text("You can drag this room into place on the plan after saving.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
                if let error { Section { Text(error).foregroundStyle(Theme.warn).accessibilityIdentifier("measurements.formError") } }
                if !isNew {
                    Section { Button("Delete this room", role: .destructive) { confirmDelete = true } }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg).tint(Theme.accent)
            .navigationTitle(isNew ? "Add room" : "Room measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.accessibilityIdentifier("measurements.saveRoom") }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
            .onAppear { initialize() }
            .fullScreenCover(item: $measure) { target in
                RoomMeasureView(unit: unit) { meters in
                    let values = fields(meters)
                    references[target.id] = FloorMeasurementFieldReference(meters: meters, primary: values.0, inches: values.1)
                    switch target.id {
                    case "length": length = values.0; lengthInches = values.1
                    case "width": width = values.0; widthInches = values.1
                    default: height = values.0; heightInches = values.1
                    }
                    source = .phoneEstimate
                    measure = nil
                }
            }
            .confirmationDialog("Delete \(room.name)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete room", role: .destructive) {
                    do { try onDelete() } catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            }
        }.interactiveDismissDisabled()
    }

    private func dimension(_ title: String, primary: Binding<String>, inches: Binding<String>, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.rpBody.weight(.semibold))
            HStack {
                TextField(unit == .feet ? "Feet" : "Metres", text: primary)
                    .keyboardType(.decimalPad).accessibilityIdentifier("measurements.\(id)")
                Text(unit == .feet ? "ft" : "m").foregroundStyle(Theme.inkDim)
                if unit == .feet {
                    TextField("Inches", text: inches).keyboardType(.decimalPad)
                        .accessibilityIdentifier("measurements.\(id)Inches")
                    Text("in").foregroundStyle(Theme.inkDim)
                }
                Button { measure = MeasurementTarget(id: id) } label: { Image(systemName: "ruler") }
                    .accessibilityLabel("Estimate \(title.lowercased()) with phone")
            }
        }.padding(.vertical, 4)
    }

    private func initialize() {
        guard !initialized else { return }; initialized = true
        name = room.name; source = room.source; rotation = room.rotationQuarterTurns
        if !isNew {
            (length, lengthInches) = fields(room.lengthMeters)
            (width, widthInches) = fields(room.widthMeters)
            references["length"] = FloorMeasurementFieldReference(meters: room.lengthMeters, primary: length, inches: lengthInches)
            references["width"] = FloorMeasurementFieldReference(meters: room.widthMeters, primary: width, inches: widthInches)
            if let h = room.heightMeters {
                (height, heightInches) = fields(h)
                references["height"] = FloorMeasurementFieldReference(meters: h, primary: height, inches: heightInches)
            }
        }
    }

    private func fields(_ meters: Double) -> (String, String) {
        if unit == .meters { return (String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), meters), "") }
        let totalInches = (meters / 0.0254 * 1000).rounded() / 1000
        let feet = floor(totalInches / 12)
        return (String(format: "%.0f", feet), String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), totalInches - feet * 12))
    }

    private func save() {
        do {
            func dimension(_ id: String, _ value: String, _ inches: String) throws -> Double {
                if let reference = references[id] { return try reference.resolve(primary: value, inches: inches, unit: unit) }
                return try FloorMeasurementInput.meters(primary: value, inches: inches, unit: unit)
            }
            var result = room
            result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            result.lengthMeters = try dimension("length", length, lengthInches)
            result.widthMeters = try dimension("width", width, widthInches)
            let heightIsBlank = height.trimmingCharacters(in: .whitespaces).isEmpty && heightInches.trimmingCharacters(in: .whitespaces).isEmpty
            result.heightMeters = heightIsBlank ? nil : try dimension("height", height, heightInches)
            result.rotationQuarterTurns = rotation; result.source = source
            if let anchorID, let anchor = otherRooms.first(where: { $0.id == anchorID }) {
                switch side {
                case "Left": result.xMeters = anchor.xMeters - result.rotatedWidthMeters; result.yMeters = anchor.yMeters
                case "Above": result.xMeters = anchor.xMeters; result.yMeters = anchor.yMeters - result.rotatedLengthMeters
                case "Below": result.xMeters = anchor.xMeters; result.yMeters = anchor.yMeters + anchor.rotatedLengthMeters
                default: result.xMeters = anchor.xMeters + anchor.rotatedWidthMeters; result.yMeters = anchor.yMeters
                }
            }
            try onSave(result)
        } catch { self.error = error.localizedDescription }
    }
}

private struct MeasurementTarget: Identifiable { let id: String }

/// Walls are entered in plan coordinates: right is +X and down is +Y.
/// Keep the original vector while its displayed fields are untouched, so
/// editing a name never rounds precise imported/previously entered geometry.
private struct MeasurementWallDraft: Identifiable {
    let id = UUID()
    var primary: String
    var inches: String
    var direction: MeasurementWallDirection
    var bearing: String
    var original: MeasurementWallOriginal? = nil

    func vector(unit: FloorMeasurementUnit) throws -> (Double, Double) {
        if let original, primary == original.primary, inches == original.inches,
           direction == original.direction, bearing == original.bearing {
            return (original.dx, original.dy)
        }
        let length = try FloorMeasurementInput.meters(primary: primary, inches: inches, unit: unit)
        let degrees: Double
        if direction == .custom {
            let text = bearing.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
            guard text.range(of: #"^(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
                  let value = Double(text), value.isFinite, (0...360).contains(value) else {
                throw MeasurementUIError(message: "Enter a direction from 0° to 360°. Right is 0°; down is 90°.")
            }
            degrees = value
        } else { degrees = direction.degrees }
        let angle = degrees * .pi / 180
        let dx = length * cos(angle), dy = length * sin(angle)
        return (abs(dx) < 1e-10 ? 0 : dx, abs(dy) < 1e-10 ? 0 : dy)
    }
}

private struct MeasurementWallOriginal {
    let primary: String
    let inches: String
    let direction: MeasurementWallDirection
    let bearing: String
    let dx: Double
    let dy: Double
}

private enum MeasurementWallDirection: String, CaseIterable {
    case right = "Right →", downRight = "Down-right ↘", down = "Down ↓", downLeft = "Down-left ↙"
    case left = "Left ←", upLeft = "Up-left ↖", up = "Up ↑", upRight = "Up-right ↗", custom = "Other angle"
    var degrees: Double {
        switch self {
        case .right: return 0
        case .downRight: return 45
        case .down: return 90
        case .downLeft: return 135
        case .left: return 180
        case .upLeft: return 225
        case .up: return 270
        case .upRight: return 315
        case .custom: return 0
        }
    }
}

private struct MeasurementOutlineForm: View {
    let outline: FloorMeasurementOutline
    let unit: FloorMeasurementUnit
    let otherOutlines: [FloorMeasurementOutline]
    let isNew: Bool
    let onSave: (FloorMeasurementOutline) throws -> Void
    let onDelete: () throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selectedFloor = 0
    @State private var category: FloorMeasurementAreaCategory = .finished
    @State private var deductionFromID: UUID?
    @State private var startX = "0"
    @State private var startY = "0"
    @State private var originalStartX = "0"
    @State private var originalStartY = "0"
    @State private var originalStart = FloorMeasurementPoint(x: 0, y: 0)
    @State private var height = ""
    @State private var heightInches = ""
    @State private var heightReference: FloorMeasurementFieldReference?
    @State private var walls: [MeasurementWallDraft] = []
    @State private var wallLength = ""
    @State private var wallInches = ""
    @State private var wallDirection: MeasurementWallDirection = .right
    @State private var wallBearing = ""
    @State private var editingWallID: UUID?
    @State private var closingReviewed = false
    @State private var error: String?
    @State private var initialized = false
    @State private var confirmDelete = false
    @State private var wallsExpanded = false

    private var finishedParents: [FloorMeasurementOutline] {
        otherOutlines.filter { $0.floor == selectedFloor && $0.category == .finished }
    }
    private var draftPoints: [FloorMeasurementPoint] { (try? makePoints()) ?? [] }
    private var closingDistance: Double {
        guard let first = draftPoints.first, let last = draftPoints.last else { return 0 }
        return hypot(first.x - last.x, first.y - last.y)
    }
    private var manuallyClosed: Bool { walls.count >= 3 && closingDistance < 0.000001 }
    private var linkedOpeningCount: Int { otherOutlines.filter { $0.deductionFromID == outline.id }.count }
    private var deletionTitle: String {
        linkedOpeningCount == 0 ? "Delete \(outline.name)?" : "Delete \(outline.name) and its \(linkedOpeningCount) linked opening\(linkedOpeningCount == 1 ? "" : "s")?"
    }

    var body: some View {
        NavigationStack {
            Form {
                outlineDetails
                drawingPreview
                wallEntry
                wallList
                closingSection
                if let error {
                    Section { Text(error).foregroundStyle(Theme.warn).accessibilityIdentifier("measurements.outlineError") }
                }
                placementSection
                if !isNew {
                    Section {
                        Button("Delete this outline", role: .destructive) { confirmDelete = true }
                            .accessibilityIdentifier("measurements.deleteOutline")
                    }
                }
            }
            .scrollContentBackground(.hidden).background(Theme.bg).tint(Theme.accent)
            .navigationTitle(isNew ? "Draw a floor outline" : "Edit floor outline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(!closingReviewed || hasPendingWall)
                        .accessibilityIdentifier("measurements.saveOutline")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .onAppear { initialize() }
            .onChange(of: selectedFloor) { _ in
                if !finishedParents.contains(where: { $0.id == deductionFromID }) { deductionFromID = nil }
            }
            .onChange(of: category) { value in if value != .openBelow { deductionFromID = nil } }
            .onChange(of: startX) { _ in
                if startX != originalStartX || startY != originalStartY { closingReviewed = false }
            }
            .onChange(of: startY) { _ in
                if startX != originalStartX || startY != originalStartY { closingReviewed = false }
            }
            .confirmationDialog(deletionTitle, isPresented: $confirmDelete, titleVisibility: .visible) {
                Button(linkedOpeningCount == 0 ? "Delete outline" : "Delete outline and linked openings", role: .destructive) {
                    do { try onDelete() } catch { self.error = error.localizedDescription }
                }
                Button("Cancel", role: .cancel) {}
            }
        }.interactiveDismissDisabled()
    }

    private var outlineDetails: some View {
        Section("What are you measuring?") {
            TextField("Outline name", text: $name).accessibilityIdentifier("measurements.outlineName")
            Picker("Floor", selection: $selectedFloor) {
                ForEach(-2...20, id: \.self) { value in Text(floorLabel(value)).tag(value) }
            }.accessibilityIdentifier("measurements.outlineFloor")
            Picker("Area type", selection: $category) {
                ForEach([FloorMeasurementAreaCategory.finished, .unfinished, .garage, .porch, .openBelow], id: \.self) { value in
                    Text(value.label).tag(value)
                }
            }.accessibilityIdentifier("measurements.outlineCategory")
            if category == .openBelow {
                Picker("Subtract from", selection: $deductionFromID) {
                    Text("Choose a finished outline").tag(Optional<UUID>.none)
                    ForEach(finishedParents) { parent in Text(parent.name).tag(Optional(parent.id)) }
                }.accessibilityIdentifier("measurements.deductionParent")
                Text("Draw the opening in the same position as its finished outline. It must fit entirely inside that outline; its area is subtracted once.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                if finishedParents.isEmpty {
                    Text("Save a finished outline on this floor first.").font(.rpCaption).foregroundStyle(Theme.warn)
                }
            }
        }
    }

    private var drawingPreview: some View {
        Section("Follow the walls around the floor") {
            Text("Start at any corner. Enter one wall, choose its direction on the plan, then continue around the outside. Include recesses and angled walls.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            MeasurementOutlineDraftDiagram(points: draftPoints, closed: closingReviewed, calculatedClosing: !manuallyClosed,
                                           context: category == .openBelow ? finishedParents.first(where: { $0.id == deductionFromID })?.vertices : nil)
                .frame(height: 220).accessibilityIdentifier("measurements.outlinePreview")
            Text("\(walls.count) wall\(walls.count == 1 ? "" : "s") entered")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
                .accessibilityIdentifier("measurements.wallCount")
        }
    }

    private var wallList: some View {
        Section("Entered walls") {
            if walls.isEmpty { Text("Your first wall will appear here.").foregroundStyle(Theme.inkDim) }
            if !walls.isEmpty {
                DisclosureGroup("Review or change entered walls (\(walls.count))", isExpanded: $wallsExpanded) {
                    ForEach(Array(walls.enumerated()), id: \.element.id) { index, wall in
                        Button { beginEditing(wall) } label: {
                            HStack {
                                Text("\(index + 1)").font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
                                Text(wallDisplay(wall)).font(.rpBody).foregroundStyle(Theme.ink)
                                Spacer()
                                Text(wall.direction == .custom ? "\(wall.bearing)°" : wall.direction.rawValue)
                                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
                                Image(systemName: "pencil").font(.caption).foregroundStyle(Theme.accent)
                            }
                        }.accessibilityIdentifier("measurements.wall.\(index + 1)")
                    }
                }.accessibilityIdentifier("measurements.reviewWalls")
                Button { walls.removeLast(); resetWallEntry(); closingReviewed = false; error = nil } label: {
                    Label("Undo last wall", systemImage: "arrow.uturn.backward")
                }.accessibilityIdentifier("measurements.undoWall")
            }
        }
    }

    private var wallEntry: some View {
        Section(editingWallID == nil ? "Next wall" : "Change this wall") {
            HStack {
                TextField(unit == .feet ? "Feet" : "Metres", text: $wallLength)
                    .keyboardType(.decimalPad).accessibilityIdentifier("measurements.wallLength")
                Text(unit == .feet ? "ft" : "m").foregroundStyle(Theme.inkDim)
                if unit == .feet {
                    TextField("Inches", text: $wallInches).keyboardType(.decimalPad)
                        .accessibilityIdentifier("measurements.wallInches")
                    Text("in").foregroundStyle(Theme.inkDim)
                }
            }
            Picker("Direction", selection: $wallDirection) {
                ForEach(MeasurementWallDirection.allCases, id: \.self) { value in Text(value.rawValue).tag(value) }
            }.accessibilityIdentifier("measurements.wallDirection")
            if unit == .feet {
                Text("Use feet and inches separately. Decimal feet are accepted: 12.5 ft = 12 ft 6 in.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            if wallDirection == .custom {
                TextField("Direction in degrees", text: $wallBearing).keyboardType(.decimalPad)
                    .accessibilityIdentifier("measurements.wallBearing")
                Text("Clockwise from right: right 0°, down 90°, left 180°, up 270°.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
            Button { addOrUpdateWall() } label: {
                Label(editingWallID == nil ? "Add wall" : "Update wall", systemImage: editingWallID == nil ? "plus" : "checkmark")
            }.accessibilityIdentifier("measurements.addWall")
            if editingWallID != nil {
                Button("Cancel wall change") { resetWallEntry() }.accessibilityIdentifier("measurements.cancelWallChange")
            }
        }
    }

    private var closingSection: some View {
        Section("Finish the outline") {
            if closingReviewed {
                if manuallyClosed {
                    Label("Your entered walls close the outline.", systemImage: "checkmark.circle")
                        .foregroundStyle(Theme.accent)
                } else {
                    Label("Calculated closing wall — verify", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.warn).accessibilityIdentifier("measurements.calculatedClosingWarning")
                    Text("Last corner to start: \(FloorMeasurementInput.display(closingDistance, unit: unit)). This wall was calculated, not measured. Add its measured length and direction to replace it, or save it with this note.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim)
                }
            } else {
                Button { reviewClosingWall() } label: { Label("Review closing wall", systemImage: "checkmark.circle") }
                    .disabled(walls.count < 2 || hasPendingWall)
                    .accessibilityIdentifier("measurements.closeOutline")
                Text("Enter the final wall yourself, or review the straight wall calculated back to your starting corner.")
                    .font(.rpCaption).foregroundStyle(Theme.inkDim)
            }
        }
    }

    private var placementSection: some View {
        Section("Position and height (optional)") {
            Text("All outlines on this floor share the same drawing. Start at 0, 0 for the first outline. Position a garage beside it or an opening inside it using these offsets.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            HStack {
                Text("Start X"); Spacer()
                TextField("0", text: $startX).multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation).accessibilityIdentifier("measurements.startX")
                Text(unit == .feet ? "ft" : "m").foregroundStyle(Theme.inkDim)
            }
            HStack {
                Text("Start Y"); Spacer()
                TextField("0", text: $startY).multilineTextAlignment(.trailing)
                    .keyboardType(.numbersAndPunctuation).accessibilityIdentifier("measurements.startY")
                Text(unit == .feet ? "ft" : "m").foregroundStyle(Theme.inkDim)
            }
            Text("Positive X moves right; positive Y moves down. Negative numbers move left or up.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            HStack {
                Text("Height")
                TextField(unit == .feet ? "Feet" : "Metres", text: $height).keyboardType(.decimalPad)
                    .accessibilityIdentifier("measurements.outlineHeight")
                Text(unit == .feet ? "ft" : "m").foregroundStyle(Theme.inkDim)
                if unit == .feet {
                    TextField("Inches", text: $heightInches).keyboardType(.decimalPad)
                        .accessibilityIdentifier("measurements.outlineHeightInches")
                    Text("in").foregroundStyle(Theme.inkDim)
                }
            }
        }
    }

    private func initialize() {
        guard !initialized else { return }; initialized = true
        name = outline.name; selectedFloor = outline.floor; category = outline.category
        deductionFromID = outline.deductionFromID
        originalStart = outline.vertices.first ?? FloorMeasurementPoint(x: 0, y: 0)
        originalStartX = coordinateField(originalStart.x); originalStartY = coordinateField(originalStart.y)
        startX = originalStartX; startY = originalStartY
        if let meters = outline.heightMeters {
            (height, heightInches) = dimensionFields(meters)
            heightReference = FloorMeasurementFieldReference(meters: meters, primary: height, inches: heightInches)
        }
        guard !isNew, outline.vertices.count >= 3 else { return }
        let edges = outline.closingWallCalculated ? outline.vertices.count - 1 : outline.vertices.count
        for index in 0..<edges {
            let from = outline.vertices[index], to = outline.vertices[(index + 1) % outline.vertices.count]
            let dx = to.x - from.x, dy = to.y - from.y
            let length = hypot(dx, dy)
            let degrees = (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let direction = MeasurementWallDirection.allCases.first { $0 != .custom && abs($0.degrees - degrees) < 0.000001 } ?? .custom
            let fields = dimensionFields(length)
            let bearing = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), degrees)
            let original = MeasurementWallOriginal(primary: fields.0, inches: fields.1, direction: direction, bearing: bearing, dx: dx, dy: dy)
            walls.append(MeasurementWallDraft(primary: fields.0, inches: fields.1, direction: direction, bearing: bearing, original: original))
        }
        closingReviewed = true
    }

    private func coordinateField(_ meters: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), unit == .feet ? meters / 0.3048 : meters)
    }

    private func dimensionFields(_ meters: Double) -> (String, String) {
        if unit == .meters { return (String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), meters), "") }
        let inches = (meters / 0.0254 * 1000).rounded() / 1000
        let feet = Foundation.floor(inches / 12)
        return (String(format: "%.0f", feet), String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), inches - feet * 12))
    }

    private func coordinate(_ text: String) throws -> Double {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard value.range(of: #"^-?(?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+)$"#, options: .regularExpression) != nil,
              let number = Double(value), number.isFinite else {
            throw MeasurementUIError(message: "Enter a number for each starting position. Use 0 if this is the first outline.")
        }
        let meters = unit == .feet ? number * 0.3048 : number
        guard abs(meters) <= 200 else { throw MeasurementUIError(message: "The starting position must be within 200 metres of the plan origin.") }
        return meters
    }

    private func makePoints() throws -> [FloorMeasurementPoint] {
        let x = startX == originalStartX ? originalStart.x : try coordinate(startX)
        let y = startY == originalStartY ? originalStart.y : try coordinate(startY)
        var points = [FloorMeasurementPoint(x: x, y: y)]
        for wall in walls {
            let vector = try wall.vector(unit: unit)
            let last = points[points.count - 1]
            points.append(FloorMeasurementPoint(x: last.x + vector.0, y: last.y + vector.1))
        }
        return points
    }

    private func candidate() throws -> FloorMeasurementOutline {
        var points = try makePoints()
        let closed: Bool
        let originalEdgeCount = outline.vertices.count - (outline.closingWallCalculated ? 1 : 0)
        let unchangedGeometry = !isNew && startX == originalStartX && startY == originalStartY &&
            walls.count == originalEdgeCount && walls.allSatisfy { wall in
                guard let original = wall.original else { return false }
                return wall.primary == original.primary && wall.inches == original.inches &&
                    wall.direction == original.direction && wall.bearing == original.bearing
            }
        if unchangedGeometry {
            // Even subtracting and re-adding the original vectors can move a
            // floating-point coordinate. Metadata-only edits retain the vertices.
            points = outline.vertices; closed = !outline.closingWallCalculated
        } else if let first = points.first, let last = points.last, points.count >= 4,
           hypot(first.x - last.x, first.y - last.y) < 0.000001 {
            points.removeLast(); closed = true
        } else { closed = false }
        var result = outline
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.floor = selectedFloor; result.category = category; result.vertices = points
        result.deductionFromID = category == .openBelow ? deductionFromID : nil
        result.closingWallCalculated = !closed
        let blank = height.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && heightInches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if blank { result.heightMeters = nil }
        else if let heightReference { result.heightMeters = try heightReference.resolve(primary: height, inches: heightInches, unit: unit) }
        else { result.heightMeters = try FloorMeasurementInput.meters(primary: height, inches: heightInches, unit: unit) }
        return result
    }

    private func reviewClosingWall() {
        do {
            let result = try candidate()
            try result.validate()
            closingReviewed = true; error = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } catch { self.error = error.localizedDescription }
    }

    private func addOrUpdateWall() {
        do {
            var wall = MeasurementWallDraft(primary: wallLength, inches: wallInches, direction: wallDirection, bearing: wallBearing)
            if let editingWallID, let index = walls.firstIndex(where: { $0.id == editingWallID }) {
                wall = walls[index]
                wall.primary = wallLength; wall.inches = wallInches; wall.direction = wallDirection; wall.bearing = wallBearing
                _ = try wall.vector(unit: unit); walls[index] = wall
            } else {
                guard walls.count < 64 else { throw MeasurementUIError(message: "An outline can have up to 64 walls. Change an existing wall or undo the last one.") }
                _ = try wall.vector(unit: unit); walls.append(wall)
            }
            resetWallEntry(); closingReviewed = false; error = nil
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        } catch { self.error = error.localizedDescription }
    }

    private func beginEditing(_ wall: MeasurementWallDraft) {
        editingWallID = wall.id; wallLength = wall.primary; wallInches = wall.inches
        wallDirection = wall.direction; wallBearing = wall.bearing
    }

    private func resetWallEntry() {
        editingWallID = nil; wallLength = ""; wallInches = ""; wallBearing = ""
    }

    private func wallDisplay(_ wall: MeasurementWallDraft) -> String {
        guard let vector = try? wall.vector(unit: unit) else { return "Check this wall" }
        return FloorMeasurementInput.display(hypot(vector.0, vector.1), unit: unit)
    }

    private func save() {
        do {
            guard closingReviewed, !hasPendingWall else {
                throw MeasurementUIError(message: "Review the closing wall before saving this outline.")
            }
            let result = try candidate(); try result.validate(); try onSave(result)
        } catch { self.error = error.localizedDescription }
    }

    private var hasPendingWall: Bool {
        editingWallID != nil || !wallLength.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !wallInches.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !wallBearing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

private struct MeasurementOutlineDraftDiagram: View {
    let points: [FloorMeasurementPoint]
    let closed: Bool
    let calculatedClosing: Bool
    let context: [FloorMeasurementPoint]?

    var body: some View {
        GeometryReader { geo in
            let all = points + (context ?? [])
            let minX = all.map(\.x).min() ?? 0, minY = all.map(\.y).min() ?? 0
            let width = max(1, (all.map(\.x).max() ?? 1) - minX)
            let height = max(1, (all.map(\.y).max() ?? 1) - minY)
            let scale = min(max(1, geo.size.width - 48) / width, max(1, geo.size.height - 48) / height)
            let offset = CGPoint(x: (geo.size.width - width * scale) / 2, y: (geo.size.height - height * scale) / 2)
            let mapped = points.map { CGPoint(x: offset.x + ($0.x - minX) * scale, y: offset.y + ($0.y - minY) * scale) }
            ZStack {
                Theme.fillSubtle
                if let context, !context.isEmpty {
                    Path { path in
                        for (index, point) in context.enumerated() {
                            let p = CGPoint(x: offset.x + (point.x - minX) * scale, y: offset.y + (point.y - minY) * scale)
                            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                        path.closeSubpath()
                    }.fill(Theme.accentSoft.opacity(0.5))
                }
                Path { path in
                    for (index, point) in mapped.enumerated() {
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    if closed { path.closeSubpath() }
                }.stroke(Theme.accent, lineWidth: 3)
                if closed, calculatedClosing, let first = mapped.first, let last = mapped.last {
                    Path { path in path.move(to: last); path.addLine(to: first) }
                        .stroke(Theme.warn, style: StrokeStyle(lineWidth: 4, dash: [6, 5]))
                }
                ForEach(Array(mapped.enumerated()), id: \.offset) { index, point in
                    Circle().fill(index == 0 ? Theme.accent : Theme.inkDim).frame(width: 8, height: 8).position(point)
                    if index > 0 {
                        let previous = mapped[index - 1]
                        Text("\(index)").font(.caption.weight(.bold)).foregroundStyle(Theme.accent)
                            .padding(4).background(Theme.card).clipShape(Circle())
                            .position(x: (point.x + previous.x) / 2, y: (point.y + previous.y) / 2)
                    }
                }
                if let first = mapped.first {
                    Text("Start").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        .position(x: first.x, y: max(10, first.y - 14))
                }
            }.clipShape(RoundedRectangle(cornerRadius: 10))
        }.accessibilityElement(children: .ignore)
            .accessibilityLabel("Outline preview, \(max(0, points.count - 1)) entered walls. \(closed ? "Closed outline." : "Continue entering walls.")")
    }
}

private struct MeasurementViewport {
    let scale: CGFloat
    let minX: Double
    let minY: Double
    let offset: CGPoint
    init(rooms: [FloorMeasurementRoom], size: CGSize) {
        minX = rooms.map(\.xMeters).min() ?? 0
        minY = rooms.map(\.yMeters).min() ?? 0
        let width = max(1, (rooms.map { $0.xMeters + $0.rotatedWidthMeters }.max() ?? 1) - minX)
        let height = max(1, (rooms.map { $0.yMeters + $0.rotatedLengthMeters }.max() ?? 1) - minY)
        scale = min(max(1, size.width - 40) / width, max(1, size.height - 40) / height)
        offset = CGPoint(x: (size.width - width * scale) / 2, y: (size.height - height * scale) / 2)
    }
    func rect(_ room: FloorMeasurementRoom) -> CGRect {
        CGRect(x: offset.x + (room.xMeters - minX) * scale,
               y: offset.y + (room.yMeters - minY) * scale,
               width: room.rotatedWidthMeters * scale, height: room.rotatedLengthMeters * scale)
    }
}

private struct MeasurementPlanDiagram: View {
    let rooms: [FloorMeasurementRoom]
    let unit: FloorMeasurementUnit
    var onSelect: ((FloorMeasurementRoom) -> Void)?
    var onMove: ((UUID, Double, Double) -> Void)?
    @State private var dragged: UUID?
    @State private var translation: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let viewport = MeasurementViewport(rooms: rooms, size: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(rooms) { room in
                    let rect = viewport.rect(room)
                    VStack(spacing: 4) {
                        Text(room.name).font(.system(size: min(20, max(9, rect.width / 9)), weight: .semibold))
                        Text(room.displayDimensions(unit: unit)).font(.system(size: min(16, max(8, rect.width / 13))))
                    }.foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                        .lineLimit(2).minimumScaleFactor(0.6).padding(5)
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .background(Theme.accentSoft)
                        .overlay(Rectangle().stroke(Theme.accent, lineWidth: 2))
                        .contentShape(Rectangle())
                        .position(x: rect.midX, y: rect.midY)
                        .offset(dragged == room.id ? translation : .zero)
                        .onTapGesture { onSelect?(room) }
                        .gesture(DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard onMove != nil, dragged == nil || dragged == room.id else { return }
                                dragged = room.id; translation = value.translation
                            }
                            .onEnded { value in
                                guard dragged == room.id else { return }
                                onMove?(room.id, room.xMeters + value.translation.width / viewport.scale,
                                        room.yMeters + value.translation.height / viewport.scale)
                                dragged = nil; translation = .zero
                            })
                        .accessibilityLabel("\(room.name), \(room.displayDimensions(unit: unit))")
                }
            }
        }
    }
}

private struct MeasurementModelView: UIViewRepresentable {
    let rooms: [FloorMeasurementRoom]
    let outlines: [FloorMeasurementOutline]
    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene(); view.backgroundColor = UIColor.systemBackground
        view.allowsCameraControl = true; view.autoenablesDefaultLighting = true
        return view
    }
    func updateUIView(_ view: SCNView, context: Context) {}
    private func scene() -> SCNScene {
        let scene = SCNScene()
        let root = SCNNode(); scene.rootNode.addChildNode(root)
        let accent = UIColor(Theme.accent)
        func box(_ w: Double, _ h: Double, _ d: Double, x: Double, y: Double, z: Double, alpha: CGFloat) {
            let geometry = SCNBox(width: w, height: h, length: d, chamferRadius: 0)
            geometry.firstMaterial?.diffuse.contents = accent.withAlphaComponent(alpha)
            let node = SCNNode(geometry: geometry)
            node.position = SCNVector3(x, y, z); root.addChildNode(node)
        }
        if outlines.isEmpty {
            for room in rooms {
                let width = room.rotatedWidthMeters, depth = room.rotatedLengthMeters
                let x = room.xMeters + width / 2, z = room.yMeters + depth / 2
                box(width, 0.04, depth, x: x, y: 0, z: z, alpha: 0.3)
            }
            // Shared edges are drawn once, including partial walls between rooms.
            for wall in (try? FloorMeasurementGeometry.walls(for: rooms)) ?? [] {
                let mid = (wall.start + wall.end) / 2
                if wall.horizontal {
                    box(wall.end - wall.start, wall.height, 0.06, x: mid, y: wall.height / 2, z: wall.position, alpha: 0.6)
                } else {
                    box(0.06, wall.height, wall.end - wall.start, x: wall.position, y: wall.height / 2, z: mid, alpha: 0.6)
                }
            }
        } else {
            func polygonPath(_ vertices: [FloorMeasurementPoint]) -> UIBezierPath {
                let path = UIBezierPath()
                for (index, point) in vertices.enumerated() {
                    let value = CGPoint(x: point.x, y: point.y)
                    if index == 0 { path.move(to: value) } else { path.addLine(to: value) }
                }
                path.close(); return path
            }
            for outline in outlines where outline.category != .openBelow {
                let path = polygonPath(outline.vertices)
                path.usesEvenOddFillRule = true
                for opening in outlines where opening.category == .openBelow && opening.deductionFromID == outline.id {
                    path.append(polygonPath(opening.vertices).reversing())
                }
                let slab = SCNShape(path: path, extrusionDepth: 0.03)
                slab.firstMaterial?.diffuse.contents = accent.withAlphaComponent(0.3)
                slab.firstMaterial?.isDoubleSided = true
                let slabNode = SCNNode(geometry: slab)
                slabNode.eulerAngles.x = .pi / 2
                slabNode.position.y = 0.03; root.addChildNode(slabNode)
                let height = outline.heightMeters ?? 2.4
                for index in outline.vertices.indices {
                    let from = outline.vertices[index], to = outline.vertices[(index + 1) % outline.vertices.count]
                    let dx = to.x - from.x, dz = to.y - from.y
                    let geometry = SCNBox(width: hypot(dx, dz), height: height, length: 0.06, chamferRadius: 0)
                    geometry.firstMaterial?.diffuse.contents = accent.withAlphaComponent(0.6)
                    let node = SCNNode(geometry: geometry)
                    node.position = SCNVector3((from.x + to.x) / 2, height / 2, (from.y + to.y) / 2)
                    node.eulerAngles.y = Float(-atan2(dz, dx)); root.addChildNode(node)
                }
            }
        }
        let points = outlines.flatMap(\.vertices)
        let minX = outlines.isEmpty ? rooms.map(\.xMeters).min() ?? 0 : points.map(\.x).min() ?? 0
        let minZ = outlines.isEmpty ? rooms.map(\.yMeters).min() ?? 0 : points.map(\.y).min() ?? 0
        let maxX = outlines.isEmpty ? rooms.map { $0.xMeters + $0.rotatedWidthMeters }.max() ?? 4 : points.map(\.x).max() ?? 4
        let maxZ = outlines.isEmpty ? rooms.map { $0.yMeters + $0.rotatedLengthMeters }.max() ?? 4 : points.map(\.y).max() ?? 4
        let span = max(4, max(maxX - minX, maxZ - minZ))
        let maximumHeight = outlines.isEmpty ? rooms.map { $0.heightMeters ?? 2.4 }.max() ?? 2.4 : outlines.map { $0.heightMeters ?? 2.4 }.max() ?? 2.4
        let middleHeight = maximumHeight / 2
        let target = SCNVector3((minX + maxX) / 2, middleHeight, (minZ + maxZ) / 2)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.zFar = 2000
        camera.position = SCNVector3(Double(target.x) + span * 1.6, middleHeight + span * 2.1, Double(target.z) + span * 1.6)
        camera.look(at: target); scene.rootNode.addChildNode(camera)
        return scene
    }
}
