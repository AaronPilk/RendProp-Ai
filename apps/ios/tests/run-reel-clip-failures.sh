#!/usr/bin/env bash
set -euo pipefail
reel_clip_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
reel_clip_test_dir="$(mktemp -d)"
trap 'rm -rf "$reel_clip_test_dir"' EXIT
python3 - "$reel_clip_test_root" "$reel_clip_test_dir/Production.swift" "${1:-}" <<'PY'
import pathlib,sys
root=pathlib.Path(sys.argv[1]);source=(root/'apps/ios/Rendprop/Screens/FlythroughDetailView.swift').read_text();api=(root/'apps/ios/Rendprop/Networking/APIClient.swift').read_text()
live=(root/'apps/ios/Rendprop/Networking/LiveAPIClient.swift').read_text()
def block(text,marker):
 assert text.count(marker)==1,marker
 start=text.index(marker);opening=text.index('{',start);depth,end=1,opening+1
 while depth:
  depth+=(text[end]=='{')-(text[end]=='}');end+=1
 return text[start:end]
apierror=block(api,'enum APIError: Error, LocalizedError')
error_adapter='enum LiveErrorFixture {\n'+block(live,'private struct ErrorEnvelope: Decodable')+'\n'+block(live,'static func serverError(status:')+'\n}\n'
job=block(api,'struct AIVideoJob: Codable, Sendable')
camera=block(api,'enum ReelCameraMove: String, CaseIterable, Codable, Sendable')
shot=block(api,'struct AIShot: Sendable, Hashable, Identifiable')
drift=block((root/'apps/ios/Rendprop/Render/DriftCheck.swift').read_text(),'struct DriftVerdict: Sendable, Equatable')
quality=block(source,'private struct ReelQualityRefusal: Error, LocalizedError').replace('private struct','struct',1)
failure=source[source.index('struct AIFailure: Identifiable'):source.index('/// Loud, unmissable failure card')]
issue=source[source.index('struct ReelClipIssue: Identifiable'):source.index('struct ReelStudioView: View')]
renderer=(root/'apps/ios/Rendprop/Render/ReelComposer.swift').read_text()
photo_motion='enum OriginalPhotoMotion {\n'+block(renderer,'    static func isClip(')+'\n}\n'
pending=source[source.index('struct PendingReelClips: Codable'):source.index('// MARK: - Reel Studio (')].replace('private struct','struct')
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
pending=(root/'apps/ios/Rendprop/Render/VideoMusicContract.swift').read_text()+'\n'+(root/'apps/ios/Rendprop/Render/VideoAspectChoice.swift').read_text()+'\n'+(root/'apps/ios/Rendprop/Models/ListingVideo.swift').read_text()+'\n'+helpers+'\n'+pending
assert 'Self.parkClips(billedClips, for: listingID, tmpDir: tmpDir)' in source
assert 'failure = ReelClipIssue.failure(for: error' in source
assert 'Button("Finish video from saved clips") { finishParkedReel() }' in source
assert 'Button("Back to video setup") { resetToSetup() }' in source
assert source.count('clipFailureDetails')>=3
assert 'failure.isServiceUnavailable || failure.isTrialCapacityUnavailable' in source
assert 'f.isServiceUnavailable || f.isTrialCapacityUnavailable' in source
assert 'failure.isServiceUnavailable || failure.isTrialCapacityUnavailable' in (root/'apps/ios/Rendprop/Photos/PhotoEditService.swift').read_text()
if sys.argv[3]=='--inject-swallowed-error':
 assert loop.count('throw error')==1
 loop=loop.replace('throw error','// restored silent continuation')
elif sys.argv[3]=='--inject-lost-fallback-provenance':
 assert loop.count('if OriginalPhotoMotion.isClip(clip) { originalPhotoMotionShots += 1 }')==1
 loop=loop.replace('if OriginalPhotoMotion.isClip(clip) { originalPhotoMotionShots += 1 }','// omitted fallback provenance counter')
elif sys.argv[3]=='--inject-lost-prepared-source':
 assert loop.count('preparedJPEG: batch.flatMap { Data(base64Encoded: $0.photos[i].jpegBase64) }')==1
 loop=loop.replace('preparedJPEG: batch.flatMap { Data(base64Encoded: $0.photos[i].jpegBase64) }','preparedJPEG: nil')
elif sys.argv[3]:raise SystemExit('Unknown test option')
harness=r'''
@MainActor final class ReelBatchHarness {
    var clipIssues: [ReelClipIssue] = []
    var completedClips = 0
    var originalPhotoMotionShots = 0
    var statusText = ""
    var billedClips: [URL] = []
    var stitched = false
    var receivedError: Error?
    let api: ClipAPI
    init(api: ClipAPI) { self.api = api }
    static func shot(for: EnhancedPhoto, in: [AIShot]) -> AIShot? { nil }
    static func makeClip(photo: EnhancedPhoto, prompt: String, shot: AIShot?, shotCount: Int,
                         motion: String, aspect: String, spaceType: String,
                         api: ClipAPI, listingServerID: UUID?, into dir: URL, index: Int,
                         recoveryContext: PendingReelRequest.Context? = nil,
                         requireCurrent: @MainActor @Sendable () throws -> Void = {},
                         preparedJPEG: Data? = nil, framing: String? = nil, sourceAssetID: String? = nil, photoProvenanceID: String? = nil) async throws -> URL {
        api.calls.append(index)
        api.preparedSources.append(preparedJPEG); api.motions.append(motion)
        if let error = api.errors[index] { throw error }
        let prefix = api.originalPhotoMotionIndices.contains(index) ? "clip-photo-motion-" : "clip-"
        let file=dir.appendingPathComponent("\(prefix)\(index).mp4")
        try Data("synthetic completed clip \(index)".utf8).write(to: file)
        return file
    }
    func run(count: Int, listingID: UUID, tmpDir: URL, savedBatch: PendingReelBatch? = nil) async throws {
        try FileManager.default.createDirectory(at: tmpDir,withIntermediateDirectories: true)
        let ordered=(0..<count).map { EnhancedPhoto(id: String($0)) }
        let plan: [AIShot]=[];let prompt="";let reelListingServerID: UUID?=nil
        let selectedMove=ReelCameraMove.flyThrough.rawValue;let isPortrait=true;let spaceRaw="real_estate"
        let recoveryContext: PendingReelRequest.Context?=savedBatch?.context
        var batch = savedBatch
        try batch?.save()
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
pathlib.Path(sys.argv[2]).write_text('import Foundation\nimport CryptoKit\nenum AIImagePrep { static func error(_ m:String)->Error { NSError(domain: \"synthetic\", code:1,userInfo:[NSLocalizedDescriptionKey:m]) } }\n@MainActor final class AIConsent { static let shared=AIConsent();var isGranted=true;var revocationRevision=0 }\n'+photo_motion+'\n'+apierror+'\n'+error_adapter+'\n'+job+'\n'+camera+'\n'+shot+'\n'+drift+'\n'+quality+'\n'+failure+'\n'+issue+'\n'+pending+'\n'+harness.replace('__LOOP__',loop).replace('__PARK__',park))
PY
xcrun swiftc -swift-version 5 -parse-as-library \
  "$reel_clip_test_dir/Production.swift" \
  "$reel_clip_test_root/apps/ios/tests/ReelClipFailureTests.swift" \
  -o "$reel_clip_test_dir/reel-clip-tests"
"$reel_clip_test_dir/reel-clip-tests"
