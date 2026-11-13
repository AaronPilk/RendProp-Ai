import Foundation

/// Suggestions inside an observed floor outline, not a room mesh or a tested
/// walking route. Furniture may cover part of a floor plane: the person checks
/// that a suggested spot is clear before moving or starting a scan.
struct RoomScanSuggestedPosition: Equatable {
    let number: Int
    let position: [Double]
    let boundaryClearanceMetres: Double
}

struct RoomScanPlan: Equatable {
    let floorAreaSquareMetres: Double
    let positions: [RoomScanSuggestedPosition]
}

enum RoomScanPlanner {
    static let minimumClearanceMetres = 0.55
    static let minimumSeparationMetres = 1.2

    static func plan(boundary: [[Double]], cameraPosition: [Double]) -> RoomScanPlan? {
        guard cameraPosition.count == 3, cameraPosition.allSatisfy(\.isFinite),
              boundary.count >= 3, boundary.count <= 64,
              boundary.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return nil }
        var polygon = boundary
        if polygon.first == polygon.last { polygon.removeLast() }
        guard polygon.count >= 3 else { return nil }
        let floorY = polygon.map { $0[1] }.reduce(0, +) / Double(polygon.count)
        guard polygon.allSatisfy({ abs($0[1] - floorY) <= 0.06 }),
              (0.4...2.5).contains(cameraPosition[1] - floorY) else { return nil }
        let minX = polygon.map { $0[0] }.min()!, maxX = polygon.map { $0[0] }.max()!
        let minZ = polygon.map { $0[2] }.min()!, maxZ = polygon.map { $0[2] }.max()!
        guard maxX - minX <= 16, maxZ - minZ <= 16 else { return nil }
        for i in polygon.indices {
            let j = (i + 1) % polygon.count
            guard distance(polygon[i], polygon[j]) > 0.001 else { return nil }
            for k in polygon.indices where k > i {
                let l = (k + 1) % polygon.count
                if j == k || l == i { continue }
                if segmentsIntersect(polygon[i], polygon[j], polygon[k], polygon[l]) { return nil }
            }
        }
        let signedArea = polygon.indices.reduce(0.0) { sum, i in
            let next = polygon[(i + 1) % polygon.count]
            return sum + polygon[i][0] * next[2] - next[0] * polygon[i][2]
        } / 2
        let area = abs(signedArea)
        guard (2...100).contains(area) else { return nil }
        var candidates: [(point: [Double], clearance: Double)] = []
        let step = 0.3
        let xSteps = Int(ceil((maxX - minX) / step))
        let zSteps = Int(ceil((maxZ - minZ) / step))
        for x in 0...xSteps {
            for z in 0...zSteps {
                let point = [minX + Double(x) / Double(max(1, xSteps)) * (maxX - minX), floorY,
                             minZ + Double(z) / Double(max(1, zSteps)) * (maxZ - minZ)]
                guard contains(point, polygon: polygon) else { continue }
                let clearance = polygon.indices.map {
                    segmentDistance(point, polygon[$0], polygon[($0 + 1) % polygon.count])
                }.min()!
                if clearance >= minimumClearanceMetres { candidates.append((point, clearance)) }
            }
        }
        guard !candidates.isEmpty else { return nil }
        let middle = [(minX + maxX) / 2, floorY, (minZ + maxZ) / 2]
        // Highest boundary clearance first; deterministic tie-break toward the
        // room's middle, then the starting camera. Concave outlines stay inside.
        candidates.sort {
            let ca = Int(floor($0.clearance * 20)), cb = Int(floor($1.clearance * 20))
            if ca != cb { return ca > cb }
            let a = distance($0.point, middle), b = distance($1.point, middle)
            if a != b { return a < b }
            let da = distance($0.point, cameraPosition), db = distance($1.point, cameraPosition)
            if da != db { return da < db }
            if $0.point[0] != $1.point[0] { return $0.point[0] < $1.point[0] }
            return $0.point[2] < $1.point[2]
        }
        var selected = [candidates[0]]
        // Extra positions are optional and must add a distinct viewpoint.
        while selected.count < 3 {
            let remaining = candidates.filter { candidate in
                selected.allSatisfy { distance(candidate.point, $0.point) >= minimumSeparationMetres }
            }
            guard let next = remaining.max(by: { a, b in
                let da = selected.map { distance(a.point, $0.point) }.min()!
                let db = selected.map { distance(b.point, $0.point) }.min()!
                return da < db
            }) else { break }
            selected.append(next)
        }
        return RoomScanPlan(floorAreaSquareMetres: area, positions: selected.enumerated().map {
            RoomScanSuggestedPosition(number: $0.offset + 1, position: $0.element.point,
                                      boundaryClearanceMetres: $0.element.clearance)
        })
    }

    static func contains(_ point: [Double], polygon: [[Double]]) -> Bool {
        guard point.count == 3, point.allSatisfy(\.isFinite), polygon.count >= 3,
              polygon.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return false }
        var inside = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if (a[2] > point[2]) != (b[2] > point[2]),
               point[0] < (b[0] - a[0]) * (point[2] - a[2]) / (b[2] - a[2]) + a[0] { inside.toggle() }
        }
        return inside
    }

    static func distance(_ a: [Double], _ b: [Double]) -> Double {
        hypot(a[0] - b[0], a[2] - b[2])
    }
    /// A previously displayed suggestion must remain inside the fresh floor
    /// outline. Keeping its number must never silently move its world position.
    static func hasStandingClearance(_ point: [Double], boundary: [[Double]]) -> Bool {
        guard point.count == 3, point.allSatisfy(\.isFinite), (3...64).contains(boundary.count),
              boundary.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else { return false }
        var polygon = boundary
        if polygon.first == polygon.last { polygon.removeLast() }
        guard polygon.count >= 3, contains(point, polygon: polygon),
              polygon.allSatisfy({ abs($0[1] - point[1]) <= 0.06 }) else { return false }
        for i in polygon.indices {
            let next = polygon[(i + 1) % polygon.count]
            guard distance(polygon[i], next) > 0.001,
                  segmentDistance(point, polygon[i], next) >= minimumClearanceMetres else { return false }
        }
        return true
    }
    private static func segmentDistance(_ p: [Double], _ a: [Double], _ b: [Double]) -> Double {
        let dx = b[0] - a[0], dz = b[2] - a[2]
        let t = max(0, min(1, ((p[0] - a[0]) * dx + (p[2] - a[2]) * dz) / (dx * dx + dz * dz)))
        return hypot(p[0] - a[0] - t * dx, p[2] - a[2] - t * dz)
    }
    private static func segmentsIntersect(_ a: [Double], _ b: [Double], _ c: [Double], _ d: [Double]) -> Bool {
        func cross(_ p: [Double], _ q: [Double], _ r: [Double]) -> Double {
            (q[0] - p[0]) * (r[2] - p[2]) - (q[2] - p[2]) * (r[0] - p[0])
        }
        let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
        if abC * abD < 0 && cdA * cdB < 0 { return true }
        // Touching non-neighbor edges also invalidate a floor outline.
        for (p, q, r, value) in [(a,b,c,abC),(a,b,d,abD),(c,d,a,cdA),(c,d,b,cdB)] {
            if abs(value) < 1e-8 && r[0] >= min(p[0],q[0]) - 1e-8 && r[0] <= max(p[0],q[0]) + 1e-8
                && r[2] >= min(p[2],q[2]) - 1e-8 && r[2] <= max(p[2],q[2]) + 1e-8 { return true }
        }
        return false
    }
}

