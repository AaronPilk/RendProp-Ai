import Foundation

struct PanoramaSavedViewLink: Equatable {
    let index: Int
    let direction: [Double]
    let distanceMetres: Double
    let longitude: Double
    let latitude: Double
}

enum PanoramaNavigationPolicy {
    struct ScreenPoint: Equatable { let x: Double; let y: Double }

    /// Project from the current viewing angles, without SceneKit's asynchronous
    /// presentation transform. This matches R_y(-yaw) * R_x(pitch) and a
    /// vertical field of view, with UIKit's downward-positive screen Y.
    static func screenPoint(direction d: [Double], yaw: Double, pitch: Double,
                            width: Double, height: Double, verticalFieldOfView: Double) -> ScreenPoint? {
        guard valid(d), [yaw, pitch, width, height, verticalFieldOfView].allSatisfy(\.isFinite),
              width > 0, height > 0, verticalFieldOfView > 0, verticalFieldOfView < 180 else { return nil }
        let sy = sin(yaw), cy = cos(yaw), sp = sin(pitch), cp = cos(pitch)
        let right = cy * d[0] + sy * d[2]
        let up = -sy * sp * d[0] + cp * d[1] + cy * sp * d[2]
        let depth = sy * cp * d[0] + sp * d[1] - cy * cp * d[2]
        guard depth > 0.000001 else { return nil }
        let focalLength = height / (2 * tan(verticalFieldOfView * .pi / 360))
        let x = width / 2 + right / depth * focalLength
        let y = height / 2 - up / depth * focalLength
        guard x.isFinite, y.isFinite else { return nil }
        return ScreenPoint(x: x, y: y)
    }

    /// Links point to measured camera positions, not inferred floors or routes.
    /// Incomplete and nearly coincident captures must not resemble a full tour.
    static func links(from selected: Int, positions: [[Double]], coverages: [Double], complete: [Bool]? = nil) -> [PanoramaSavedViewLink] {
        guard positions.count == coverages.count, positions.indices.contains(selected),
              complete == nil || (complete?.count == positions.count && complete?[selected] == true),
              valid(positions[selected]), coverages[selected].isFinite, coverages[selected] >= 0.6,
              coverages[selected] <= 1 else { return [] }
        let origin = positions[selected]
        return positions.indices.compactMap { index in
            let target = positions[index]
            guard index != selected, valid(target), coverages[index].isFinite,
                  complete == nil || complete?[index] == true,
                  (0.6...1).contains(coverages[index]), abs(target[1] - origin[1]) <= 0.6 else { return nil }
            let x = target[0] - origin[0], y = target[1] - origin[1], z = target[2] - origin[2]
            let horizontal = hypot(x, z), length = sqrt(x*x + y*y + z*z)
            guard (0.75...8).contains(horizontal), length.isFinite else { return nil }
            return PanoramaSavedViewLink(index: index, direction: [x/length, y/length, z/length],
                                         distanceMetres: horizontal, longitude: atan2(x, -z),
                                         latitude: atan2(y, horizontal))
        }
    }
    private static func valid(_ p: [Double]) -> Bool { p.count == 3 && p.allSatisfy(\.isFinite) }
}
