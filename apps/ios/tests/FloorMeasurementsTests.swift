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
        future.version = 3
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
        try testOutlines()
        try testPerimeterDisplay()
        print("FloorMeasurementsTests: \(assertions) assertions passed")
    }

    private static func outline(_ name: String, _ coordinates: [(Double, Double)], floor: Int = 0,
                                category: FloorMeasurementAreaCategory = .finished,
                                parent: UUID? = nil) -> FloorMeasurementOutline {
        .init(name: name, floor: floor, vertices: coordinates.map { .init(x: $0.0, y: $0.1) },
              category: category, deductionFromID: parent)
    }

    private static func testOutlines() throws {
        let lShape = outline("L-shaped first floor", [(0, 0), (6, 0), (6, 2), (2, 2), (2, 5), (0, 5)])
        try lShape.validate()
        near(lShape.areaMeters2, 18, "concave L analytical area")
        near(lShape.perimeterMeters, 22, "L analytical perimeter")
        check(lShape.edgeLengthsMeters == [6, 2, 4, 3, 2, 5], "closing edge participates in wall lengths")
        var clockwise = lShape
        clockwise.vertices.reverse()
        try clockwise.validate()
        near(clockwise.areaMeters2, 18, "clockwise and counterclockwise have equal unsigned area")
        near(clockwise.perimeterMeters, 22, "clockwise perimeter")
        let diagonal = outline("Diagonal", [(0, 0), (3, 0), (3, 4)])
        try diagonal.validate()
        near(diagonal.areaMeters2, 6, "3-4-5 triangle analytical area")
        check(diagonal.edgeLengthsMeters == [3, 4, 5], "diagonal closing wall measured length")
        near(diagonal.perimeterMeters, 12, "diagonal analytical perimeter")
        var translated = diagonal
        translated.vertices = diagonal.vertices.map { .init(x: $0.x - 190, y: $0.y + 190) }
        try translated.validate()
        near(translated.areaMeters2, 6, "large signed placement preserves small analytical area")
        let minOutline = outline("Small", [(199.8, 199.8), (199.9, 199.8), (199.9, 199.9), (199.8, 199.9)])
        try minOutline.validate()
        near(minOutline.areaMeters2, 0.01, "legal endpoint tolerates coordinate-subtraction roundoff")
        let forwardCollinear = outline("Straight segmented walls", [(0, 0), (2, 0), (4, 0), (4, 3), (0, 3)])
        try forwardCollinear.validate()
        near(forwardCollinear.areaMeters2, 12, "forward collinear walls are legal")
        for coordinates in [[(0.0, 0.0), (4, 4), (0, 4), (4, 0)],
                            [(0, 0), (4, 0), (2, 0), (2, 3), (0, 3)],
                            [(0, 0), (4, 0), (4, 4), (2, 0), (0, 4)],
                            [(0, 0), (4, 0), (4, 4), (0, 4), (0, 2), (4, 2), (2, 2), (2, 1)]] {
            rejects(.selfIntersectingOutline, "crossing, backtracking or touching nonadjacent boundary") {
                try outline("Invalid", coordinates).validate()
            }
        }
        for coordinates in [[(0.0, 0.0), (4, 0)], [(0, 0), (4, 0), (4, 4), (0, 0)],
                            [(0, 0), (0.05, 0), (0, 1)]] {
            rejects(.invalidVertices, "insufficient, repeated or too-short outline corners") {
                try outline("Invalid", coordinates).validate()
            }
        }
        rejects(.selfIntersectingOutline, "zero-area collinear closed run") {
            try outline("Line", [(0, 0), (1, 0), (2, 0)]).validate()
        }
        rejects(.invalidVertices, "edge over 100 meters") {
            try outline("Too long", [(-100, 0), (100, 0), (100, 1), (-100, 1)]).validate()
        }
        let sixtyFour = (0..<64).map { index in
            let angle = Double(index) * 2 * Double.pi / 64
            return (10 * cos(angle), 10 * sin(angle))
        }
        try outline("64 corners", sixtyFour).validate()
        rejects(.invalidVertices, "65 corner cap") { try outline("Too many", sixtyFour + [(9.9, -0.1)]).validate() }
        for value in [Double.nan, .infinity, -.infinity, -200.001, 200.001] {
            var invalid = diagonal
            invalid.vertices[0].x = value
            rejects(.invalidPosition, "invalid outline x") { try invalid.validate() }
            invalid = diagonal
            invalid.vertices[0].y = value
            rejects(.invalidPosition, "invalid outline y") { try invalid.validate() }
        }
        for name in ["", " \n", String(repeating: "a", count: 41), "Floor\nTwo", "Floor\u{0000}"] {
            var invalid = diagonal; invalid.name = name
            rejects(.invalidName, "outline name") { try invalid.validate() }
        }
        for floor in [-3, 21] {
            var invalid = diagonal; invalid.floor = floor
            rejects(.invalidFloor, "outline floor") { try invalid.validate() }
        }
        for height in [Double.nan, .infinity, 0, 100.001] {
            var invalid = diagonal; invalid.heightMeters = height
            rejects(.invalidDimension, "outline height") { try invalid.validate() }
        }

        let finished = outline("Finished first floor", [(0, 0), (10, 0), (10, 10), (0, 10)])
        let hole = outline("Open stairwell", [(1, 1), (3, 1), (3, 4), (1, 4)],
                           category: .openBelow, parent: finished.id)
        let secondHole = outline("Open foyer", [(5, 5), (7, 5), (7, 7), (5, 7)],
                                 category: .openBelow, parent: finished.id)
        let garage = outline("Garage", [(10, 0), (14, 0), (14, 6), (10, 6)], category: .garage)
        let porch = outline("Porch", [(0, -2), (10, -2), (10, 0), (0, 0)], category: .porch)
        let upstairs = outline("Upstairs unfinished", [(0, 0), (10, 0), (10, 10), (0, 10)], floor: 1, category: .unfinished)
        let annotationRoom = FloorMeasurementRoom(name: "Room inside footprint", widthMeters: 3, lengthMeters: 4)
        let basementRoom = FloorMeasurementRoom(name: "Basement room", floor: -1, widthMeters: 2, lengthMeters: 3)
        let measured = FloorMeasurementPlan(version: 2, rooms: [annotationRoom, basementRoom],
                                           outlines: [finished, hole, secondHole, garage, porch, upstairs])
        try measured.validate()
        let rows = try measured.worksheet()
        check(rows.count == 7 && !rows.contains(where: { $0.id == annotationRoom.id }), "outlined floor excludes room annotation from worksheet")
        check(rows.contains(where: { $0.id == basementRoom.id && $0.netAreaMeters2 == 6 }), "rectangle-only basement retains its distinct room-area basis")
        let finishedRow = rows.first { $0.id == finished.id }!
        near(finishedRow.grossAreaMeters2, 100, "worksheet gross before deductions")
        near(finishedRow.deductionAreaMeters2, 10, "worksheet sums explicit holes")
        near(finishedRow.netAreaMeters2, 90, "worksheet net after holes")
        near(finishedRow.perimeterMeters, 40, "worksheet gross boundary perimeter excludes hole edges")
        check(rows.filter { $0.category == .openBelow }.allSatisfy { $0.netAreaMeters2 == 0 && $0.deductionAreaMeters2 == 0 },
              "deduction rows never contribute positive totals or repeat parent deductions")
        near(rows.filter { $0.floor == 0 && $0.category == .finished }.reduce(0) { $0 + $1.netAreaMeters2 }, 90,
             "finished total excludes garage, porch and separate floors")
        near(rows.filter { $0.category == .garage }.reduce(0) { $0 + $1.netAreaMeters2 }, 24, "garage area stays classified separately")
        near(rows.filter { $0.category == .unfinished }.reduce(0) { $0 + $1.netAreaMeters2 }, 100, "upstairs unfinished separate")
        check(rows.map(\.floor) == [-1, 0, 0, 0, 0, 0, 1], "worksheet orders floors deterministically")
        check(try FloorMeasurementPlan(rooms: [basementRoom]).worksheet().first?.netAreaMeters2 == 6,
              "legacy rectangle worksheet computes entered room area")
        check(FloorMeasurementPlan().isEmpty && !measured.isEmpty, "empty checks both measurement paths")
        check(!FloorMeasurementPlan(version: 2, outlines: [finished]).isEmpty, "outline-only plan is not empty")
        check(try FloorMeasurementPlan(version: 2).worksheet().isEmpty, "removing final outline keeps a valid empty v2 plan")

        for candidate in [outline("Nested", [(2, 2), (4, 2), (4, 4), (2, 4)]),
                          outline("Crossing", [(9, 2), (12, 2), (12, 4), (9, 4)]),
                          outline("Aligned overlap", [(9, 0), (12, 0), (12, 10), (9, 10)]),
                          outline("Identical reversed", finished.vertices.reversed().map { ($0.x, $0.y) }),
                          outline("Boundary-inscribed diamond", [(0, 5), (5, 0), (10, 5), (5, 10)])] {
            rejects(.overlappingOutlines, "solid interior overlap including boundary-only corners") {
                try FloorMeasurementPlan(version: 2, outlines: [finished, candidate]).validate()
            }
        }
        let adjacentTriangle = outline("Adjacent triangle", [(3, 0), (6, 0), (3, 4)])
        try FloorMeasurementPlan(version: 2, outlines: [diagonal, adjacentTriangle]).validate()
        check(true, "diagonal/shared boundary with opposite interiors allowed")
        let withinNotch = outline("In L notch", [(3, 3), (5, 3), (5, 4), (3, 4)])
        try FloorMeasurementPlan(version: 2, outlines: [lShape, withinNotch]).validate()
        check(true, "bounding boxes overlap but polygon interiors stay separate")
        // Independent occupancy oracle: this integer L is exactly 18 unit
        // tiles. Sweep a 2×2 square across edges, corners, the concave notch and
        // empty space, in both polygon windings. Expected overlap comes from
        // shared occupied tiles, not the production polygon predicates.
        let occupiedTiles = (0..<6).flatMap { x in (0..<2).map { y in (x, y) } }
            + (0..<2).flatMap { x in (2..<5).map { y in (x, y) } }
        for x in -4...8 {
            for y in -4...7 {
                let expectedOverlap = occupiedTiles.contains { (x..<(x + 2)).contains($0.0) && (y..<(y + 2)).contains($0.1) }
                for reversed in [false, true] {
                    var first = lShape
                    var second = outline("Swept square", [(Double(x), Double(y)), (Double(x + 2), Double(y)),
                                                        (Double(x + 2), Double(y + 2)), (Double(x), Double(y + 2))])
                    if reversed { first.vertices.reverse(); second.vertices.reverse() }
                    let sweptPlan = FloorMeasurementPlan(version: 2, outlines: [first, second])
                    if expectedOverlap {
                        rejects(.overlappingOutlines, "unit-tile overlap at \(x),\(y), reversed=\(reversed)") { try sweptPlan.validate() }
                    } else {
                        try sweptPlan.validate()
                        check(true, "unit-tile separation at \(x),\(y), reversed=\(reversed)")
                    }
                }
            }
        }
        var tinyOverlap = garage
        tinyOverlap.vertices = garage.vertices.map { .init(x: $0.x - 0.001, y: $0.y) }
        rejects(.overlappingOutlines, "one millimeter of area overlap is not swallowed by boundary tolerance") {
            try FloorMeasurementPlan(version: 2, outlines: [finished, tinyOverlap]).validate()
        }
        var gap = garage
        gap.vertices = garage.vertices.map { .init(x: $0.x + 0.000001, y: $0.y) }
        try FloorMeasurementPlan(version: 2, outlines: [finished, gap]).validate()
        check(true, "real one-micrometer gap remains separated")

        for parent in [nil, UUID(), hole.id, upstairs.id, garage.id] {
            var invalid = hole; invalid.deductionFromID = parent
            rejects(.invalidDeduction, "deduction explicit same-floor finished parent") {
                try FloorMeasurementPlan(version: 2, outlines: [finished, invalid, upstairs, garage]).validate()
            }
        }
        var invalidSolid = finished; invalidSolid.deductionFromID = garage.id
        rejects(.invalidDeduction, "solid area cannot be used as hidden deduction") {
            try FloorMeasurementPlan(version: 2, outlines: [invalidSolid, garage]).validate()
        }
        for coordinates in [[(0.0, 1.0), (2, 1), (2, 3), (0, 3)], [(9, 9), (11, 9), (11, 11), (9, 11)],
                            [(0, 0), (10, 0), (10, 10), (0, 10)]] {
            let invalid = outline("Outside/touching", coordinates, category: .openBelow, parent: finished.id)
            rejects(.deductionOutsideOutline, "deduction must be strictly contained") {
                try FloorMeasurementPlan(version: 2, outlines: [finished, invalid]).validate()
            }
        }
        let notchCrossingHole = outline("Across concave notch", [(1, 1), (5, 1), (1, 4)], category: .openBelow, parent: lShape.id)
        rejects(.deductionOutsideOutline, "contained corners do not permit a hole edge through a concave notch") {
            try FloorMeasurementPlan(version: 2, outlines: [lShape, notchCrossingHole]).validate()
        }
        let overlappingHole = outline("Overlapping hole", [(2, 2), (4, 2), (4, 4), (2, 4)], category: .openBelow, parent: finished.id)
        rejects(.overlappingDeductions, "two holes cannot subtract the same area") {
            try FloorMeasurementPlan(version: 2, outlines: [finished, hole, overlappingHole]).validate()
        }
        let holeEdge = outline("Touching holes", [(3, 1), (4, 1), (4, 4), (3, 4)], category: .openBelow, parent: finished.id)
        try FloorMeasurementPlan(version: 2, outlines: [finished, hole, holeEdge]).validate()
        check(true, "deductions sharing only a boundary do not double subtract")
        var duplicate = measured; duplicate.outlines.append(finished)
        rejects(.duplicateOutline, "duplicate outline identity") { try duplicate.validate() }
        var roomID = measured; roomID.outlines[0].id = annotationRoom.id
        rejects(.duplicateOutline, "room and outline row identities cannot collide") { try roomID.validate() }
        let capacity = (0..<12).map { index in outline("Area \(index)", [(0, 0), (2, 0), (2, 2), (0, 2)], floor: index) }
        try FloorMeasurementPlan(version: 2, outlines: capacity).validate()
        rejects(.tooManyOutlines, "13 outlines") {
            try FloorMeasurementPlan(version: 2, outlines: capacity + [outline("Extra", [(0, 0), (2, 0), (2, 2), (0, 2)], floor: 12)]).validate()
        }

        var v1Outline = measured; v1Outline.version = 1
        rejects(.unsupportedVersion, "v1 cannot carry outlines that an older reader would ignore") { try v1Outline.validate() }
        var v2 = measured; v2.outlines[0].source = .phoneEstimate; v2.outlines[0].closingWallCalculated = true
        v2.outlines[0].heightMeters = 2.6
        let wire = try v2.encodedWireValue()
        check(FloorMeasurementPlan.decodeWireValue(wire) == v2, "v2 full outline/worksheet provenance roundtrip")
        check(try v2.encodedWireValue() == wire, "v2 wire deterministic")
        check(FloorMeasurementPlan.wireKey == "floor_measurements_v1", "cloud details key stays stable across versions")
        var v1Object = try object(FloorMeasurementPlan(rooms: [basementRoom]))
        v1Object.removeValue(forKey: "outlines")
        check(FloorMeasurementPlan.decodeWireValue(try raw(v1Object))?.outlines.isEmpty == true, "old v1 payload with no outline key decodes")
        var malformed = try object(v2)
        malformed.removeValue(forKey: "outlines")
        check(FloorMeasurementPlan.decodeWireValue(try raw(malformed)) == nil, "v2 missing outlines cannot silently become a room-only plan")
        malformed["outlines"] = NSNull()
        check(FloorMeasurementPlan.decodeWireValue(try raw(malformed)) == nil, "v2 null outlines rejected")
        malformed = try object(v2)
        var wireOutlines = malformed["outlines"] as! [[String: Any]]
        wireOutlines[0]["category"] = "livingFromFuture"
        malformed["outlines"] = wireOutlines
        check(FloorMeasurementPlan.decodeWireValue(try raw(malformed)) == nil, "unknown area category safely rejects")
        malformed = try object(v2); wireOutlines = malformed["outlines"] as! [[String: Any]]
        wireOutlines[0]["source"] = "laserFromFuture"; malformed["outlines"] = wireOutlines
        check(FloorMeasurementPlan.decodeWireValue(try raw(malformed)) == nil, "unknown outline source safely rejects")
        malformed = try object(v2); wireOutlines = malformed["outlines"] as! [[String: Any]]
        wireOutlines[0]["vertices"] = [["x": "nan", "y": 0]]; malformed["outlines"] = wireOutlines
        check(FloorMeasurementPlan.decodeWireValue(try raw(malformed)) == nil, "malformed vertex coordinate safely rejects")
        var large = FloorMeasurementPlan(version: 2, outlines: capacity)
        for i in large.outlines.indices {
            large.outlines[i].vertices = sixtyFour.map { .init(x: $0.0, y: $0.1) }
        }
        rejects(.tooLarge, "outline geometry respects existing 10 KB wire budget") { try large.validate() }
        var future = v2; future.version = 3
        rejects(.unsupportedVersion, "future v3 rejected") { try future.validate() }
        check(FloorMeasurementPlan.decodeWireValue(try raw(object(future))) == nil, "future v3 absent in typed reader")
        let oldListing: [String: Any] = ["address": "Synthetic outline listing", "beds": 0, "baths": 0, "sqft": 999,
            "details": [FloorMeasurementPlan.wireKey: wire]]
        let decodedListing = try listing(oldListing)
        check(decodedListing.floorMeasurements == v2 && decodedListing.sqft == 999,
              "wire-only v2 listing recovers geometry without rewriting advertised area")
        var saved = decodedListing; saved.floorMeasurements = v2
        let restored = try JSONDecoder().decode(Listing.self, from: JSONEncoder().encode(saved))
        check(restored.floorMeasurements == v2 && restored.sqft == 999, "v2 typed listing persists exact geometry and unrelated facts")
        var unknown = oldListing
        let futureWire = try raw(object(future)); unknown["details"] = [FloorMeasurementPlan.wireKey: futureWire]
        let futureListing = try listing(unknown)
        check(futureListing.floorMeasurements == nil && futureListing.details?[FloorMeasurementPlan.wireKey] == futureWire,
              "future wire is preserved raw without breaking listing")
        check(FloorMeasurementAreaCategory.allCases.count == 5 && FloorMeasurementAreaCategory.openBelow.label == "Open below",
              "area classification supports explicit finished/unfinished/garage/porch/open-below choices")
    }

    private static func testPerimeterDisplay() throws {
        let footprint = outline("40 by 20 meter floor", [(0, 0), (40, 0), (40, 20), (0, 20)])
        try footprint.validate()
        let plan = FloorMeasurementPlan(version: 2, outlines: [footprint])
        let perimeter = try plan.worksheet()[0].perimeterMeters
        near(perimeter, 120, "valid footprint has aggregate perimeter above one-wall limit")
        check(FloorMeasurementInput.displayPerimeter(perimeter, unit: .meters) == "120 m", "120 meter perimeter remains visible")
        check(FloorMeasurementInput.displayPerimeter(perimeter, unit: .feet) == "393′ 8″", "120 meter perimeter converts to feet and inches")
        check(FloorMeasurementInput.displayPerimeter(6_400, unit: .meters) == "6400 m", "maximum 64-wall aggregate safely formats meters")
        check(FloorMeasurementInput.displayPerimeter(6_400, unit: .feet) == "20997′ 5″", "maximum aggregate safely formats feet without truncation")
        check(FloorMeasurementInput.displayPerimeter(0, unit: .meters) == "0 m", "empty aggregate meter perimeter")
        check(FloorMeasurementInput.displayPerimeter(0, unit: .feet) == "0′ 0″", "empty aggregate feet perimeter")
        for value in [Double.nan, .infinity, -.infinity, -0.000001, 6_400.000001] {
            for unit in FloorMeasurementUnit.allCases {
                check(FloorMeasurementInput.displayPerimeter(value, unit: unit) == "—", "nonfinite or out-of-range aggregate is not displayed")
            }
        }
        for value in [120.0, 6_400] {
            for unit in FloorMeasurementUnit.allCases {
                check(FloorMeasurementInput.display(value, unit: unit) == "—", "aggregate display does not widen single-wall display")
            }
            rejects(.invalidDimension, "aggregate display does not widen dimension validation") {
                try FloorMeasurementInput.validateDimension(value)
            }
            rejects(.invalidDimension, "aggregate display does not widen meter entry") {
                _ = try FloorMeasurementInput.meters(primary: String(value), unit: .meters)
            }
        }
        rejects(.invalidVertices, "outline edge still cannot exceed 100 meters") {
            try outline("Too-long single wall", [(0, 0), (120, 0), (120, 1), (0, 1)]).validate()
        }
        check(FloorMeasurementInput.display(100, unit: .meters) == "100 m", "legal single-wall display endpoint retained")
    }
}
