import Foundation
import MetricKit

// MARK: - CrashReporter
//
// Crash and hang reporting with no crash-reporting SDK. MetricKit is Apple's
// own channel: iOS collects diagnostics for us and hands them over on the NEXT
// launch (usually within 24 h), already anonymised at the source. We turn each
// one into a single tiny `crash` or `error` event on our own pipeline.
//
// ── WHY NOT A REAL CRASH REPORTER ────────────────────────────────────────────
//
// Because the question this has to answer is "is the app breaking for the
// people my ads are sending?", not "give me a symbolicated stack". MetricKit
// answers the first question for free, ships nothing third-party, and adds
// nothing to the privacy manifest. When a number here starts climbing, the fix
// is to go and look at the full diagnostic in Xcode's Organizer — which has the
// symbolicated stack this deliberately does not send.
//
// ── WHAT LEAVES THE DEVICE ───────────────────────────────────────────────────
//
// A kind, a signal or exception type as a number-turned-string, a termination
// reason CLIPPED TO 120 CHARACTERS AND STRIPPED OF ANYTHING PATH-SHAPED, and
// ONE frame name — `binaryName+offset` from the top of the attributed thread,
// capped at 80 characters.
//
// Never the full call stack. A stack trace is a list of what code was running,
// which for this app includes file-handling paths, and a `virtualMemoryRegionInfo`
// string can contain a mapped file's path outright. Neither is worth a byte of
// privacy risk to a product funnel — Xcode Organizer already has them.
final class CrashReporter: NSObject, MXMetricManagerSubscriber {

    static let shared = CrashReporter()

    private var subscribed = false

    private override init() { super.init() }

    /// Subscribe to MetricKit. Called from `Analytics.start()` on the main
    /// actor; idempotent, because a double-subscribe would double-report every
    /// crash and quietly double the number the owner is watching.
    func begin() {
        guard !subscribed else { return }
        subscribed = true
        MXMetricManager.shared.add(self)
    }

    // MARK: Diagnostics (crashes, hangs, CPU, disk)

