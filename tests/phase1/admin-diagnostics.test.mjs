import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';
import assert from 'node:assert/strict';

const root = fileURLToPath(new URL('../../', import.meta.url));
const probePath = root + 'apps/ios/Rendprop/Screens/AdminProbeAPI.swift';
const crashPath = root + 'apps/ios/Rendprop/Analytics/CrashReporter.swift';
const probeSource = readFileSync(probePath, 'utf8');
const crashSource = readFileSync(crashPath, 'utf8');

function declaration(source, needle) {
  assert.equal(source.split(needle).length - 1, 1, `unique actual declaration ${needle}`);
  const begin = source.lastIndexOf('\n', source.indexOf(needle)) + 1;
  let position = source.indexOf('{', source.indexOf(needle)), depth = 1;
  while (depth > 0 && ++position < source.length) {
    if (source[position] === '{') depth++;
    if (source[position] === '}') depth--;
  }
  assert.equal(depth, 0);
  return source.slice(begin, position + 1);
}

// Mechanically extract the real Foundation models and their presentation
// helpers. HTTP transports and app-global formatting are inert boundaries.
assert.equal(probeSource.split('protocol AdminProbeAPI {').length - 1, 1);
assert.equal(probeSource.split('enum AdminProbeText {').length - 1, 1);
const probeModels = probeSource.slice(0, probeSource.indexOf('protocol AdminProbeAPI {'))
  + probeSource.slice(probeSource.indexOf('enum AdminProbeText {'));

const boundary = String.raw`
import Foundation

enum AdminText { static func pretty(_ value: String) -> String { value } }
enum Formatters { static func relative(_ date: Date) -> String { "relative" } }

// Inert MetricKit type fixtures. No OS subscription, device crash or network
// runs here; the complete production subscriber/callback code runs unchanged.
protocol MXMetricManagerSubscriber {}
final class MXMetricManager {
    static let shared = MXMetricManager()
    var subscriptions = 0
    func add(_ subscriber: MXMetricManagerSubscriber) { subscriptions += 1 }
}
struct MXMetaData {
    var osVersion = "fixture-os"
    var applicationBuildVersion = "diagnostic-build"
}
class MXDiagnostic {
    var applicationVersion = "diagnostic-version"
    var metaData = MXMetaData()
}
final class MXCallStackTree {
    func jsonRepresentation() -> Data {
        Data(#"{"callStacks":[{"threadAttributed":true,"callStackRootFrames":[{"binaryName":"FixtureApp","offsetIntoBinaryTextSegment":12}]}]}"#.utf8)
    }
}
final class MXCrashDiagnostic: MXDiagnostic {
    var signal: NSNumber? = 11
    var exceptionType: NSNumber? = 1
    var terminationReason: String? = "terminated /private/fixture/image.jpg"
    var callStackTree = MXCallStackTree()
}
final class MXHangDiagnostic: MXDiagnostic {
    var hangDuration = Measurement(value: 2, unit: UnitDuration.seconds)
    var callStackTree = MXCallStackTree()
}
final class MXCPUExceptionDiagnostic: MXDiagnostic { var callStackTree = MXCallStackTree() }
final class MXDiskWriteExceptionDiagnostic: MXDiagnostic { var callStackTree = MXCallStackTree() }
struct MXDiagnosticPayload {
    var crashDiagnostics: [MXCrashDiagnostic]? = nil
    var hangDiagnostics: [MXHangDiagnostic]? = nil
    var cpuExceptionDiagnostics: [MXCPUExceptionDiagnostic]? = nil
    var diskWriteExceptionDiagnostics: [MXDiskWriteExceptionDiagnostic]? = nil
}
final class MXHistogramBucket<UnitType: Unit> {
    var bucketStart: Measurement<UnitType>
    var bucketEnd: Measurement<UnitType>
    var bucketCount: Int
    init(start: Measurement<UnitType>, end: Measurement<UnitType>, count: Int) {
        bucketStart = start; bucketEnd = end; bucketCount = count
    }
}
final class MXHistogram<UnitType: Unit> {
    var bucketEnumerator: [Any]
    init(_ buckets: [MXHistogramBucket<UnitType>]) { bucketEnumerator = buckets }
}
struct MXAppLaunchMetrics { var histogrammedTimeToFirstDraw: MXHistogram<UnitDuration> }
struct MXMetricPayload {
    var applicationLaunchMetrics: MXAppLaunchMetrics?
    var latestApplicationVersion = "metric-version"
}
@MainActor enum Analytics {
    static var events: [(name: String, props: [String: String])] = []
    static func track(_ name: String, _ props: [String: String]) { events.append((name, props)) }
}
`;

