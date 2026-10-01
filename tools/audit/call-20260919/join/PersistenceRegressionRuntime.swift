@main struct PersistenceRegressionRuntime {
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1])
        FileStore.documents = root
        let fm = FileManager.default
        try fm.createDirectory(at:FileStore.recordingsDir,withIntermediateDirectories:true)
        let url = FileStore.recordingsDir.appendingPathComponent("original.mov")
        let original = Data("synthetic original retained".utf8)
        try original.write(to:url)
        let listing = Listing()
        var asset = CaptureAsset(localURL:url,durationS:30,fps:30,width:1920,height:1080,bytes:Int64(original.count))
        asset.roomTags = [RoomTag(name:"Kitchen",tMs:1000)]
        asset.personVisibleRanges = [TimeRange(startS:2,endS:5),TimeRange(startS:12,endS:16)]
        var assertions = 0
        func check(_ value:Bool,_ message:String) throws {
            guard value else { throw NSError(domain:message,code:1) }; assertions += 1
        }
        try check(PersistentStore.save(listings:[listing],assets:[listing.id:asset],tours:[:],renders:[:]),"save")
        let loaded = PersistentStore.load().assets[listing.id]!
        try check(loaded.personVisibleRanges == asset.personVisibleRanges && loaded.personVisibleSeconds == 7,"range round trip")
        try check(loaded.id == asset.id && loaded.roomTags == asset.roomTags,"other fields unchanged")
        let snapshot = root.appendingPathComponent("rendprop-state.json")
        let bytes = try Data(contentsOf:snapshot)
        var obj = try JSONSerialization.jsonObject(with:bytes) as! [String:Any]
        var assets = obj["assets"] as! [Any]
        var savedAsset = assets[1] as! [String:Any]
        try check(savedAsset["personVisibleRanges"] != nil,"saved key exists")

        savedAsset.removeValue(forKey:"personVisibleRanges")
        assets[1] = savedAsset; obj["assets"] = assets
        try JSONSerialization.data(withJSONObject:obj).write(to:snapshot,options:.atomic)
        let legacy = PersistentStore.load().assets[listing.id]!
        try check(legacy.personVisibleRanges.isEmpty,"older snapshots default empty")
        try check(legacy.id == asset.id && legacy.roomTags == asset.roomTags,"legacy snapshot preserves asset and tags")

        savedAsset["personVisibleRanges"] = [
            ["startS":2,"endS":5], ["startS":-1,"endS":3], ["startS":8,"endS":7],
            ["startS":20,"endS":31], "unreadable range", ["startS":4,"endS":4]
        ] as [Any]
        assets[1] = savedAsset; obj["assets"] = assets
        try JSONSerialization.data(withJSONObject:obj).write(to:snapshot,options:.atomic)
        let salvaged = PersistentStore.load().assets[listing.id]!
        try check(salvaged.personVisibleRanges == [TimeRange(startS:2,endS:5)],"malformed ranges cannot discard valid detection or extend video clock")
        try check(salvaged.id == asset.id && salvaged.roomTags == asset.roomTags,"malformed detection preserves video")
        try check(try Data(contentsOf:url) == original,"source bytes unchanged")
        let result:[String:Any] = ["accepted":true,"assertions":assertions,"restored_ranges":loaded.personVisibleRanges.count,
                                  "restored_seconds":loaded.personVisibleSeconds,"legacy_ranges":legacy.personVisibleRanges.count,
                                  "salvaged_ranges":salvaged.personVisibleRanges.count]
        let evidence=try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
        try evidence.write(to:root.appendingPathComponent("regression-results.json"))
        print(String(decoding:evidence,as:UTF8.self))
    }
}
