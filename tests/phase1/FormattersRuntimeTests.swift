import Foundation

@main struct FormattersRuntimeTests {
    static func main() {
        if CommandLine.arguments.contains("--force-failure") {
            print("FAIL: deliberate negative control")
            exit(1)
        }
        var count = 0
        func check(_ actual: String, _ expected: String, _ name: String) {
            count += 1
            guard actual == expected else {
                print("FAIL: \(name): expected \(expected), got \(actual)")
                exit(1)
            }
        }
        let review = ActualReviewMetadata()
        let valid: [(Double, String)] = [
            (0, "0:00"), (-0.0, "0:00"), (0.49, "0:00"), (0.5, "0:01"),
            (59.49, "0:59"), (59.5, "1:00"), (59.6, "1:00"), (60, "1:00"),
            (3599.5, "60:00"), (3600, "60:00"), (7201, "120:01"),
            // This duration is representable by Int; minutes must not truncate
            // to the 32-bit C integer previously used by String(format:).
            (Double(Int32.max) * 60 + 60, "2147483648:00")
        ]
        if !CommandLine.arguments.contains("--fps-only") {
            for (input, expected) in valid {
                check(Formatters.duration(input), expected, "duration \(input)")
                check(review.time(input), expected, "review time \(input)")
            }
            for input in [Double.nan, .infinity, -.infinity, 1e20,
                          Double.greatestFiniteMagnitude, Double(Int.max)] {
                check(Formatters.duration(input), "—", "invalid duration \(input)")
                check(review.time(input), "—", "invalid review time \(input)")
            }
            check(Formatters.duration(-1), "—", "negative metadata duration")
            check(review.time(-1), "0:00", "existing negative review time")
            let largestSafe = Double(Int.max).nextDown
            let total = Int(exactly: largestSafe)!
            check(Formatters.duration(largestSafe), "\(total / 60):" + String(format: "%02d", total % 60),
                  "largest representable whole-second duration")
        }
        for (input, expected) in [(0.0, "0 fps"), (23.976, "24 fps"), (29.97, "30 fps"),
                                  (59.94, "60 fps"), (120.0, "120 fps")] {
            check(Formatters.frameRate(input), expected, "frame rate \(input)")
            let asset = CaptureAsset(localURL: URL(fileURLWithPath: "/synthetic/video.mov"),
                                     durationS: 59.6, fps: input, width: 1920, height: 1080, bytes: 0)
            check(review.summary(asset), "1:00 · 1080p · \(expected)", "actual review summary \(input)")
        }
        for input in [Double.nan, .infinity, -.infinity, -1, 1e20, Double(Int.max)] {
            check(Formatters.frameRate(input), "— fps", "invalid frame rate \(input)")
            let asset = CaptureAsset(localURL: URL(fileURLWithPath: "/synthetic/video.mov"),
                                     durationS: 59.6, fps: input, width: 1920, height: 1080, bytes: 0)
            check(review.summary(asset), "1:00 · 1080p · — fps", "actual invalid review summary \(input)")
        }
        print("PASS: \(count) actual formatter and ReviewSubmitView metadata assertions")
    }
}