const harness = String.raw`
@main struct AdminDiagnosticsTests {
    static var checks = 0
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !condition() { print("FAIL: " + message); exit(1) }
    }
    @MainActor static func flush() async {
        for _ in 0..<8 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    @MainActor static func main() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let permission = try decoder.decode(AdminProbeResult.self, from: Data(#"{"key":"elevenlabs","configured":true,"ok":null,"error_class":"permission"}"#.utf8))
        require(permission.state == .permission, "typed nil permission must remain distinct")
        require(permission.state.label == "Can't test: permission", "permission needs an honest diagnostic label")
        require(!permission.state.isFailure, "missing diagnostic scope is not an invalid-key verdict")
        let invalid = try decoder.decode(AdminProbeResult.self, from: Data(#"{"key":"elevenlabs","configured":true,"ok":false,"error_class":"auth"}"#.utf8))
        require(invalid.state == .wrongKey && invalid.state.isFailure, "invalid-key behavior unchanged")
        let unknown = try decoder.decode(AdminProbeResult.self, from: Data(#"{"configured":true,"ok":null,"error_class":"future_class"}"#.utf8))
        require(unknown.state == .notTestable, "future nil result remains neutral")
        let absent = try decoder.decode(AdminProbeResult.self, from: Data(#"{"configured":false,"ok":null,"error_class":"permission"}"#.utf8))
        require(absent.state == .notSet, "missing configuration retains precedence")
        let working = try decoder.decode(AdminProbeResult.self, from: Data(#"{"key":"fal","configured":true,"ok":true}"#.utf8))
        var report = AdminProbeReport()
        report.results = [working, permission, invalid, unknown, absent]
        require(AdminProbeText.summary(report) == "1 working · 1 failed · 3 not tested", "permission counted as untested")
        require(report.sortedResults.map { $0.state } == [.wrongKey, .permission, .notTestable, .notSet, .working], "failures sort before permission and working")

        let reporter = CrashReporter.shared
        reporter.begin(); reporter.begin()
        require(MXMetricManager.shared.subscriptions == 1, "idempotent MetricKit subscription")
        let histogram = MXHistogram([MXHistogramBucket(
            start: Measurement(value: 1, unit: UnitDuration.seconds),
            end: Measurement(value: 2, unit: UnitDuration.seconds), count: 4)])
        // Non-empty launch data reaches the exact legacy bug, not an empty
        // callback that would pass both the fixed and original source.
        reporter.didReceive([MXMetricPayload(applicationLaunchMetrics: MXAppLaunchMetrics(histogrammedTimeToFirstDraw: histogram))])
        await flush()
        require(Analytics.events.isEmpty, "routine launch metrics must not count as errors")
        reporter.didReceive([MXDiagnosticPayload()])
        await flush()
        require(Analytics.events.isEmpty, "empty diagnostics emit nothing")
        reporter.didReceive([MXDiagnosticPayload(crashDiagnostics: [MXCrashDiagnostic()],
            hangDiagnostics: [MXHangDiagnostic()], cpuExceptionDiagnostics: [MXCPUExceptionDiagnostic()],
            diskWriteExceptionDiagnostics: [MXDiskWriteExceptionDiagnostic()])])
        await flush()
        require(Analytics.events.count == 4, "four actual diagnostics remain reported")
        let crashes = Analytics.events.filter { $0.name == "crash" }
        require(crashes.count == 1, "crash stays a crash event")
        require(crashes[0].props["app_version"] == "diagnostic-version (diagnostic-build)", "diagnostic version retained")
        require(crashes[0].props["termination_reason"] == "terminated [path]", "crash path remains private")
        let errors = Analytics.events.filter { $0.name == "error" }
        require(errors.count == 3, "only actual diagnostic errors")
        require(Set(errors.compactMap { $0.props["category"] }) == Set(["hang", "cpu", "disk"]), "diagnostic categories retained")
        require(errors.first { $0.props["category"] == "hang" }?.props["hang_ms"] == "2000", "hang duration retained")
        print("PASS: \(checks) actual admin mapping and diagnostic assertions")
    }
}
`;