/// A single fresh plane update is insufficient. Keep a consistent floor outline
/// for at least two seconds/three observations in one tracking epoch.
struct RoomScanSurveyStability {
    private var planeID: String?
    private var stableSince: Double?
    private var lastTimestamp: Double?
    private var startingPlan: RoomScanPlan?
    private var observations = 0

    mutating func reset() { self = Self() }
    mutating func observe(planeID id: String, boundary: [[Double]], cameraPosition: [Double], timestamp: Double) -> RoomScanPlan? {
        guard timestamp.isFinite, timestamp >= 0, let plan = RoomScanPlanner.plan(boundary: boundary, cameraPosition: cameraPosition),
              !plan.positions.isEmpty else { reset(); return nil }
        if planeID == id && timestamp == lastTimestamp { return nil }
        let changed = planeID != id || lastTimestamp.map { timestamp < $0 } == true
            || lastTimestamp.map { timestamp - $0 > 3 } == true
            || startingPlan.map { abs(plan.floorAreaSquareMetres - $0.floorAreaSquareMetres) > $0.floorAreaSquareMetres * 0.2 } == true
            || startingPlan.map { original in
                RoomScanPlanner.distance(original.positions[0].position, plan.positions[0].position) > 0.35
                    || original.positions.contains { !RoomScanPlanner.hasStandingClearance($0.position, boundary: boundary) }
            } == true
        if changed || stableSince == nil { stableSince = timestamp; observations = 0; startingPlan = plan }
        planeID = id; lastTimestamp = timestamp
        observations += 1
        guard observations >= 3, timestamp - (stableSince ?? timestamp) >= 2 else { return nil }
        // Compare against the first observation, not the previous one, and keep
        // every displayed number at its original world location while valid.
        return startingPlan
    }
}
