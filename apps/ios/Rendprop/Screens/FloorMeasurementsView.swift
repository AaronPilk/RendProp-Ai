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
    @State private var export: MeasurementExport?
    @State private var show3D = false
    @State private var error: String?
    @State private var ownerAtOpen: String?
    @State private var revisionAtOpen: UInt64 = 0
    @State private var workspaceAtOpen: UUID?
    @State private var didOpen = false

    init(listing: Listing) {
        self.listing = listing
        _plan = State(initialValue: listing.floorMeasurements ?? FloorMeasurementPlan())
    }

    private var rooms: [FloorMeasurementRoom] { plan.rooms.filter { $0.floor == floor } }
    private var floors: [Int] { Array(Set(plan.rooms.map(\.floor) + [floor])).sorted() }
    private var unsupported: Bool {
        listing.floorMeasurements == nil &&
        !(listing.details?[FloorMeasurementPlan.wireKey] ?? "").isEmpty
    }
    private var currentContext: Bool {
        didOpen && auth.userID == ownerAtOpen && auth.syncSessionRevision == revisionAtOpen &&
        WorkspaceContext.selectedOrgID == workspaceAtOpen
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                introduction
                if unsupported {
                    Text("This listing has measurements in a format this version cannot open. Update the app before editing them.")
                        .font(.rpBody).foregroundStyle(Theme.warn)
                        .padding().background(Theme.card).clipShape(RoundedRectangle(cornerRadius: Theme.radius))
                } else {
                    settings
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
                    if !rooms.isEmpty { outputActions }
                }
                if let error {
                    Text(error).font(.rpBody).foregroundStyle(Theme.warn)
                        .accessibilityIdentifier("measurements.error")
                }
                Text("Rooms are saved to this listing as you add or arrange them. Cloud sync follows your listing's normal account and workspace rules.")
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
            floor = plan.rooms.first?.floor ?? 0
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
                            disclosure: "Drawn from entered room dimensions. Layout and phone estimates should be checked before use.",
                            additionalFile: item.pdfURL, canExport: { currentContext })
        }
        .sheet(isPresented: $show3D) {
            NavigationStack {
                VStack(spacing: 14) {
                    MeasurementModelView(rooms: rooms)
                    Text("Room boxes from your dimensions. Unentered heights use 2.4 m for this preview; doors, windows and wall thickness are not inferred.")
                        .font(.rpCaption).foregroundStyle(Theme.inkDim).padding()
                }.background(Theme.bg)
                    .navigationTitle("3D room layout")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { show3D = false } } }
            }
        }
        .onChange(of: auth.syncSessionRevision) { _ in invalidateContext() }
        .onReceive(NotificationCenter.default.publisher(for: .rendpropWorkspaceChanged)) { _ in invalidateContext() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Turn room measurements into a plan", systemImage: "ruler")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Enter each room's length and width from a tape or laser measure. You can also estimate a distance with your phone. Then arrange the rooms to match the home.")
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
                Text("\(rooms.count) room\(rooms.count == 1 ? "" : "s")").font(.rpCaption).foregroundStyle(Theme.inkDim)
            }.font(.rpBody.weight(.semibold)).foregroundStyle(Theme.accent)
        }
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
            let area = rooms.reduce(0) { $0 + $1.widthMeters * $1.lengthMeters }
            Text("Room area total: \(areaText(area))")
                .font(.rpHeadline).foregroundStyle(Theme.ink)
            Text("Adds the entered rectangular room areas on this floor. It does not calculate a home's advertised living area.")
                .font(.rpCaption).foregroundStyle(Theme.inkDim)
            Button { makeExport() } label: {
                Label("Download plan · image or PDF", systemImage: "square.and.arrow.down")
                    .font(.rpBody.weight(.semibold)).frame(maxWidth: .infinity).padding(14)
                    .background(Theme.accentSoft).foregroundStyle(Theme.accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }.accessibilityIdentifier("measurements.export")
            Button { show3D = true } label: {
                Label("View room layout in 3D", systemImage: "cube.transparent")
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
        guard current.floorMeasurements != nil || (current.details?[FloorMeasurementPlan.wireKey] ?? "").isEmpty else {
            throw MeasurementUIError(message: "These measurements changed to a format this app cannot open. Reopen the listing before editing.")
        }
        // Reject a cloud/local replacement rather than overwriting unseen work.
        // Date metadata may be normalized during a round trip; compare the
        // actual geometry and editing preferences before replacing a plan.
        var expected = plan
        var saved = current.floorMeasurements ?? (plan.rooms.isEmpty ? plan : FloorMeasurementPlan())
        expected.updatedAt = Date(timeIntervalSince1970: 0); saved.updatedAt = expected.updatedAt
        guard saved == expected else {
            throw MeasurementUIError(message: "These measurements changed elsewhere. Reopen this screen to use the latest version.")
        }
        var changed = candidate
        changed.updatedAt = Date()
        try changed.validate()
        _ = try changed.encodedWireValue()
        var checkedListing = current; checkedListing.floorMeasurements = changed
        _ = try ListingWireDetails.merged(checkedListing)
        model.modify(listing.id) { $0.floorMeasurements = changed }
        plan = changed; error = nil
    }

    private func addRoom() {
        guard currentContext else { invalidateContext(); return }
        let edge = rooms.map { $0.xMeters + $0.rotatedWidthMeters }.max() ?? 0
        let room = FloorMeasurementRoom(name: "", floor: floor, widthMeters: 3.6576,
                                       lengthMeters: 3.048, xMeters: edge, yMeters: 0)
        roomEditor = MeasurementRoomEditor(room: room, isNew: true)
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
            guard currentContext else { throw MeasurementUIError(message: "Your account or workspace changed. Reopen Measurements before exporting.") }
            try plan.validate()
            let content = VStack(spacing: 20) {
                Text(listing.address.isEmpty ? "Room measurements" : listing.address)
                    .font(.system(size: 34, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(floorLabel(floor)).font(.system(size: 25)).foregroundStyle(Theme.inkDim)
                MeasurementPlanDiagram(rooms: rooms, unit: plan.unit)
                Text("Entered room dimensions · layout arranged by the user")
                    .font(.system(size: 21)).foregroundStyle(Theme.inkDim)
                Text("Phone measurements are approximate. Confirm dimensions before use.")
                    .font(.system(size: 20)).foregroundStyle(Theme.inkDim)
            }.padding(48).frame(width: 1600, height: 1200)
                .background(Theme.bg).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content); renderer.scale = 1
            guard let image = renderer.uiImage else { throw MeasurementUIError(message: "Couldn't create the plan image. Try again.") }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("room-measurements-\(UUID().uuidString).pdf")
            let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 842, height: 632))
            try pdf.writePDF(to: url) { context in
                context.beginPage()
                image.draw(in: CGRect(x: 21, y: 16, width: 800, height: 600))
            }
            export = MeasurementExport(image: image, pdfURL: url)
        } catch { self.error = error.localizedDescription }
    }

    private func areaText(_ squareMeters: Double) -> String {
        plan.unit == .feet ? String(format: "%.1f sq ft", squareMeters / 0.09290304) : String(format: "%.2f m²", squareMeters)
    }
    private func invalidateContext() {
        guard didOpen, !currentContext else { return }
        roomEditor = nil; export = nil; show3D = false
        error = "Your account or workspace changed. Reopen Measurements to continue."
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

private struct MeasurementExport: Identifiable {
    let id = UUID()
    let image: UIImage
    let pdfURL: URL
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
        let minX = rooms.map(\.xMeters).min() ?? 0, minZ = rooms.map(\.yMeters).min() ?? 0
        let maxX = rooms.map { $0.xMeters + $0.rotatedWidthMeters }.max() ?? 4
        let maxZ = rooms.map { $0.yMeters + $0.rotatedLengthMeters }.max() ?? 4
        let span = max(4, max(maxX - minX, maxZ - minZ))
        let middleHeight = (rooms.map { $0.heightMeters ?? 2.4 }.max() ?? 2.4) / 2
        let target = SCNVector3((minX + maxX) / 2, middleHeight, (minZ + maxZ) / 2)
        let camera = SCNNode(); camera.camera = SCNCamera()
        camera.camera?.zFar = 2000
        camera.position = SCNVector3(Double(target.x) + span * 1.6, middleHeight + span * 2.1, Double(target.z) + span * 1.6)
        camera.look(at: target); scene.rootNode.addChildNode(camera)
        return scene
    }
}
