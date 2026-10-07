#!/usr/bin/env bash
set -euo pipefail
reel_clip_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reel_clip_test_dir="$(mktemp -d)"
trap 'rm -rf "$reel_clip_test_dir"' EXIT
python3 - "$reel_clip_test_root" "$reel_clip_test_dir/Production.swift" "${1:-}" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);source=(root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift').read_text();api=(root/'apps/ios/Rendprop/Networking/APIClient.swift').read_text()
def block(text,marker):
 assert text.count(marker)==1,marker
 start=text.index(marker);opening=text.index('{',start);depth,end=1,opening+1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
apierror=block(api,'enum APIError: Error, LocalizedError')
job=block(api,'struct AIVideoJob: Codable, Sendable')
failure=source[source.index('struct AIFailure: Identifiable'):source.index('/// Loud, unmissable failure card')]
issue=source[source.index('struct ReelClipIssue: Identifiable'):source.index('struct ReelStudioView: View')]
pending=source[source.index('private struct PendingReelClips: Codable'):source.index('// MARK: - Reel Studio (')].replace('private struct','struct')
adoption=block((root/'apps/ios/Rendprop/Auth/AdoptionProductionLibrary.swift').read_text(),'enum AdoptionOwnedIdentity {')
helpers='enum AdoptionOwnedIdentity {\n'+'\n'.join(block(adoption,anchor) for anchor in [
 'enum Failure: Error', 'struct Card: Codable, Equatable','struct PaidRequest: Codable, Equatable','struct Journal: Codable, Equatable',
 'static func prefix(','static func requestKey(','static func requestFile(','private static func digest(',
 'private static func absentFile(','static func pathIsOccupied(','static func unselectedReviewFiles(','static func forgetUnselectedReviews('])+'\n}\n'
helpers=helpers.replace('defaults: UserDefaults','defaults: Foundation.UserDefaults')
space=(root/'apps/ios/Rendprop/Models/Listing.swift').read_text()
cases=space[space.index('    case realEstate =',space.index('enum SpaceType:')):space.index('    var id:',space.index('enum SpaceType:'))]
helpers+='enum SpaceType: String {\n'+cases+'}\n'
loop=block(source,'                for (i, photo) in ordered.enumerated()')
park=block(source,'    nonisolated private static func parkClips(').replace('private static','static',1)
pending=helpers+'\n'+pending
assert 'Self.parkClips(billedClips, for: listingID, tmpDir: tmpDir)' in source
assert 'failure = ReelClipIssue.failure(for: error' in source
assert 'Button("Finish reel from saved clips") { finishParkedReel() }' in source
assert 'Button("Back to reel setup") { resetToSetup() }' in source
assert source.count('clipFailureDetails')>=3
if sys.argv[3]=='--inject-swallowed-error':
 assert loop.count('throw error')==1
 loop=loop.replace('throw error','// restored silent continuation')
elif sys.argv[3]:raise SystemExit('Unknown test option')
harness=r'''
@MainActor final class ReelBatchHarness {
    var clipIssues: [ReelClipIssue] = []
    var completedClips = 0
    var statusText = ""
    var billedClips: [URL] = []
    var stitched = false
    var receivedError: Error?
    let api: ClipAPI
    init(api: ClipAPI) { self.api = api }
    static func shot(for: EnhancedPhoto, in: [AIShot]) -> AIShot? { nil }
    static func makeClip(photo: EnhancedPhoto, prompt: String, shot: AIShot?, shotCount: Int,
                         api: ClipAPI, listingServerID: UUID?, into dir: URL, index: Int,
                         recoveryContext: PendingReelRequest.Context? = nil,
                         requireCurrent: @MainActor @Sendable () throws -> Void = {}) async throws -> URL {
        api.calls.append(index)
        if let error = api.errors[index] { throw error }
        let file=dir.appendingPathComponent("clip-\(index).mp4")
        try Data("synthetic completed clip \(index)".utf8).write(to: file)
        return file
    }
    func run(count: Int, listingID: UUID, tmpDir: URL) async throws {
        try FileManager.default.createDirectory(at: tmpDir,withIntermediateDirectories: true)
        let ordered=(0..<count).map { EnhancedPhoto(id: String($0)) }
        let plan: [AIShot]=[];let prompt="";let reelListingServerID: UUID?=nil
        let recoveryContext: PendingReelRequest.Context?=nil
        let requireCurrent: @MainActor @Sendable () throws -> Void = { try Task.checkCancellation() }
        let reelConsentRevision=AIConsent.shared.revocationRevision
        var clipURLs: [URL]=[];var usedShots: [AIShot?]=[]
        do {
__LOOP__
            stitched = !clipURLs.isEmpty
            try FileManager.default.removeItem(at: tmpDir)
        } catch {
            Self.parkClips(billedClips,for: listingID,tmpDir: tmpDir)
            receivedError=error
        }
    }
__PARK__
}
'''
pathlib.Path(sys.argv[2]).write_text('import Foundation\nimport CryptoKit\nenum AIImagePrep { static func error(_ m:String)->Error { NSError(domain: \"synthetic\", code:1,userInfo:[NSLocalizedDescriptionKey:m]) } }\n@MainActor final class AIConsent { static let shared=AIConsent();var isGranted=true;var revocationRevision=0 }\n'+apierror+'\n'+job+'\n'+failure+'\n'+issue+'\n'+pending+'\n'+harness.replace('__LOOP__',loop).replace('__PARK__',park))
PY
xcrun swiftc -swift-version 5 -parse-as-library \
  "$reel_clip_test_dir/Production.swift" \
  "$reel_clip_test_root/apps/ios/tests/ReelClipFailureTests.swift" \
  -o "$reel_clip_test_dir/reel-clip-tests"
"$reel_clip_test_dir/reel-clip-tests"
