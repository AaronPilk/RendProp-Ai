import Foundation

@main
struct RoomGuidanceChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ reason: String) {
            guard condition() else { fputs("FAIL: \(reason)\n", stderr); exit(1) }
            checks += 1
        }
        if CommandLine.arguments.contains("--intentional-failure") { check(false, "negative runner control") }
        let floor: [[Double]] = [[0,0,0],[6,0,0],[6,0,4],[0,0,4]]
        let camera = [0.6,1.4,0.6]
        guard let plan = RoomScanPlanner.plan(boundary: floor, cameraPosition: camera) else { fatalError("No rectangle plan") }
        check(plan.floorAreaSquareMetres == 24, "measured floor patch area")
        check(plan.positions.count == 3, "bounded distinct suggested places")
        check(RoomScanPlanner.distance(plan.positions[0].position, [3,0,2]) < 0.4, "first point near room middle")
        for p in plan.positions {
            check(RoomScanPlanner.contains(p.position, polygon: floor), "each suggestion lies inside observed outline")
            check(p.boundaryClearanceMetres >= 0.55, "each suggestion has boundary clearance")
        }
        for i in plan.positions.indices {
            for j in plan.positions.indices where j > i {
                check(RoomScanPlanner.distance(plan.positions[i].position, plan.positions[j].position) >= 1.2,
                      "additional places add a translated viewpoint")
            }
        }
        check(RoomScanPlanner.plan(boundary: floor, cameraPosition: camera) == plan, "deterministic plan")
        check(RoomScanPlanner.plan(boundary: Array(floor.reversed()), cameraPosition: camera)?.positions == plan.positions,
              "winding does not change floor placement")
        let concave: [[Double]] = [[0,0,0],[6,0,0],[6,0,2],[2,0,2],[2,0,6],[0,0,6]]
        let cornerPlan = RoomScanPlanner.plan(boundary: concave, cameraPosition: camera)!
        for p in cornerPlan.positions {
            check(RoomScanPlanner.contains(p.position, polygon: concave), "concave corner never invents floor")
        }
        let narrow: [[Double]] = [[0,0,0],[0.8,0,0],[0.8,0,4],[0,0,4]]
        check(RoomScanPlanner.plan(boundary: narrow, cameraPosition: camera) == nil, "narrow area has no clear standing suggestion")
        let crossing: [[Double]] = [[0,0,0],[4,0,4],[0,0,4],[4,0,0]]
        check(RoomScanPlanner.plan(boundary: crossing, cameraPosition: camera) == nil, "crossed outline rejected")
        check(RoomScanPlanner.plan(boundary: [[0,0,0],[1,0,0],[1,0,1],[0,0,1]], cameraPosition: camera) == nil,
              "small unobserved floor patch cannot produce room plan")
        check(RoomScanPlanner.plan(boundary: [[0,0,0],[6,0.3,0],[6,0.3,4],[0,0,4]], cameraPosition: camera) == nil,
              "sloped/mixed height plane rejected")
        check(RoomScanPlanner.plan(boundary: floor, cameraPosition: [0,0.1,0]) == nil, "tabletop/incorrect floor height rejected")
        check(RoomScanPlanner.plan(boundary: floor, cameraPosition: [0,4,0]) == nil, "incorrect remote-floor height rejected")
        check(RoomScanPlanner.plan(boundary: [[0,0,0],[.nan,0,0],[2,0,2]], cameraPosition: camera) == nil, "nonfinite boundary")
        check(RoomScanPlanner.plan(boundary: floor, cameraPosition: [0,.infinity,0]) == nil, "nonfinite camera")
        check(RoomScanPlanner.plan(boundary: floor.map { $0 + [1] }, cameraPosition: camera) == nil, "malformed world positions")
        check(RoomScanPlanner.plan(boundary: floor + [floor[0]], cameraPosition: camera) == plan, "closed polygon accepted")
        var survey = RoomScanSurveyStability()
        check(survey.observe(planeID: "floor", boundary: floor, cameraPosition: camera, timestamp: 0) == nil, "one floor observation insufficient")
        check(survey.observe(planeID: "floor", boundary: floor, cameraPosition: camera, timestamp: 1) == nil, "second observation insufficient")
        check(survey.observe(planeID: "floor", boundary: floor, cameraPosition: camera, timestamp: 2) == plan, "stable floor survey becomes usable")
        check(survey.observe(planeID: "floor", boundary: floor, cameraPosition: camera, timestamp: 2) == nil, "duplicate ARFrame not new evidence")
        check(survey.observe(planeID: "new-floor", boundary: floor, cameraPosition: camera, timestamp: 3) == nil, "different anchor loses previous stability")
        check(survey.observe(planeID: "new-floor", boundary: floor, cameraPosition: camera, timestamp: 1) == nil, "clock rollback resets survey")
        check(survey.observe(planeID: "new-floor", boundary: floor, cameraPosition: camera, timestamp: 10) == nil, "stale observation gap resets survey")
        survey.reset()
        check(survey.observe(planeID: "floor", boundary: floor, cameraPosition: camera, timestamp: 20) == nil, "tracking epoch reset clears plan")
        let positions: [[Double]] = [[0,1.4,0],[0,1.4,-2],[2,1.4,0],[0,1.4,2],[-2,1.4,0]]
        let links = PanoramaNavigationPolicy.links(from: 0, positions: positions, coverages: [1,1,1,1,1])
        check(links.count == 4, "four distinct captured directions can be tapped")
        check(PanoramaNavigationPolicy.links(from: 0, positions: positions, coverages: [1,1,1,1,1], complete: [false,true,true,true,true]).isEmpty,
              "partial source never supplies spatial navigation markers")
        check(PanoramaNavigationPolicy.links(from: 0, positions: positions, coverages: [1,1,1,1,1], complete: [true,false,false,false,false]).isEmpty,
              "partial targets never supply spatial navigation markers")
        check(abs(links[0].longitude) < 1e-8, "forward measured camera")
        check(abs(links[1].longitude - .pi/2) < 1e-8, "right measured camera")
        check(abs(abs(links[2].longitude) - .pi) < 1e-8, "rear wrap bearing")
        check(abs(links[3].longitude + .pi/2) < 1e-8, "left measured camera")
        for link in links {
            check(abs(link.direction.reduce(0) { $0 + $1 * $1 } - 1) < 1e-8, "navigation ray normalized")
            check(link.distanceMetres == 2, "recorded translation preserved")
        }
        check(PanoramaNavigationPolicy.links(from: 0, positions: positions, coverages: [0.1,1,1,1,1]).isEmpty,
              "one-shot panorama must not look like completed navigable room")
        check(PanoramaNavigationPolicy.links(from: 0, positions: [[0,1.4,0],[0.1,1.4,0]], coverages: [1,1]).isEmpty,
              "repeated buttons at same spot are not a navigable destination")
        check(PanoramaNavigationPolicy.links(from: 0, positions: [[0,1.4,0],[2,3,0]], coverages: [1,1]).isEmpty,
              "different floor not inferred as connected")
        check(PanoramaNavigationPolicy.links(from: 0, positions: [[0,1.4,0],[20,1.4,0]], coverages: [1,1]).isEmpty,
              "remote position not inferred as neighbor")
        check(PanoramaNavigationPolicy.links(from: 0, positions: positions, coverages: [1]).isEmpty, "mismatched metadata")
        check(PanoramaNavigationPolicy.links(from: 9, positions: positions, coverages: [1,1,1,1,1]).isEmpty, "invalid selected position")
        check(PanoramaNavigationPolicy.links(from: 0, positions: [[0,1.4,0],[.nan,1.4,0]], coverages: [1,1]).isEmpty, "nonfinite navigation")
        func screen(_ direction: [Double], yaw: Double = 0, pitch: Double = 0,
                    width: Double = 390, height: Double = 600, fov: Double = 70) -> PanoramaNavigationPolicy.ScreenPoint? {
            PanoramaNavigationPolicy.screenPoint(direction: direction, yaw: yaw, pitch: pitch,
                width: width, height: height, verticalFieldOfView: fov)
        }
        check(screen([0,0,-1]) == .init(x: 195, y: 300), "forward ray centered without a rendered SceneKit frame")
        check(abs(screen([1,0,0], yaw: .pi/2)!.x - 195) < 1e-8, "current right-facing yaw immediately centers right view")
        check(abs(screen([-1,0,0], yaw: -.pi/2)!.x - 195) < 1e-8, "current left-facing yaw immediately centers left view")
        check(abs(screen([0,0,1], yaw: .pi)!.x - 195) < 1e-8, "rear-facing yaw centers rear view")
        let tilted = screen([0, sin(.pi/6), -cos(.pi/6)], pitch: .pi/6)!
        check(abs(tilted.x - 195) < 1e-8 && abs(tilted.y - 300) < 1e-8, "matching tilt centers raised view")
        check(screen([0,0.2,-1])!.y < 300, "above ray maps above UIKit center")
        check(screen([0,-0.2,-1])!.y > 300, "below ray maps below UIKit center")
        check(screen([0,0,1]) == nil, "rear ray is hidden without waiting for rendering")
        check(screen([0,0,0]) == nil, "zero-depth ray rejected")
        check(screen([.nan,0,-1]) == nil, "nonfinite ray rejected")
        check(screen([0,0,-1], width: 0) == nil, "unlaid-out viewport produces no marker")
        check(screen([0,0,-1], yaw: .infinity) == nil, "nonfinite camera angle rejected")
        check(screen([0,0,-1], fov: 180) == nil, "invalid camera field of view rejected")
        print("Room survey/navigation: \(checks) checks passed")
    }
}
