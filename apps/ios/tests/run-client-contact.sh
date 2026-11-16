#!/usr/bin/env bash
set -euo pipefail
client_contact_test_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
client_contact_test_dir="$(mktemp -d)"
trap 'rm -rf "$client_contact_test_dir"' EXIT
# Compile the actual identity/photo resolver without unrelated SwiftUI screens.
python3 - "$client_contact_test_root/apps/ios/Rendprop/Screens/SettingsView.swift" "$client_contact_test_dir/CardBinding.swift" <<'PY'
import pathlib,sys
source=pathlib.Path(sys.argv[1]).read_text()
def block(anchor):
    start=source.index(anchor); opening=source.index('{',start); depth=0
    for position in range(opening,len(source)):
        if source[position]=='{': depth+=1
        elif source[position]=='}':
            depth-=1
            if depth==0: return source[start:position+1]
    raise AssertionError('Unclosed actual resolver')
header='''import Foundation
struct AgentCard {
var name:String;var brokerage:String;var phone:String;var email:String;var website:String
var instagram="";var linkedin="";var tiktok="";var customHeadshotRelPath:String?=nil
var usesOwnHeadshot=true;var publicAvatarURL:String?=nil
static var current:AgentCard { .init(name:"Photographer",brokerage:"Private business",phone:"5551112222",email:"private@example.invalid",website:"https://private.example.invalid") }
static var headshotURL:URL { URL(fileURLWithPath:"/isolated/photographer-headshot.jpg") }
'''
pathlib.Path(sys.argv[2]).write_text(header+block('    var resolvedHeadshotURL: URL? {')+'\n'+block('    static func forListing(')+'\n}\n')
PY
xcrun swiftc -parse-as-library \
  "$client_contact_test_root/apps/ios/Rendprop/Models/ListingClientContact.swift" \
  "$client_contact_test_root/apps/ios/Rendprop/Models/Listing.swift" \
  "$client_contact_test_root/apps/ios/Rendprop/Models/Money.swift" \
  "$client_contact_test_root/apps/ios/Rendprop/Networking/WorkspaceSync.swift" \
  "$client_contact_test_root/apps/ios/Rendprop/Networking/NativeReelDraft.swift" \
  "$client_contact_test_root/apps/ios/Rendprop/Voice/VoiceTypes.swift" \
  "$client_contact_test_root/apps/ios/tests/ClientContactTests.swift" \
  "$client_contact_test_dir/CardBinding.swift" \
  -o "$client_contact_test_dir/client-contact-tests"
"$client_contact_test_dir/client-contact-tests"