    @available(iOS 14.0, *)
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for d in payload.crashDiagnostics ?? [] {
                emitCrash(d)
            }
            for d in payload.hangDiagnostics ?? [] {
                let ms = Int(d.hangDuration.converted(to: .milliseconds).value.rounded())
                emitError(category: "hang", diagnostic: d, stack: d.callStackTree,
                          extra: ["hang_ms": String(ms)])
            }
            for d in payload.cpuExceptionDiagnostics ?? [] {
                emitError(category: "cpu", diagnostic: d, stack: d.callStackTree, extra: [:])
            }
            for d in payload.diskWriteExceptionDiagnostics ?? [] {
                emitError(category: "disk", diagnostic: d, stack: d.callStackTree, extra: [:])
            }
        }
    }

    @available(iOS 14.0, *)
    private func emitCrash(_ d: MXCrashDiagnostic) {
        var props: [String: String] = ["kind": "crash"]
        if let signal = d.signal { props["signal"] = signal.stringValue }
        if let type = d.exceptionType { props["exception_type"] = type.stringValue }
        if let reason = d.terminationReason {
            props["termination_reason"] = Self.safeReason(reason)
        }
        if let frame = Self.topFrame(d.callStackTree) { props["top_frame"] = frame }
        props["app_version"] = Self.version(of: d)
        props["os"] = d.metaData.osVersion
        report("crash", props)
    }

    /// `callStackTree` is declared on each concrete diagnostic subclass, NOT on
    /// `MXDiagnostic`, so it comes in as its own parameter rather than being
    /// read off the base type.
    @available(iOS 14.0, *)
    private func emitError(category: String, diagnostic d: MXDiagnostic,
                           stack: MXCallStackTree, extra: [String: String]) {
        var props: [String: String] = ["category": category]
        for (k, v) in extra { props[k] = v }
        // `detail`, not `top_frame`: the server whitelists `top_frame` on
        // `crash` only, and drops it from an `error`
        // (services/supabase/functions/events/schema.ts). Same one frame.
        if let frame = Self.topFrame(stack) { props["detail"] = frame }
        props["app_version"] = Self.version(of: d)
        props["os"] = d.metaData.osVersion
        report("error", props)
    }

    // MARK: Metrics (one number, once a day)

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let launch = payload.applicationLaunchMetrics,
                  let p50 = Self.medianMilliseconds(launch.histogrammedTimeToFirstDraw) else { continue }
            report("error", [
                "category": "metrics",
                "launch_time_ms": String(p50),
                "app_version": payload.latestApplicationVersion,
            ])
        }
    }

    // MARK: Helpers

    /// MetricKit calls back on a background queue; `Analytics.track` is
    /// main-actor. Nothing here is urgent, so hop and move on.
    private func report(_ name: String, _ props: [String: String]) {
        Task { @MainActor in
            Analytics.track(name, props)
        }
    }

    /// `applicationVersion` is the marketing version; the build number lives on
    /// the metadata. Together they match the `app_version` the rest of the
    /// pipeline sends ("1.0 (1)"), so a crash can be lined up with a release.
    @available(iOS 14.0, *)
    private static func version(of d: MXDiagnostic) -> String {
        "\(d.applicationVersion) (\(d.metaData.applicationBuildVersion))"
    }

    /// A termination reason is an arbitrary string from the kernel or from
    /// whatever killed the process, and it CAN contain a file path
    /// ("...mapped file /var/mobile/.../IMG_0042.HEIC"). Drop every token that
    /// looks like a path or a URL, collapse whitespace, clip to 120.
    static func safeReason(_ raw: String) -> String {
        let cleaned = raw
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map { token -> String in
                let s = String(token)
                if s.contains("/") || s.contains("://") { return "[path]" }
                return s
            }
            .joined(separator: " ")
        return String(cleaned.prefix(120))
    }

    /// ONE frame: `binaryName+offsetIntoBinaryTextSegment` from the top of the
    /// attributed thread (the one that crashed), or the first thread if
    /// MetricKit did not attribute one. Clipped to 80 characters.
    ///
    /// Deliberately not the stack. See the file header.
    @available(iOS 14.0, *)
    static func topFrame(_ tree: MXCallStackTree) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: tree.jsonRepresentation()),
              let dict = root as? [String: Any],
              let stacks = dict["callStacks"] as? [[String: Any]],
              !stacks.isEmpty else { return nil }

        let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks[0]
        guard let frames = stack["callStackRootFrames"] as? [[String: Any]],
              let frame = frames.first else { return nil }

        let name = (frame["binaryName"] as? String) ?? "?"
        let offset = (frame["offsetIntoBinaryTextSegment"] as? NSNumber)?.stringValue ?? "0"
        return String("\(name)+\(offset)".prefix(80))
    }

    /// Median of an MXHistogram, in milliseconds. Buckets are ranges, so the
    /// answer is the midpoint of the bucket the 50th percentile falls in —
    /// approximate by construction, which is why it ships as one number and not
    /// as a percentile table.
    static func medianMilliseconds(_ histogram: MXHistogram<UnitDuration>) -> Int? {
        var buckets: [(start: Double, end: Double, count: Int)] = []
        for case let bucket as MXHistogramBucket<UnitDuration> in histogram.bucketEnumerator {
            buckets.append((
                start: bucket.bucketStart.converted(to: .milliseconds).value,
                end: bucket.bucketEnd.converted(to: .milliseconds).value,
                count: bucket.bucketCount
            ))
        }
        let total = buckets.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }

        let target = total / 2
        var seen = 0
        for bucket in buckets.sorted(by: { $0.start < $1.start }) {
            seen += bucket.count
            if seen >= target {
                return Int(((bucket.start + bucket.end) / 2).rounded())
            }
        }
        return nil
    }
}
