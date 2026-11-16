import Foundation

struct SpaceType { static let current = Self(); var quickTags: [String] { [] } }
enum Haptics { static func success() {} }
struct CLLocationCoordinate2D: Equatable { var latitude: Double; var longitude: Double }
final class ClosedLocator { var cancellations = 0; func cancel() { cancellations += 1 } }
final class ClosedGeocoder { var cancellations = 0; func cancelGeocode() { cancellations += 1 } }

@main struct NativeFormCommitTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ reason: String) { precondition(value, reason); checks += 1 }
        let room = RoomCommitHarness()
        room.current = 3.125; room.customName = "  Pantry  "; room.customNameFocused = true
        room.tags = [RoomTag(name: "Unconfirmed AI", tMs: 100, isAISuggested: true)]
        room.finishTagging()
        check(room.dismissedTags?.count == 1 && room.dismissedTags?.first?.name == "Pantry", "Done commits the typed custom name before host dismissal")
        check(room.tags.first?.tMs == 3125, "Done uses the current playhead timestamp")
        check(room.customName.isEmpty && !room.customNameFocused, "Done clears committed editor state")
        check(room.dismissedTags?.allSatisfy { !$0.isFromAI } == true, "Done withholds untouched AI suggestions before host dismissal")
        room.finishTagging()
        check(room.tags.count == 1, "Repeated Done cannot duplicate a committed tag")
        let rename = RoomCommitHarness()
        rename.current = 2; rename.customName = "  Kitchen island  "
        rename.tags = [RoomTag(name: "AI room", tMs: 2100, isAISuggested: true, aiConfidence: 0.2)]
        rename.finishTagging()
        check(rename.tags.count == 1 && rename.tags[0].name == "Kitchen island" && !rename.tags[0].isFromAI && rename.tags[0].aiConfidence == nil, "Done accepts a human rename at the same marker without duplication")
        let empty = RoomCommitHarness(); empty.customName = "   "
        empty.finishTagging()
        check(empty.tags.isEmpty && empty.dismissedTags?.isEmpty == true, "Blank Done creates no empty chapter")

        let location = LocationCommitHarness()
        location.form.unit = "1202"
        let coordinate = CLLocationCoordinate2D(latitude: 35.123, longitude: -80.987)
        location.applyLocationSuggestion("100 Synthetic Condo Way, Fixture City", coordinate: coordinate)
        location.addressDidChange(location.form.address)
        check(location.pendingCoord == coordinate, "The location-generated address keeps its own coordinate")
        check(location.form.unit == "1202", "Location lookup preserves the agent's entered unit")
        location.locationRequestID = UUID(); location.locating = true; location.locationGeocoder = ClosedGeocoder()
        let oldGeocoder = location.locationGeocoder!
        location.form.address = "200 Different Property, Fixture City"
        location.addressDidChange(location.form.address)
        check(location.pendingCoord == nil && location.pendingCoordAddress == nil, "Manual address changes discard the prior property's coordinate")
        check(location.locationRequestID == nil && !location.locating && location.locator.cancellations == 1 && oldGeocoder.cancellations == 1, "Manual address changes cancel an in-flight location lookup")
        location.applyLocationSuggestion("300 Another Property #2B, Fixture City", coordinate: coordinate)
        location.addressDidChange(location.form.address)
        check(location.pendingCoord == coordinate && location.form.unit == "2B", "A fresh location suggestion binds a new address and explicit unit")
        location.form.unit = "4C"; location.addressDidChange(location.form.address)
        check(location.pendingCoord == coordinate, "Unit-only edits preserve the property's building coordinate")
        location.form.address = ""; location.addressDidChange("")
        check(location.pendingCoord == nil, "Clearing the address cannot retain stale map data")
        print("PASS: \(checks) actual room Done and address-coordinate commit assertions; closed dismissal/location boundaries")
    }
}
