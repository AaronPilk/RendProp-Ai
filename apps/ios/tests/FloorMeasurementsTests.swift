import Foundation

// Only the unrelated local-photo lookup needs a stub. Measurement, money,
// contact, and Listing Codable behavior compile directly from production.
enum FileStore {
    static func url(fromRelativePath path: String) -> URL { URL(fileURLWithPath: "/isolated/\(path)") }
}

@main struct FloorMeasurementsTests {
    private static var assertions = 0

    private static func check(_ value: Bool, _ message: String) {
        assertions += 1
        precondition(value, message)
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) {
        check(abs(actual - expected) < 0.000000001, message)
    }

    private static func rejects(_ expected: FloorMeasurementError, _ message: String,
                                _ operation: () throws -> Void) {
        do {
            try operation()
            check(false, "Accepted invalid input: \(message)")
        } catch {
            check(error as? FloorMeasurementError == expected, "Wrong validation for \(message): \(error)")
        }
    }

    private static func object(_ plan: FloorMeasurementPlan) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(plan)) as! [String: Any]
    }

    private static func raw(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    private static func listing(_ object: [String: Any]) throws -> Listing {
        try JSONDecoder().decode(Listing.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func main() throws {
        // Exact physical conversions and strict entry grammar.
        near(try FloorMeasurementInput.meters(primary: "12", inches: "6", unit: .feet), 3.81, "12 ft 6 in")
        near(try FloorMeasurementInput.meters(primary: "12.5", unit: .feet), 3.81, "decimal feet")
        near(try FloorMeasurementInput.meters(primary: "0", inches: "6", unit: .feet), 0.1524, "inches alone with explicit zero feet")
        near(try FloorMeasurementInput.meters(primary: " 3,5 ", unit: .meters), 3.5, "decimal comma")
        near(try FloorMeasurementInput.meters(primary: ",5", unit: .meters), 0.5, "leading comma fraction")
        near(try FloorMeasurementInput.meters(primary: "0,125", unit: .meters), 0.125, "unambiguous fractional comma")
        near(try FloorMeasurementInput.meters(primary: "0.1", unit: .meters), 0.1, "minimum dimension")
        near(try FloorMeasurementInput.meters(primary: "100", inches: "0", unit: .meters), 100, "maximum dimension")
        near(try FloorMeasurementInput.meters(primary: "2", inches: "11,5", unit: .feet), 0.9017, "decimal inches")
        for text in ["", "-1", "+1", "NaN", "Infinity", "1e2", "1 m", "1 000", "1,000", "12,345",
                     "1,2,3", "1.2,3", "1,2.3", "3.", "1\n2", "１２", String(repeating: "1", count: 65)] {
            rejects(.invalidInput, "numeric grammar \(text)") {
                _ = try FloorMeasurementInput.meters(primary: text, unit: .meters)
            }
        }
        for text in ["0", "0.099", "100.001", "99999999999999999999999999999999999999"] {
            rejects(.invalidDimension, "dimension \(text)") {
                _ = try FloorMeasurementInput.meters(primary: text, unit: .meters)
            }
        }
        rejects(.invalidInches, "12 inches must be carried into feet") {
            _ = try FloorMeasurementInput.meters(primary: "1", inches: "12", unit: .feet)
        }
        rejects(.invalidInput, "negative inches") {
            _ = try FloorMeasurementInput.meters(primary: "1", inches: "-1", unit: .feet)
        }
        rejects(.invalidInches, "meter entry cannot silently ignore stale inches") {
            _ = try FloorMeasurementInput.meters(primary: "2", inches: "6", unit: .meters)
        }

        // Rendered feet/inches can round a legal endpoint just outside the
        // dimension bounds. Only an exact untouched pair keeps its original.
        let minimumReference = FloorMeasurementFieldReference(meters: 0.1, primary: "0", inches: "3.937")
        let maximumReference = FloorMeasurementFieldReference(meters: 100, primary: "328", inches: "1.008")
        check(try minimumReference.resolve(primary: "0", inches: "3.937", unit: .feet) == 0.1,
              "untouched minimum keeps exact original meters")
        check(try maximumReference.resolve(primary: "328", inches: "1.008", unit: .feet) == 100,
              "untouched maximum keeps exact original meters")
        rejects(.invalidDimension, "minimum display reparsing really falls below the bound") {
            _ = try FloorMeasurementInput.meters(primary: "0", inches: "3.937", unit: .feet)
        }
        rejects(.invalidDimension, "maximum display reparsing really exceeds the bound") {
            _ = try FloorMeasurementInput.meters(primary: "328", inches: "1.008", unit: .feet)
        }
        rejects(.invalidDimension, "edited minimum primary cannot preserve stale meters") {
            _ = try minimumReference.resolve(primary: "0.0", inches: "3.937", unit: .feet)
        }
        rejects(.invalidDimension, "edited minimum inches cannot preserve stale meters") {
            _ = try minimumReference.resolve(primary: "0", inches: "3.936", unit: .feet)
        }
        rejects(.invalidDimension, "edited maximum primary cannot preserve stale meters") {
            _ = try maximumReference.resolve(primary: "329", inches: "1.008", unit: .feet)
        }
        rejects(.invalidDimension, "edited maximum inches cannot preserve stale meters") {
            _ = try maximumReference.resolve(primary: "328", inches: "1.009", unit: .feet)
        }
        rejects(.invalidDimension, "adding whitespace counts as an edit, not an unchanged display") {
            _ = try minimumReference.resolve(primary: "0 ", inches: "3.937", unit: .feet)
        }
        near(try minimumReference.resolve(primary: "0", inches: "4", unit: .feet), 0.1016,
             "valid edited inches becomes the new measurement")
        near(try minimumReference.resolve(primary: "1", inches: "3.937", unit: .feet), 0.4047998,
             "valid edited primary becomes the new measurement")
        for original in [Double.nan, .infinity, -.infinity, 0, 0.099, 100.001] {
            let invalidReference = FloorMeasurementFieldReference(meters: original, primary: "2", inches: "0")
            rejects(.invalidDimension, "malicious original cannot bypass validation when untouched") {
                _ = try invalidReference.resolve(primary: "2", inches: "0", unit: .meters)
            }
            rejects(.invalidDimension, "malicious original cannot bypass validation when edited") {
                _ = try invalidReference.resolve(primary: "3", inches: "0", unit: .meters)
            }
        }
        let exactExisting = 3.8100134
        let existingReference = FloorMeasurementFieldReference(meters: exactExisting, primary: "12", inches: "6.001")
        var precisionRoom = FloorMeasurementRoom(name: "Precision", widthMeters: exactExisting, lengthMeters: 4.000001)
        precisionRoom.widthMeters = try existingReference.resolve(primary: "12", inches: "6.001", unit: .feet)
        check(precisionRoom.widthMeters == exactExisting, "unchanged saved room width does not silently round")
        check(precisionRoom.widthMeters != (try FloorMeasurementInput.meters(primary: "12", inches: "6.001", unit: .feet)),
              "fixture would expose ordinary display reparsing drift")
        let meterReference = FloorMeasurementFieldReference(meters: precisionRoom.lengthMeters, primary: "4.000", inches: "")
        precisionRoom.lengthMeters = try meterReference.resolve(primary: "4.000", inches: "", unit: .meters)
        check(precisionRoom.lengthMeters == 4.000001, "unchanged saved metric length does not silently round")
        near(try meterReference.resolve(primary: "4.100", inches: "", unit: .meters), 4.1,
             "edited metric length uses entered value")

        let room = FloorMeasurementRoom(name: "Living room", widthMeters: 3, lengthMeters: 4,
                                        heightMeters: 2.4, xMeters: -10, yMeters: -5)
        try room.validate()
        check(room.floor == 0 && room.source == .manual && room.rotationQuarterTurns == 0, "room defaults")
        check(room.rotatedWidthMeters == 3 && room.rotatedLengthMeters == 4, "unrotated sides")
        var rotated = room
        rotated.rotationQuarterTurns = 1
        check(rotated.rotatedWidthMeters == 4 && rotated.rotatedLengthMeters == 3, "quarter-turn swaps sides")
        rotated.rotationQuarterTurns = 2
        check(rotated.rotatedWidthMeters == 3 && rotated.rotatedLengthMeters == 4, "half-turn preserves sides")
        rotated.rotationQuarterTurns = 3
        check(rotated.rotatedWidthMeters == 4 && rotated.rotatedLengthMeters == 3, "three-quarter-turn swaps sides")

        // Placement uses the rotated rectangle. Shared edges/corners and other
        // floors are valid; a small positive interior intersection is not.
        let edge = FloorMeasurementRoom(name: "Kitchen", widthMeters: 2, lengthMeters: 4, xMeters: -7, yMeters: -5)
        let corner = FloorMeasurementRoom(name: "Corner", widthMeters: 2, lengthMeters: 2, xMeters: -7, yMeters: -1)
        let separate = FloorMeasurementRoom(name: "Separate", widthMeters: 2, lengthMeters: 2, xMeters: 2, yMeters: 2)
        check(!room.overlaps(edge) && !edge.overlaps(room), "shared edge is allowed")
        check(!room.overlaps(corner), "shared corner is allowed")
        check(!room.overlaps(separate), "separated rooms are allowed")
        var intersection = edge
        intersection.xMeters -= 0.001
        check(room.overlaps(intersection) && intersection.overlaps(room), "one millimeter of interior intersection is overlap")
        var otherFloor = room
        otherFloor.id = UUID()
        otherFloor.floor = -1
        check(!room.overlaps(otherFloor), "vertical rooms on different floors do not overlap")
        check(rotated.overlaps(edge), "rotation changes the occupied rectangle")
        let decimalEdge = FloorMeasurementRoom(name: "Fraction", widthMeters: 0.1, lengthMeters: 1, xMeters: 0.2)
        let decimalNeighbor = FloorMeasurementRoom(name: "Neighbor", widthMeters: 1, lengthMeters: 1, xMeters: 0.3)
        check(!decimalEdge.overlaps(decimalNeighbor), "decimal shared-edge roundoff is allowed")

        var plan = FloorMeasurementPlan(rooms: [room, edge, otherFloor], updatedAt: Date(timeIntervalSinceReferenceDate: 12345.25))
        try plan.validate()
        near(plan.totalRoomAreaMeters2, 32, "sum of room areas across floors")
        check(!plan.hasOverlaps, "valid plan has no overlaps")
        var overlapping = plan
        overlapping.rooms[1] = intersection
        check(overlapping.hasOverlaps, "overlap detected at plan level")
        rejects(.overlappingRooms, "overlapping plan") { try overlapping.validate() }
        check(overlapping.totalRoomAreaMeters2 == 0, "overlapping plan cannot inflate area")
        rejects(.overlappingRooms, "overlapping plan cannot serialize") { _ = try overlapping.encodedWireValue() }

        for dimension in [Double.nan, .infinity, -.infinity, -1, 0, 0.099, 100.001] {
            var invalid = room
            invalid.widthMeters = dimension
            rejects(.invalidDimension, "width bound \(dimension)") { try invalid.validate() }
            invalid = room
            invalid.lengthMeters = dimension
            rejects(.invalidDimension, "length bound \(dimension)") { try invalid.validate() }
            invalid = room
            invalid.heightMeters = dimension
            rejects(.invalidDimension, "height bound \(dimension)") { try invalid.validate() }
        }
        for position in [Double.nan, .infinity, -.infinity, -200.001, 200.001] {
            var invalid = room
            invalid.xMeters = position
            rejects(.invalidPosition, "x bound \(position)") { try invalid.validate() }
            invalid = room
            invalid.yMeters = position
            rejects(.invalidPosition, "y bound \(position)") { try invalid.validate() }
        }
        for floor in [-3, 21] {
            var invalid = room
            invalid.floor = floor
            rejects(.invalidFloor, "floor bound") { try invalid.validate() }
        }
        for rotation in [-1, 4] {
            var invalid = room
            invalid.rotationQuarterTurns = rotation
            rejects(.invalidRotation, "rotation bound") { try invalid.validate() }
        }
        for name in ["", "  \n", String(repeating: "a", count: 41), "Room\nTwo", "Room\u{0000}"] {
            var invalid = room
            invalid.name = name
            rejects(.invalidName, "room name bound") { try invalid.validate() }
        }
        var bounds = room
        bounds.name = String(repeating: "a", count: 40)
        bounds.widthMeters = 0.1
        bounds.lengthMeters = 100
        bounds.heightMeters = nil
        bounds.xMeters = -200
        bounds.yMeters = 200
        bounds.floor = 20
        try bounds.validate()
        bounds.floor = -2
        try bounds.validate()
        check(true, "all inclusive room bounds validate")
        var duplicate = plan
        duplicate.rooms.append(room)
        rejects(.duplicateRoom, "duplicate identity even if overlap would also fail") { try duplicate.validate() }
        var future = plan
        future.version = 2
        rejects(.unsupportedVersion, "future plan") { try future.validate() }
        check(future.totalRoomAreaMeters2 == 0, "future plan has no trusted area")
        var badDate = plan
        badDate.updatedAt = Date(timeIntervalSinceReferenceDate: .nan)
        rejects(.invalidDate, "nonfinite date") { try badDate.validate() }
        let maxRooms = (0..<24).map {
            FloorMeasurementRoom(name: "Room \($0 + 1)", widthMeters: 1, lengthMeters: 1, xMeters: Double($0 * 2))
        }
        var capacity = FloorMeasurementPlan(rooms: maxRooms)
        try capacity.validate()
        near(capacity.totalRoomAreaMeters2, 24, "24 separate rooms")
        capacity.rooms.append(FloorMeasurementRoom(name: "Extra", floor: 1, widthMeters: 1, lengthMeters: 1))
        rejects(.tooManyRooms, "25 rooms") { try capacity.validate() }
        check(FloorMeasurementPlan().totalRoomAreaMeters2 == 0, "empty plan")

        // UTF-8 bytes, not Swift character count, determine the transport cap.
        let combiningName = String(repeating: "e\u{301}\u{301}\u{301}\u{301}\u{301}", count: 40)
        check(combiningName.count == 40 && combiningName.utf8.count > 400, "large legal grapheme name fixture")
        var large = FloorMeasurementPlan(rooms: maxRooms)
        for i in large.rooms.indices { large.rooms[i].name = combiningName }
        rejects(.tooLarge, "UTF-8 encoded wire cap") { _ = try large.encodedWireValue() }
        let wire = try plan.encodedWireValue()
        check(wire.utf8.count <= 10_000, "normal plan fits transport")
        check(FloorMeasurementPlan.decodeWireValue(wire) == plan, "complete wire roundtrip preserves identities/date/source/height")
        check(try plan.encodedWireValue() == wire, "wire encoding is deterministic")
        let padded = wire + String(repeating: " ", count: 10_001 - wire.utf8.count)
        check(FloorMeasurementPlan.decodeWireValue(padded) == nil, "raw wire byte cap before decode")
        for invalidRaw in [nil, "", "not JSON", "[]", "{}", "null", try raw(object(future)), try raw(object(overlapping))] {
            check(FloorMeasurementPlan.decodeWireValue(invalidRaw) == nil, "invalid/future wire is safely absent")
        }
        var unknownUnit = try object(plan)
        unknownUnit["unit"] = "yards"
        check(FloorMeasurementPlan.decodeWireValue(try raw(unknownUnit)) == nil, "unknown wire unit")
        var unknownSource = try object(plan)
        var wireRooms = unknownSource["rooms"] as! [[String: Any]]
        wireRooms[0]["source"] = "laserFromFuture"
        unknownSource["rooms"] = wireRooms
        check(FloorMeasurementPlan.decodeWireValue(try raw(unknownSource)) == nil, "unknown wire source")
        var minimalRoomPlan = try object(plan)
        var minimalRoom = (minimalRoomPlan["rooms"] as! [[String: Any]])[0]
        for field in ["floor", "heightMeters", "xMeters", "yMeters", "rotationQuarterTurns", "source"] { minimalRoom.removeValue(forKey: field) }
        minimalRoomPlan["rooms"] = [minimalRoom]
        let minimalDecoded = FloorMeasurementPlan.decodeWireValue(try raw(minimalRoomPlan))
        check(minimalDecoded?.rooms.first?.floor == 0 && minimalDecoded?.rooms.first?.xMeters == 0
              && minimalDecoded?.rooms.first?.source == .manual, "optional wire editing fields use defaults")

        // A corrupt/future measurement field must never discard an otherwise
        // valid old Listing snapshot or erase unknown cloud details.
        let old: [String: Any] = ["address": "Synthetic listing", "beds": 3, "baths": 2.5, "sqft": 1200,
                                 "details": ["unknown_future_fact": "preserve"]]
        let legacy = try listing(old)
        check(legacy.address == "Synthetic listing" && legacy.beds == 3 && legacy.baths == 2.5 && legacy.sqft == 1200,
              "legacy listing facts decode")
        check(legacy.floorMeasurements == nil && legacy.details?["unknown_future_fact"] == "preserve", "legacy listing needs no measurement field")
        var saved = legacy
        saved.floorMeasurements = plan
        saved.details?[FloorMeasurementPlan.wireKey] = wire
        saved.mainPhotoRelPath = "owned/latest.jpeg"
        saved.serverID = UUID()
        let savedRoundtrip = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(saved))
        check(savedRoundtrip == saved, "Listing full persistence roundtrip with measured plan")
        var wireOnly = old
        wireOnly["details"] = ["unknown_future_fact": "preserve", FloorMeasurementPlan.wireKey: wire]
        check(try listing(wireOnly).floorMeasurements == plan, "absent typed key recovers wire-only older snapshot")
        for badTyped: Any in [try object(future), try object(overlapping), "broken", ["version": 1], NSNull()] {
            var changed = wireOnly
            changed["floorMeasurements"] = badTyped
            let decoded = try listing(changed)
            check(decoded.floorMeasurements == nil, "present invalid/future/null typed field does not resurrect raw stale data")
            check(decoded.address == legacy.address && decoded.details?[FloorMeasurementPlan.wireKey] == wire,
                  "invalid typed data preserves listing and raw wire")
        }
        for badWire in ["broken", try raw(object(future)), padded] {
            var changed = old
            changed["details"] = ["unknown_future_fact": "preserve", FloorMeasurementPlan.wireKey: badWire]
            let decoded = try listing(changed)
            check(decoded.floorMeasurements == nil && decoded.details?[FloorMeasurementPlan.wireKey] == badWire,
                  "invalid/future raw wire remains untouched")
        }
        saved.floorMeasurements = nil
        saved.details?.removeValue(forKey: FloorMeasurementPlan.wireKey)
        let cleared = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(saved))
        check(cleared.floorMeasurements == nil && cleared.details?[FloorMeasurementPlan.wireKey] == nil,
              "explicit clear remains cleared after relaunch")
        check(cleared.mainPhotoRelPath == "owned/latest.jpeg" && cleared.serverID == saved.serverID,
              "clear preserves independent photo and sync metadata")
        plan.rooms[0].source = .phoneEstimate
        check(FloorMeasurementPlan.decodeWireValue(try plan.encodedWireValue())?.rooms[0].source == .phoneEstimate,
              "phone estimate provenance retained")
        check(FloorMeasurementPlan.floorName(-2) == "Second basement" && FloorMeasurementPlan.floorName(-1) == "Basement"
              && FloorMeasurementPlan.floorName(0) == "First floor" && FloorMeasurementPlan.floorName(20) == "Floor 21", "floor display names")
        let displayRoom = FloorMeasurementRoom(name: "Display", widthMeters: 3.81, lengthMeters: 3.048)
        check(displayRoom.displayDimensions(unit: .feet) == "12′ 6″ × 10′ 0″", "feet/inches display")
        check(displayRoom.displayDimensions(unit: .meters) == "3.81 m × 3.05 m", "meter display")

        // A shared boundary must become a single SceneKit surface, including
        // partial intersections and rooms with different entered heights.
        let leftRoom = FloorMeasurementRoom(name: "Left", widthMeters: 2, lengthMeters: 3)
        let rightRoom = FloorMeasurementRoom(name: "Right", widthMeters: 2, lengthMeters: 3, xMeters: 2)
        let adjacentWalls = try FloorMeasurementGeometry.walls(for: [leftRoom, rightRoom])
        check(adjacentWalls.count == 5, "two adjacent rooms have two joined horizontal walls and three vertical walls")
        let shared = adjacentWalls.filter { !$0.horizontal && $0.position == 2 }
        check(shared.count == 1 && shared[0].start == 0 && shared[0].end == 3 && shared[0].height == 2.4,
              "shared full-height wall appears exactly once with default height")
        let lower = adjacentWalls.filter { $0.horizontal && $0.position == 0 }
        let upper = adjacentWalls.filter { $0.horizontal && $0.position == 3 }
        check(lower.count == 1 && lower[0].start == 0 && lower[0].end == 4,
              "adjacent equal-height bottom intervals merge")
        check(upper.count == 1 && upper[0].start == 0 && upper[0].end == 4,
              "adjacent equal-height top intervals merge")
        check(try FloorMeasurementGeometry.walls(for: [rightRoom, leftRoom]) == adjacentWalls,
              "wall output is deterministic regardless of room order")
        let longRoom = FloorMeasurementRoom(name: "Long", widthMeters: 4, lengthMeters: 4, heightMeters: 2.4)
        let tallRoom = FloorMeasurementRoom(name: "Tall", widthMeters: 2, lengthMeters: 2, heightMeters: 3,
                                            xMeters: 4, yMeters: 1)
        let partialWalls = try FloorMeasurementGeometry.walls(for: [longRoom, tallRoom])
        let partial = partialWalls.filter { !$0.horizontal && $0.position == 4 }
        check(partial.count == 3, "partial shared wall retains both height transitions")
        check(partial[0] == FloorMeasurementWall(floor: 0, horizontal: false, position: 4, start: 0, end: 1, height: 2.4),
              "unshared lower part keeps shorter room height")
        check(partial[1] == FloorMeasurementWall(floor: 0, horizontal: false, position: 4, start: 1, end: 3, height: 3),
              "shared part uses maximum active height exactly once")
        check(partial[2] == FloorMeasurementWall(floor: 0, horizontal: false, position: 4, start: 3, end: 4, height: 2.4),
              "unshared upper part keeps shorter room height")
        var equalPartial = tallRoom
        equalPartial.heightMeters = 2.4
        let equalPartialWalls = try FloorMeasurementGeometry.walls(for: [longRoom, equalPartial])
            .filter { !$0.horizontal && $0.position == 4 }
        check(equalPartialWalls.count == 1 && equalPartialWalls[0].start == 0 && equalPartialWalls[0].end == 4,
              "same-height partial shared wall merges into one uninterrupted surface")
        var tallerRight = rightRoom
        tallerRight.heightMeters = 3.1
        let unequalWalls = try FloorMeasurementGeometry.walls(for: [leftRoom, tallerRight])
        let unequalShared = unequalWalls.filter { !$0.horizontal && $0.position == 2 }
        check(unequalShared.count == 1 && unequalShared[0].height == 3.1, "full shared wall uses taller height")
        let unequalBottom = unequalWalls.filter { $0.horizontal && $0.position == 0 }
        check(unequalBottom.count == 2 && unequalBottom[0].height == 2.4 && unequalBottom[1].height == 3.1,
              "adjacent genuinely unequal-height intervals stay separate")
        let turnedRoom = FloorMeasurementRoom(name: "Turned", widthMeters: 2, lengthMeters: 4,
                                              xMeters: -5, yMeters: -7, rotationQuarterTurns: 1)
        let turnedWalls = try FloorMeasurementGeometry.walls(for: [turnedRoom])
        check(turnedWalls.count == 4, "single rotated rectangle has four walls")
        check(turnedWalls.contains(.init(floor: 0, horizontal: true, position: -7, start: -5, end: -1, height: 2.4))
              && turnedWalls.contains(.init(floor: 0, horizontal: true, position: -5, start: -5, end: -1, height: 2.4)),
              "rotated horizontal walls use rotated width")
        check(turnedWalls.contains(.init(floor: 0, horizontal: false, position: -5, start: -7, end: -5, height: 2.4))
              && turnedWalls.contains(.init(floor: 0, horizontal: false, position: -1, start: -7, end: -5, height: 2.4)),
              "rotated vertical walls use rotated length")
        var upstairs = leftRoom
        upstairs.id = UUID(); upstairs.floor = 1; upstairs.heightMeters = 3
        let floorWalls = try FloorMeasurementGeometry.walls(for: [leftRoom, upstairs])
        check(floorWalls.count == 8 && floorWalls.filter { $0.floor == 0 }.count == 4
              && floorWalls.filter { $0.floor == 1 }.count == 4, "identical room geometry on separate floors stays separate")
        check(floorWalls.filter { $0.floor == 0 }.allSatisfy { $0.height == 2.4 }
              && floorWalls.filter { $0.floor == 1 }.allSatisfy { $0.height == 3 }, "floor groups preserve independent heights")
        let gapRoom = FloorMeasurementRoom(name: "Gap", widthMeters: 2, lengthMeters: 3, xMeters: 2.000001)
        let gapWalls = try FloorMeasurementGeometry.walls(for: [leftRoom, gapRoom])
        check(gapWalls.count == 8, "real gaps are not hidden by the numeric grouping tolerance")
        let decimalWalls = try FloorMeasurementGeometry.walls(for: [decimalEdge, decimalNeighbor])
        check(decimalWalls.filter { !$0.horizontal && abs($0.position - 0.3) < 0.000000001 }.count == 1,
              "floating point shared coordinates are grouped into one surface")
        check(try FloorMeasurementGeometry.walls(for: []).isEmpty, "empty layout has no walls")
        rejects(.overlappingRooms, "wall geometry rejects overlapping layout") {
            _ = try FloorMeasurementGeometry.walls(for: [room, intersection])
        }
        var invalidGeometry = leftRoom
        invalidGeometry.lengthMeters = .nan
        rejects(.invalidDimension, "wall geometry rejects nonfinite room dimension") {
            _ = try FloorMeasurementGeometry.walls(for: [invalidGeometry])
        }
        invalidGeometry = leftRoom
        invalidGeometry.heightMeters = 0
        rejects(.invalidDimension, "wall geometry rejects invalid entered height rather than defaulting") {
            _ = try FloorMeasurementGeometry.walls(for: [invalidGeometry])
        }
        invalidGeometry = leftRoom
        invalidGeometry.rotationQuarterTurns = 4
        rejects(.invalidRotation, "wall geometry rejects invalid rotation") {
            _ = try FloorMeasurementGeometry.walls(for: [invalidGeometry])
        }
        rejects(.duplicateRoom, "wall geometry rejects duplicate room identity") {
            _ = try FloorMeasurementGeometry.walls(for: [leftRoom, leftRoom])
        }
        print("FloorMeasurementsTests: \(assertions) assertions passed")
    }
}