test('actual admin mapping and MetricKit callbacks distinguish untested permissions and routine metrics', () => {
  const out = mkdtempSync(join(tmpdir(), 'rendprop-admin-diagnostics-'));
  assert.equal(crashSource.split('import MetricKit').length - 1, 1);
  const subscriber = crashSource.replace('import MetricKit', '// Inert MetricKit types supplied by the fixture.');
  function run(name, models, callbackSource) {
    const source = join(out, name + '.swift');
    writeFileSync(source, boundary + models + callbackSource + harness, { flag: 'wx' });
    const binary = join(out, name);
    const compile = spawnSync('/usr/bin/swiftc', ['-parse-as-library', source, '-o', binary],
      { encoding: 'utf8', timeout: 60_000 });
    writeFileSync(join(out, name + '-compile.log'), compile.stdout + compile.stderr, { flag: 'wx' });
    assert.equal(compile.status, 0, compile.stderr);
    const result = spawnSync(binary, [], { encoding: 'utf8', timeout: 30_000 });
    writeFileSync(join(out, name + '-run.log'), result.stdout + result.stderr, { flag: 'wx' });
    return result;
  }
  const actual = run('actual', probeModels, subscriber);
  assert.equal(actual.status, 0, actual.stdout + actual.stderr);
  assert.match(actual.stdout, /PASS: 18 actual admin mapping and diagnostic assertions/);

  const permissionGuard = '        if ok == nil && (errorClass ?? "").lowercased() == "permission" { return .permission }\n';
  assert.equal(probeModels.split(permissionGuard).length - 1, 1);
  const permissionMutant = run('missing-permission-mapping', probeModels.replace(permissionGuard, ''), subscriber);
  assert.equal(permissionMutant.status, 1);
  assert.match(permissionMutant.stdout, /typed nil permission must remain distinct/);

  const metricCallback = declaration(subscriber, 'func didReceive(_ payloads: [MXMetricPayload])');
  const legacyCallback = String.raw`    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let launch = payload.applicationLaunchMetrics,
                  let p50 = Self.medianMilliseconds(launch.histogrammedTimeToFirstDraw) else { continue }
            report("error", ["category": "metrics", "launch_time_ms": String(p50),
                             "app_version": payload.latestApplicationVersion])
        }
    }`;
  const metricsMutant = run('legacy-launch-error', probeModels, subscriber.replace(metricCallback, legacyCallback));
  assert.equal(metricsMutant.status, 1);
  assert.match(metricsMutant.stdout, /routine launch metrics must not count as errors/);

  const paths = [probePath, crashPath, fileURLToPath(import.meta.url)];
  writeFileSync(join(out, 'receipt.json'), JSON.stringify({ accepted: true,
    scope: 'Actual Foundation admin models/helpers plus complete CrashReporter source with inert MetricKit/Analytics boundaries. No device, provider, Apple, network or host preferences execution.',
    actualExit: actual.status, assertions: 18,
    controls: { missingPermissionMappingExit: permissionMutant.status, legacyMetricErrorExit: metricsMutant.status },
    sourceHashes: Object.fromEntries(paths.map(path => [path.slice(root.length), createHash('sha256').update(readFileSync(path)).digest('hex')])),
  }, null, 2) + '\n', { flag: 'wx' });
  console.log(`Admin diagnostic evidence: ${out}\n${actual.stdout.trim()}\nPASS: both copied-source negative controls rejected`);
});
