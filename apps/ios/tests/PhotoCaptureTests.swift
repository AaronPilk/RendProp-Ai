import Foundation

@main enum PhotoCaptureTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ reason: String) throws {
            checks += 1
            guard condition else { throw NSError(domain: reason, code: 1) }
        }
        typealias Policy = PhotoCapturePolicy
        try check(Policy.defaultLens(purpose: .interior, supportsUltraWide: true) == .ultraWide, "Rooms prefer a real supported ultra-wide camera")
        try check(Policy.defaultLens(purpose: .interior, supportsUltraWide: false) == .wide, "A phone without ultra-wide uses its real wide camera")
        try check(Policy.defaultLens(purpose: .exterior, supportsUltraWide: true) == .wide, "Exteriors start with less edge distortion")

        let phases: [Policy.Phase] = [.idle, .awaitingPermission, .opening, .ready, .orienting, .capturing, .reviewing, .saving, .failed, .closed]
        for phase in phases {
            try check(phase.canStart == [.idle, .ready, .failed, .reviewing].contains(phase), "Only idle, ready, retry or retake can configure a session")
            try check(phase.canResume == [.idle, .ready, .failed].contains(phase), "Foreground cannot invalidate a pending photo or save")
            try check(phase.canCapture == (phase == .ready), "Shutter cannot race opening, lens switching, review or saving")
            try check(phase.canOrient == (phase == .ready), "Motion cannot overwrite interruption errors or pending-photo identity")
            try check(phase.isBusy == [.awaitingPermission, .opening, .orienting, .capturing, .saving].contains(phase), "Busy phases include pending authorization, configuration, capture and saving")
        }

        let cardinals: [(Double, Double, Policy.Orientation, Int, Double)] = [
            (0, -1, .portrait, 1, 0), (-1, 0, .landscapeLeft, 3, .pi / 2),
            (1, 0, .landscapeRight, 4, -.pi / 2), (0, 1, .portraitUpsideDown, 2, .pi)
        ]
        for (x, y, orientation, capture, rotation) in cardinals {
            try check(Policy.orientation(gravityX: x, gravityY: y, previous: .portrait) == orientation, "Physical gravity determines orientation")
            try check(orientation.captureOrientationRawValue == capture, "Photo and preview use the AVFoundation physical orientation mapping")
            try check(abs(orientation.canvasRotationRadians - rotation) < 0.0001, "Camera-only rotation leaves the rest of the app portrait")
            let level = Policy.level(gravityX: x, gravityY: y, gravityZ: 0, orientation: orientation)
            try check(level?.isLevel == true, "Every upright cardinal camera orientation levels correctly")
            let tilted = Policy.level(gravityX: x * cos(0.2), gravityY: y * cos(0.2), gravityZ: sin(0.2), orientation: orientation)
            try check(tilted?.isLevel == false, "Downward/upward tilt is warned in every orientation")
            let roll = Policy.level(gravityX: x * cos(0.06) - y * sin(0.06), gravityY: x * sin(0.06) + y * cos(0.06), gravityZ: 0, orientation: orientation)
            try check(roll?.isLevel == false, "A slanted horizon is warned in every orientation")
        }
        for previous in cardinals.map({ $0.2 }) {
            try check(Policy.orientation(gravityX: 0.7, gravityY: -0.7, previous: previous) == previous, "Diagonal movement retains orientation without flicker")
            try check(Policy.orientation(gravityX: 0, gravityY: 0, previous: previous) == previous, "Face-up phone retains orientation")
            try check(Policy.orientation(gravityX: .nan, gravityY: 1, previous: previous) == previous, "Invalid motion cannot rotate the camera")
        }
        try check(Policy.level(gravityX: 0, gravityY: 0, gravityZ: 1, orientation: .portrait) == nil, "Face-up leveling is unavailable rather than falsely green")
        try check(Policy.level(gravityX: .infinity, gravityY: -1, gravityZ: 0, orientation: .portrait) == nil, "Invalid gravity is unavailable")
        let twelve = Policy.Dimensions(width: 4032, height: 3024)
        let fortyEight = Policy.Dimensions(width: 8064, height: 6048)
        let small = Policy.Dimensions(width: 1920, height: 1080)
        try check(Policy.preferredDimensions([small, fortyEight, twelve]) == twelve, "Select an advertised regular high-quality photo size")
        try check(Policy.preferredDimensions([fortyEight]) == fortyEight, "Never invent unsupported maxPhotoDimensions")
        try check(Policy.preferredDimensions([.init(width: 0, height: 3000)]) == nil, "Reject invalid format dimensions")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rendprop-photo-storage-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("original-frame".utf8), enhanced = Data("brightened-frame".utf8)
        try PhotoCaptureStorage.writePair(original: original, enhanced: enhanced, id: "success", directory: directory)
        try check(try Data(contentsOf: directory.appendingPathComponent("orig-success.jpg")) == original, "Original bytes are durable")
        try check(try Data(contentsOf: directory.appendingPathComponent("enh-success.jpg")) == enhanced, "Enhanced bytes are durable")
        do {
            try PhotoCaptureStorage.writePair(original: enhanced, enhanced: original, id: "success", directory: directory)
            throw NSError(domain: "Existing photos were overwritten", code: 1)
        } catch PhotoCaptureStorage.Failure.alreadyExists { checks += 1 }
        try check(try Data(contentsOf: directory.appendingPathComponent("orig-success.jpg")) == original, "Collision cannot alter an existing original")
        for failingWrite in [1, 2] {
            let id = "failure-\(failingWrite)"
            var writes = 0
            do {
                try PhotoCaptureStorage.writePair(original: original, enhanced: enhanced, id: id, directory: directory) { data, destination in
                    writes += 1
                    if writes == failingWrite { throw NSError(domain: "Injected full disk", code: 28) }
                    try data.write(to: destination, options: .atomic)
                }
                throw NSError(domain: "Write failure reported as success", code: 1)
            } catch let error as NSError where error.domain == "Injected full disk" { checks += 1 }
            try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("orig-\(id).jpg").path), "Failed pairs cannot leave a misleading original-only result")
            try check(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("enh-\(id).jpg").path), "Failed pairs cannot leave an enhanced image without its original")
        }
        do {
            try PhotoCaptureStorage.writePair(original: original, enhanced: enhanced, id: "../escape", directory: directory)
            throw NSError(domain: "Unsafe photo path accepted", code: 1)
        } catch PhotoCaptureStorage.Failure.invalidID { checks += 1 }
        print("PASS: \(checks) photo lens, orientation, level, resolution and failed-save checks")
    }
}
