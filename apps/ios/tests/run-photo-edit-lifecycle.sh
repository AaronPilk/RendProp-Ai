#!/usr/bin/env bash
set -euo pipefail
photo_lifecycle_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
photo_lifecycle_test_dir="$(mktemp -d)"
trap 'rm -rf "$photo_lifecycle_test_dir"' EXIT
python3 - "$photo_lifecycle_test_root/apps/ios/Rendprop/Photos/PhotoEditService.swift" "$photo_lifecycle_test_dir/ServiceLifecycle.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
def block(anchor):
    start=source.index(anchor); opening=source.index('{',start); depth=0
    for position in range(opening,len(source)):
        if source[position]=='{': depth+=1
        elif source[position]=='}':
            depth-=1
            if depth==0: return source[start:position+1]
    raise AssertionError('Unclosed actual lifecycle method')
header='''import Foundation
@MainActor final class PhotoEditService {
private let model:AppModel
private let listing:Listing
private let owner=AuthStore.shared.userID
private let revision=AuthStore.shared.syncSessionRevision
private let workspace=WorkspaceContext.selectedOrgID
private let process:(EnhancedPhoto) async throws -> Void
init(model:AppModel,listing:Listing,process:@escaping (EnhancedPhoto) async throws -> Void) {
self.model=model;self.listing=listing;self.process=process
}
func edit(_ photo:EnhancedPhoto,edit:String,style:String?,prompt:String?,batch:Bool) async throws {
try requireIdentity(); try await process(photo); try requireIdentity()
}
'''
methods=[block(anchor) for anchor in ['    var identityIsCurrent: Bool {','    private func requireIdentity()','    func start(title:','    private func notify(']]
pathlib.Path(sys.argv[2]).write_text(header+'\n'.join(methods)+'\n}\n')
PY
xcrun swiftc -parse-as-library \
  "$photo_lifecycle_test_root/apps/ios/Rendprop/Photos/PhotoWorkQueue.swift" \
  "$photo_lifecycle_test_dir/ServiceLifecycle.swift" \
  "$photo_lifecycle_test_root/apps/ios/tests/PhotoEditLifecycleTests.swift" \
  -o "$photo_lifecycle_test_dir/photo-lifecycle-tests"
"$photo_lifecycle_test_dir/photo-lifecycle-tests"
