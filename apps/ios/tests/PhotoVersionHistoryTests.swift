import Foundation

@main
struct PhotoVersionHistoryTests {
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message); checks += 1
        }
        func rejected(_ message: String, _ operation: () throws -> Void) {
            do { try operation(); preconditionFailure(message) } catch { checks += 1 }
        }
        for flags in 0..<16 {
            var review = PhotoVersionHistory.StagingReview()
            review.comparedSource = flags & 1 != 0
            review.fixedFeaturesMatch = flags & 2 != 0
            review.accessIsClear = flags & 4 != 0
            review.furnitureMatchesOtherViews = flags & 8 != 0
            check(review.isComplete == (flags == 15), "staging review requires source, fixed features, access and other-view checks")
            var customReview = PhotoVersionHistory.CustomReview()
            customReview.comparedSource = flags & 1 != 0
            customReview.fixedFeaturesMatch = flags & 2 != 0
            customReview.colorsAndMaterialsMatch = flags & 4 != 0
            customReview.onlyRequestedChange = flags & 8 != 0
            check(customReview.isComplete == (flags == 15), "custom review requires actual source comparison, fixed features, colors/materials and requested-change checks")
        }
        for text in ["repaint the garage white", "make the garage door white", "change the color of the trim", "hide the wall crack", "repair the roof", "remove the wall", "replace the windows", "make it brighter and repaint the garage white", "make it look freshly painted white with warm evening light", "repainting the garage and improve lighting", "re\u{200B}paint garage and lighting", "chànge trím color and lighting", "répair roof and lighting", "repaint\u{2060}ing garage and lighting", "ｒｅｐａｉｎｔ garage and lighting"] {
            check(CustomPhotoPromptPolicy.decision(for: text, realEstate: true) == .blocked, "explicit permanent property changes are refused rather than silently interpreted: \(text)")
        }
        for text in ["make it better", "make it nicer", "modernize garage", "clean garage", "clean house", "make this modern", "change this", "improve lighting and make house nicer", "make the garage modern"] {
            check(CustomPhotoPromptPolicy.decision(for: text, realEstate: true) == .clarify, "ambiguous property request needs a plain choice before generation: \(text)")
        }
        for text in ["brighten exposure only; preserve all colors", "remove bags", "add modern furniture", "do not repaint the garage; improve lighting only", "Don't repair the roof, replace only the sky", "make the lawn greener", "remove my reflection"] {
            check(CustomPhotoPromptPolicy.decision(for: text, realEstate: true) == .ready, "specific benign scope and protective negations remain available: \(text)")
        }
        for choice in CustomPhotoPromptPolicy.Choice.allCases {
            check(CustomPhotoPromptPolicy.decision(for: choice.prompt, realEstate: true) == .ready, "every offered clarification choice can reach a prepared review")
            check(choice.prompt.count <= 600, "clarification instruction fits the same full request contract")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-history-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("home")
        let original = Data("unaltered-capture".utf8), enhanced = Data("local-enhancement".utf8)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "capture", directory: dir)
        var index = try PhotoVersionHistory.load(directory: dir)
        check(index.versions.count == 1, "capture persisted")
        check(index.versions["capture"]?.originalVerified == true, "retained capture explicitly known")
        check(index.versions["capture"]?.visibleLabel == nil, "exposure enhancement is not staging")
        check(index.current["capture"] == "capture", "capture current")
        let before = try Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))
        check(before == original, "retained bytes intact")

        let declutter = try PhotoVersionHistory.saveEdit(jpeg: Data("decluttered".utf8), id: "declutter", parentID: "capture", sourceID: "capture",
            edit: "declutter", style: nil, disclosure: "Items digitally removed.", provenanceID: "provider-row", provenanceRecorded: true, directory: dir)
        check(declutter.originalFile == "orig-capture.jpg", "declutter uses true root original")
        check(declutter.visibleLabel == "Digitally decluttered", "declutter not mislabeled staging")
        index = try PhotoVersionHistory.load(directory: dir)
        check(!index.isVisible("capture") && index.isVisible("declutter"), "only latest primary visible")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("enh-capture.jpg").path), "superseded file retained for existing reel")
        check(index.versions["declutter"]?.disclosure == "Items digitally removed.", "disclosure survives disk reload")
        check(index.versions["declutter"]?.provenanceID == "provider-row", "provenance row survives disk reload")
        check(index.versions["declutter"]?.provenanceRecorded == true, "recording status retained")

        let stagingInput = try PhotoVersionHistory.source(for: "declutter", edit: "stage", directory: dir)
        check(stagingInput.id == "declutter", "first stage uses decluttered image")
        let stage = try PhotoVersionHistory.saveEdit(jpeg: Data("modern-furniture".utf8), id: "stage", parentID: "declutter", sourceID: stagingInput.id,
            edit: "stage", style: "modern", disclosure: "Furniture digitally added. The architecture, dimensions, and views are unchanged.", provenanceID: nil, provenanceRecorded: false, directory: dir)
        check(stage.disclosure?.contains("are unchanged") == true, "historical audit sentence remains immutable")
        check(stage.reviewDisclosure?.contains("are unchanged") == false, "native presentation does not certify AI geometry")
        check(stage.caption.contains("Compare with the original") && !stage.caption.contains("are unchanged"), "download caption uses honest review disclosure")
        check(stage.originalFile == "orig-capture.jpg", "declutter to stage preserves true original")
        check(stage.stagingBaseID == "declutter", "pre-furniture image persisted")
        check(stage.visibleLabel == "Virtually staged · Digitally decluttered", "both actual alterations disclosed")
        let restyleInput = try PhotoVersionHistory.source(for: "stage", edit: "stage", directory: dir)
        check(restyleInput.id == "declutter", "relaunch restyle uses pre-furniture image")
        let rustic = try PhotoVersionHistory.saveEdit(jpeg: Data("rustic-furniture".utf8), id: "rustic", parentID: "stage", sourceID: restyleInput.id,
            edit: "stage", style: "rustic", disclosure: "Rustic virtual staging.", provenanceID: nil, provenanceRecorded: false, directory: dir)
        check(rustic.sourceID == "declutter" && rustic.parentID == "stage", "record input and superseded version separately")
        check(rustic.effects == ["declutter", "stage"], "restyling does not accumulate duplicate furniture effects")
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.history(for: "rustic").count == 4, "all four versions remain accessible")
        check(index.current["capture"] == "rustic", "latest remains current after relaunch")
        check((try? Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))) == original, "edits never replace original")
        rejected("stale edit cannot create second primary") {
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("late".utf8), id: "late", parentID: "stage", sourceID: "stage", edit: "sky", style: nil,
                disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: dir)
        }
        check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("edit-late.jpg").path), "failed stale write leaves no visible image")
        rejected("duplicate capture cannot overwrite original") {
            try PhotoVersionHistory.saveCapture(original: Data("bad".utf8), enhanced: Data("bad".utf8), id: "capture", directory: dir)
        }
        check((try? Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))) == original, "collision preserves originals")

        check(index.listingSelections?["capture"] == "declutter", "unreviewed staging keeps approved declutter on public listing")
        rejected("unreviewed staging cannot be a furnishing reference") { _ = try PhotoVersionHistory.stagingReference(id: "stage", directory: dir) }
        rejected("declutter cannot be mislabeled as a reviewed furnishing reference") { _ = try PhotoVersionHistory.stagingReference(id: "declutter", directory: dir) }
        rejected("staging cannot bypass review through cover selection") { try PhotoVersionHistory.select(id: "stage", directory: dir) }
        rejected("staging cannot bypass review through publication selection") { try PhotoVersionHistory.selectForPublication(id: "stage", directory: dir) }
        try PhotoVersionHistory.select(id: "stage", directory: dir, reviewed: true)
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.current["capture"] == "stage" && index.listingSelections?["capture"] == "stage", "reviewed saved version selected without a paid rerun")
        check(index.versions["stage"]?.stagingReviewed == true, "explicit source/access/room review persists for reference eligibility")
        check((try? PhotoVersionHistory.stagingReference(id: "stage", directory: dir))?.id == "stage", "reviewed retained staging is eligible in the same listing directory")
        rejected("another listing directory cannot resolve this furnishing reference") { _ = try PhotoVersionHistory.stagingReference(id: "stage", directory: root.appendingPathComponent("other-listing")) }
        let referenceDir = root.appendingPathComponent("reference-lineage")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "room", directory: referenceDir)
        _ = try PhotoVersionHistory.saveEdit(jpeg: Data("reference".utf8), id: "reviewed", parentID: "room", sourceID: "room", edit: "stage", style: "modern", disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: referenceDir)
        try PhotoVersionHistory.selectForPublication(id: "reviewed", directory: referenceDir, reviewed: true)
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "angle", directory: referenceDir)
        let referenced = try PhotoVersionHistory.saveEdit(jpeg: Data("other-angle".utf8), id: "consistent-intent", parentID: "angle", sourceID: "angle", edit: "stage", style: "modern", disclosure: "Review before publishing", provenanceID: "provider", provenanceRecorded: true, directory: referenceDir, stagingReferenceID: "reviewed", stagingBrief: "Oak bed along the back wall")
        check(referenced.stagingReferenceID == "reviewed" && referenced.stagingBrief == "Oak bed along the back wall", "reference and furnishing brief retained with exact output lineage")
        check(referenced.sourceID == "angle" && referenced.originalFile == "orig-angle.jpg", "furnishing reference cannot replace the target's source or original")
        check(referenced.stagingReviewed == nil, "reviewed reference cannot approve a new output")
        check((try? PhotoVersionHistory.load(directory: referenceDir))?.versions["consistent-intent"]?.stagingReferenceID == "reviewed", "reference metadata survives reload")
        try PhotoVersionHistory.hide(id: "reviewed", directory: referenceDir)
        rejected("hidden reviewed reference cannot be sent by a new edit") { _ = try PhotoVersionHistory.stagingReference(id: "reviewed", directory: referenceDir) }
        try PhotoVersionHistory.select(id: "declutter", directory: dir)
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.current["capture"] == "declutter" && index.listingSelections?["capture"] == "declutter", "declutter restored after staging")
        check(index.versions.count == 4 && (try? Data(contentsOf: dir.appendingPathComponent("edit-rustic.jpg"))) != nil, "reverting preserves rejected staging and lineage")
        // A source/access/furniture review belongs to this exact saved version.
        // Switching to the clean photo does not erase it or require a paid rerun.
        check(index.versions["stage"]?.stagingReviewed == true, "review remains persisted after switching to declutter")
        do { try PhotoVersionHistory.selectForPublication(id: "stage", directory: dir) }
        catch { preconditionFailure("previously reviewed staging can be reselected for publication") }
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.listingSelections?["capture"] == "stage", "publication reselects the exact previously reviewed staged version")
        check(index.current["capture"] == "declutter", "publication reselect leaves the current editing workspace unchanged")
        try PhotoVersionHistory.selectForPublication(id: "declutter", directory: dir)
        do { try PhotoVersionHistory.select(id: "stage", directory: dir) }
        catch { preconditionFailure("previously reviewed staging can be reselected through cover selection") }
        index = try PhotoVersionHistory.load(directory: dir)
        check(index.current["capture"] == "stage" && index.listingSelections?["capture"] == "stage", "cover reselect uses the persisted review for the exact version")
        check((try? Data(contentsOf: dir.appendingPathComponent("orig-capture.jpg"))) == original, "reviewed-stage reselection never changes retained original bytes")
        rejected("review of one stage cannot approve another stage in the same family") { try PhotoVersionHistory.selectForPublication(id: "rustic", directory: dir) }
        rejected("cover reselect cannot inherit review from a different stage") { try PhotoVersionHistory.select(id: "rustic", directory: dir) }
        try PhotoVersionHistory.select(id: "declutter", directory: dir)
        rejected("missing saved version cannot become public") { try PhotoVersionHistory.select(id: "missing", directory: dir) }
        let publishChoices = try PhotoVersionHistory.publicationVersions(directory: dir)
        check(publishChoices?.map(\.id) == ["declutter"], "publication uses reviewed versions rather than newest staging")
        let missingSelected = dir.appendingPathComponent("edit-declutter.jpg")
        let retainedSelected = try Data(contentsOf: missingSelected)
        try FileManager.default.removeItem(at: missingSelected)
        rejected("missing selected publication file preserves cloud rather than clearing it") { _ = try PhotoVersionHistory.publicationVersions(directory: dir) }
        try retainedSelected.write(to: missingSelected)
        let indexURL = dir.appendingPathComponent(".photo-history.json")
        let goodIndex = try Data(contentsOf: indexURL)
        try Data("corrupt".utf8).write(to: indexURL)
        rejected("corrupt publication index cannot silently fall back to old photos") { _ = try PhotoVersionHistory.publicationVersions(directory: dir) }
        try goodIndex.write(to: indexURL)
        try PhotoVersionHistory.select(id: "rustic", directory: dir, reviewed: true)
        try PhotoVersionHistory.hide(id: "rustic", directory: dir)
        index = try PhotoVersionHistory.load(directory: dir)
        check(!index.isVisible("rustic") && !index.isVisible("capture"), "gallery removal does not resurrect a predecessor")
        check(index.history(for: "rustic").count == 4, "gallery removal preserves history")
        check(FileManager.default.fileExists(atPath: dir.appendingPathComponent("edit-stage.jpg").path), "gallery removal preserves old reel sources")
        rejected("hidden family cannot be republished through stale compare") { try PhotoVersionHistory.select(id: "stage", directory: dir) }
        rejected("hidden family cannot accept delayed edit") { _ = try PhotoVersionHistory.source(for: "rustic", edit: "sky", directory: dir) }

        let legacyDir = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try Data("old-altered-photo".utf8).write(to: legacyDir.appendingPathComponent("enh-old.jpg"))
        try Data("prior-altered-photo".utf8).write(to: legacyDir.appendingPathComponent("orig-old.jpg"))
        let legacy = try PhotoVersionHistory.trackExisting(id: "old", imageFile: "enh-old.jpg", priorFile: "orig-old.jpg", directory: legacyDir)
        check(!legacy.originalVerified && !legacy.sourceHistoryKnown, "legacy orig file never silently certified")
        check(legacy.visibleLabel == "Earlier edits unverified", "legacy uncertainty visible")
        let legacyEdit = try PhotoVersionHistory.saveEdit(jpeg: Data("new-ai-photo".utf8), id: "new", parentID: "old", sourceID: "old",
            edit: "sky", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: legacyDir)
        check(!legacyEdit.originalVerified && !legacyEdit.sourceHistoryKnown, "new edit cannot launder unknown history")
        check(legacyEdit.originalFile == "orig-old.jpg", "earlier source preserved without relabeling")
        check(legacyEdit.visibleLabel == "AI edited · Earlier edits unverified", "known edit and unknown ancestry both shown")
        rejected("traversal rejected") { _ = try PhotoVersionHistory.trackExisting(id: "bad", imageFile: "../enh-old.jpg", priorFile: nil, directory: legacyDir) }
        rejected("unrelated family source rejected") {
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("x".utf8), id: "wrong", parentID: "new", sourceID: "capture", edit: "sky", style: nil,
                disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: legacyDir)
        }
        try FileManager.default.removeItem(at: legacyDir.appendingPathComponent("edit-new.jpg"))
        rejected("missing source does not silently fall back") { _ = try PhotoVersionHistory.source(for: "new", edit: "sky", directory: legacyDir) }
        let badDir = root.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: badDir, withIntermediateDirectories: true)
        try Data("broken-json".utf8).write(to: badDir.appendingPathComponent(".photo-history.json"))
        rejected("corrupt history refuses new writes") {
            try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "new", directory: badDir)
        }
        check(!FileManager.default.fileExists(atPath: badDir.appendingPathComponent("enh-new.jpg").path), "corrupt history does not leave untracked ingest")

        enum DiskFailure: Error { case full }
        let failureDir = root.appendingPathComponent("metadata-failure")
        rejected("metadata failure rolls back freshly written capture pair") {
            try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "retry", directory: failureDir) { bytes, url in
                if url.lastPathComponent == ".photo-history.json" { throw DiskFailure.full }
                try bytes.write(to: url, options: .atomic)
            }
        }
        check(!FileManager.default.fileExists(atPath: failureDir.appendingPathComponent("orig-retry.jpg").path)
              && !FileManager.default.fileExists(atPath: failureDir.appendingPathComponent("enh-retry.jpg").path),
              "failed metadata leaves no orphan current photo")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "retry", directory: failureDir)
        rejected("edit metadata failure must not replace current photo") {
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("new-output".utf8), id: "failed-edit", parentID: "retry", sourceID: "retry",
                edit: "declutter", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: failureDir) { bytes, url in
                    if url.lastPathComponent == ".photo-history.json" { throw DiskFailure.full }
                    try bytes.write(to: url, options: .atomic)
                }
        }
        let unchanged = try PhotoVersionHistory.load(directory: failureDir)
        check(unchanged.current["retry"] == "retry" && unchanged.versions.count == 1, "prior current/history survives metadata failure")
        check(!FileManager.default.fileExists(atPath: failureDir.appendingPathComponent("edit-failed-edit.jpg").path), "uncommitted AI output cleaned up")
        check((try? Data(contentsOf: failureDir.appendingPathComponent("orig-retry.jpg"))) == original, "metadata failure never deletes existing original")

        // Saved-library browsing and the public selection are separate from
        // the editing workspace. Use two families and multiple restyles so a
        // latest-only grid or staging-derived "declutter" cannot pass.
        let libraryDir = root.appendingPathComponent("separate-libraries")
        var latestByFamily: [String: String] = [:]
        var cleanByFamily: [String: String] = [:]
        for family in ["living", "bedroom"] {
            try PhotoVersionHistory.saveCapture(original: Data("original-\(family)".utf8),
                enhanced: Data("enhanced-\(family)".utf8), id: family, directory: libraryDir)
            let firstClean = family + "-clean-1", secondClean = family + "-clean-2"
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("clean-1-\(family)".utf8), id: firstClean,
                parentID: family, sourceID: family, edit: "declutter", style: nil, disclosure: nil,
                provenanceID: nil, provenanceRecorded: false, directory: libraryDir)
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("clean-2-\(family)".utf8), id: secondClean,
                parentID: firstClean, sourceID: firstClean, edit: "declutter", style: nil, disclosure: nil,
                provenanceID: nil, provenanceRecorded: false, directory: libraryDir)
            let firstStage = family + "-modern", secondStage = family + "-rustic"
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("modern-\(family)".utf8), id: firstStage,
                parentID: secondClean, sourceID: secondClean, edit: "stage", style: "modern", disclosure: nil,
                provenanceID: nil, provenanceRecorded: false, directory: libraryDir)
            let restyleSource = try PhotoVersionHistory.source(for: firstStage, edit: "stage", directory: libraryDir)
            _ = try PhotoVersionHistory.saveEdit(jpeg: Data("rustic-\(family)".utf8), id: secondStage,
                parentID: firstStage, sourceID: restyleSource.id, edit: "stage", style: "rustic", disclosure: nil,
                provenanceID: nil, provenanceRecorded: false, directory: libraryDir)
            latestByFamily[family] = secondStage; cleanByFamily[family] = secondClean
            check(restyleSource.id == secondClean, "restyling uses retained furniture-free source")
        }
        let libraryIndexURL = libraryDir.appendingPathComponent(".photo-history.json")
        let beforeBrowsing = try Data(contentsOf: libraryIndexURL)
        let browseIndex = try PhotoVersionHistory.load(directory: libraryDir)
        let latestLibrary = browseIndex.libraryVersions(.latest)
        let cleanLibrary = browseIndex.libraryVersions(.decluttered)
        let stageLibrary = browseIndex.libraryVersions(.staged)
        check(latestLibrary.count == 2 && stageLibrary.count == 2 && cleanLibrary.count == 2, "each library keeps one version per family")
        check(Dictionary(uniqueKeysWithValues: latestLibrary.map { ($0.familyID, $0.id) }) == latestByFamily, "latest library remains the editing workspace's current versions")
        check(Dictionary(uniqueKeysWithValues: stageLibrary.map { ($0.familyID, $0.id) }) == latestByFamily, "staged library keeps newest restyle per family")
        check(Dictionary(uniqueKeysWithValues: cleanLibrary.map { ($0.familyID, $0.id) }) == cleanByFamily, "declutter library keeps newest clean source after two staging outputs")
        check(cleanLibrary.allSatisfy { $0.effects == ["declutter"] }, "declutter exports cannot include furniture effects inherited by staging")
        check(stageLibrary.allSatisfy { $0.effects == ["declutter", "stage"] }, "staged outputs retain truthful declutter lineage")
        check((try? Data(contentsOf: libraryIndexURL)) == beforeBrowsing, "loading and browsing libraries performs no history-state write")
        for version in cleanLibrary {
            let cleanBytes = try Data(contentsOf: libraryDir.appendingPathComponent(version.imageFile))
            check(cleanBytes == Data("clean-2-\(version.familyID)".utf8), "downloadable declutter bytes remain separate from staging")
            check(version.originalFile == "orig-\(version.familyID).jpg", "declutter download still points to the retained unaltered source")
            check((try? Data(contentsOf: libraryDir.appendingPathComponent(version.originalFile!))) == Data("original-\(version.familyID)".utf8), "library review never changes original pixels")
            try PhotoVersionHistory.selectForPublication(id: version.id, directory: libraryDir)
            let publicationIndex = try PhotoVersionHistory.load(directory: libraryDir)
            check(publicationIndex.current == latestByFamily, "public selection must not replace current editing/staging versions")
            check(publicationIndex.isSelectedForListing(version.id), "chosen clean version is the public selection")
            check(!publicationIndex.isSelectedForListing(latestByFamily[version.familyID]!), "newest staging stays unapproved after choosing declutter")
            check(publicationIndex.versions.count == 10, "public selection retains all source, declutter and staging versions")
        }
        let cleanPublished = try PhotoVersionHistory.publicationVersions(directory: libraryDir)!
        check(Set(cleanPublished.map(\.id)) == Set(cleanByFamily.values), "publication exports reviewed clean versions for both families")
        let indexBeforeReject = try Data(contentsOf: libraryIndexURL)
        let missingCleanURL = libraryDir.appendingPathComponent("edit-living-clean-2.jpg")
        let cleanSavedBytes = try Data(contentsOf: missingCleanURL)
        try FileManager.default.removeItem(at: missingCleanURL)
        rejected("missing public-choice image fails closed") { try PhotoVersionHistory.selectForPublication(id: "living-clean-2", directory: libraryDir) }
        rejected("missing selected image cannot silently publish a staged replacement") { _ = try PhotoVersionHistory.publicationVersions(directory: libraryDir) }
        check((try? Data(contentsOf: libraryIndexURL)) == indexBeforeReject, "failed public choice cannot alter history or selection")
        try Data().write(to: missingCleanURL)
        rejected("empty public-choice image fails closed") { try PhotoVersionHistory.selectForPublication(id: "living-clean-2", directory: libraryDir) }
        try cleanSavedBytes.write(to: missingCleanURL)
        rejected("unknown version cannot be selected through a stale saved-library item") { try PhotoVersionHistory.selectForPublication(id: "not-a-version", directory: libraryDir) }
        check((try? Data(contentsOf: libraryIndexURL)) == indexBeforeReject, "unknown/empty selection rejection is also read only")
        try PhotoVersionHistory.hide(id: "living-rustic", directory: libraryDir)
        let hiddenIndex = try PhotoVersionHistory.load(directory: libraryDir)
        for kind in PhotoVersionHistory.LibraryKind.allCases {
            let visible = hiddenIndex.libraryVersions(kind)
            check(visible.count == 1 && visible[0].familyID == "bedroom", "every library excludes the whole hidden living-room family")
        }
        let beforeHiddenReject = try Data(contentsOf: libraryIndexURL)
        rejected("hidden clean version cannot be selected from an old compare sheet") { try PhotoVersionHistory.selectForPublication(id: "living-clean-2", directory: libraryDir) }
        check((try? Data(contentsOf: libraryIndexURL)) == beforeHiddenReject, "hidden-family selection rejection preserves current and public state")
        let visiblePublished = try PhotoVersionHistory.publicationVersions(directory: libraryDir)
        check(visiblePublished?.map(\.familyID) == ["bedroom"], "hidden family stays off publication without resurrecting an earlier image")

        // Real migration sequence: three siblings, no index, then exactly one
        // mutation. A one-photo fixture cannot detect a shrinking gallery.
        for mutation in ["capture", "edit", "remove"] {
            let older = root.appendingPathComponent("three-legacy-\(mutation)")
            try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
            for id in ["old-a", "old-b", "old-c"] {
                try Data("earlier-output-\(id)".utf8).write(to: older.appendingPathComponent("enh-\(id).jpg"))
                try Data("earlier-source-\(id)".utf8).write(to: older.appendingPathComponent("orig-\(id).jpg"))
            }
            let previousBytes = try Dictionary(uniqueKeysWithValues: ["old-a", "old-b", "old-c"].map {
                ($0, try Data(contentsOf: older.appendingPathComponent("enh-\($0).jpg")))
            })
            switch mutation {
            case "capture":
                try PhotoVersionHistory.saveCapture(original: Data("new-source".utf8), enhanced: Data("new-output".utf8), id: "new-photo", directory: older)
            case "edit":
                _ = try PhotoVersionHistory.trackExisting(id: "old-a", imageFile: "enh-old-a.jpg", priorFile: "orig-old-a.jpg", directory: older)
                _ = try PhotoVersionHistory.saveEdit(jpeg: Data("clean-output".utf8), id: "old-a-clean", parentID: "old-a", sourceID: "old-a",
                    edit: "declutter", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: older)
            default:
                _ = try PhotoVersionHistory.trackExisting(id: "old-a", imageFile: "enh-old-a.jpg", priorFile: "orig-old-a.jpg", directory: older)
                try PhotoVersionHistory.hide(id: "old-a", directory: older)
            }
            let published = try PhotoVersionHistory.publicationVersions(directory: older)!
            let expected: Set<String> = mutation == "capture" ? ["old-a", "old-b", "old-c", "new-photo"]
                : mutation == "edit" ? ["old-a-clean", "old-b", "old-c"] : ["old-b", "old-c"]
            check(Set(published.map(\.id)) == expected, "first \(mutation) reconciles every pre-history gallery sibling")
            let reconciled = try PhotoVersionHistory.load(directory: older)
            for id in ["old-a", "old-b", "old-c"] {
                check(reconciled.versions[id]?.originalVerified == false && reconciled.versions[id]?.sourceHistoryKnown == false,
                      "adoption keeps \(id) provenance unverified")
                check((try? Data(contentsOf: older.appendingPathComponent("enh-\(id).jpg"))) == previousBytes[id], "first mutation retains all legacy photo bytes")
            }
            // An explicit legacy cover choice must also be the gallery choice.
            try PhotoVersionHistory.selectForPublication(id: "old-b", directory: older)
            check((try? PhotoVersionHistory.load(directory: older).isSelectedForListing("old-b")) == true, "legacy cover is selected for publication")
            check((try? Set(PhotoVersionHistory.publicationVersions(directory: older)!.map(\.id))) == expected, "cover selection retains sibling gallery membership")
        }

        let partial = try PhotoVersionHistory.load(directory: libraryDir)
        check(partial.publicationLabel(for: "bedroom-rustic") == "Decluttered version on listing", "latest staging identifies selected decluttered predecessor")
        let selectedFile = libraryDir.appendingPathComponent("edit-bedroom-clean-2.jpg")
        let selectedBytes = try Data(contentsOf: selectedFile)
        try FileManager.default.removeItem(at: selectedFile)
        rejected("missing family still fences wholesale publication") { _ = try PhotoVersionHistory.publicationVersions(directory: libraryDir) }
        check((try? PhotoVersionHistory.load(directory: libraryDir).publicationLabel(for: "bedroom-rustic")) == "Decluttered version on listing", "missing selected bytes do not erase family selection metadata")
        try selectedBytes.write(to: selectedFile)
        check((try? PhotoVersionHistory.familyContains(id: "bedroom-rustic", imageFile: "edit-bedroom-clean-2.jpg", directory: libraryDir)) == true, "hidden earlier cover is resolved by family")
        check((try? PhotoVersionHistory.availableCoverVersion(directory: libraryDir)?.effects.contains("stage")) == false, "fallback cover uses approved clean version rather than latest staging")

        let cloudDir = root.appendingPathComponent("cloud-import")
        try FileManager.default.createDirectory(at: cloudDir, withIntermediateDirectories: true)
        try Data("old-photo".utf8).write(to: cloudDir.appendingPathComponent("enh-neighbor.jpg"))
        try Data("cloud-original".utf8).write(to: cloudDir.appendingPathComponent("orig-cloud.jpg"))
        try Data("cloud-staging".utf8).write(to: cloudDir.appendingPathComponent("cloud-photo-cloud.jpg"))
        try PhotoVersionHistory.registerImport(id: "cloud", imageFile: "cloud-photo-cloud.jpg", originalFile: "orig-cloud.jpg", staged: true, altered: true, directory: cloudDir)
        let imported = try PhotoVersionHistory.load(directory: cloudDir)
        check(imported.current["cloud"] == "cloud" && imported.listingSelections?["cloud"] == "cloud-source", "staged cloud import keeps preview separate from publication")
        check(imported.versions["cloud"]?.effects == ["stage"] && imported.versions["cloud"]?.originalVerified == false, "cloud import retains staged disclosure without certifying original")
        check(imported.publicationLabel(for: "cloud") == "Earlier version on listing", "imported staging explains selected source")
        check((try? Set(PhotoVersionHistory.publicationVersions(directory: cloudDir)!.map(\.id))) == ["neighbor", "cloud-source"], "cloud import retains pre-history neighbors and a complete selected source")
        rejected("unreviewed cloud staging cannot become cover") { try PhotoVersionHistory.selectForPublication(id: "cloud", directory: cloudDir) }
        try PhotoVersionHistory.selectForPublication(id: "cloud", directory: cloudDir, reviewed: true)
        check((try? PhotoVersionHistory.load(directory: cloudDir).isSelectedForListing("cloud")) == true, "explicit cloud review enables staged publication")
        try PhotoVersionHistory.selectForPublication(id: "cloud", directory: cloudDir)
        check((try? PhotoVersionHistory.source(for: "cloud", edit: "stage", directory: cloudDir).id) == "cloud-source", "restyling cloud staging starts from retained source")
        try PhotoVersionHistory.hide(id: "cloud", directory: cloudDir)
        rejected("cloud re-import cannot resurrect a hidden family") {
            try PhotoVersionHistory.registerImport(id: "cloud", imageFile: "cloud-photo-cloud.jpg", originalFile: "orig-cloud.jpg", staged: true, altered: true, directory: cloudDir)
        }
        check((try? PhotoVersionHistory.availableCoverVersion(directory: cloudDir)?.id) == "neighbor", "removing staged cover family chooses other actual publication image")
        check((try? Set(PhotoVersionHistory.publicationVersions(directory: cloudDir)!.map(\.id))) == ["neighbor"], "hidden imported source and output cannot reappear as legacy siblings")
        check((try? Data(contentsOf: cloudDir.appendingPathComponent("cloud-photo-cloud.jpg"))) == Data("cloud-staging".utf8), "removing imported family retains staged bytes")
        try Data("other-original".utf8).write(to: cloudDir.appendingPathComponent("orig-other.jpg"))
        try Data("other-ai-result".utf8).write(to: cloudDir.appendingPathComponent("cloud-photo-other.jpg"))
        try PhotoVersionHistory.registerImport(id: "other", imageFile: "cloud-photo-other.jpg", originalFile: "orig-other.jpg", staged: false, altered: true, directory: cloudDir)
        let otherImport = try PhotoVersionHistory.load(directory: cloudDir)
        check(otherImport.listingSelections?["other"] == "other-source", "imported altered output also retains its earlier source selection until review")
        check(otherImport.versions["other"]?.visibleLabel == "AI edited · Earlier edits unverified", "imported altered output cannot lose its AI label")

        let noOriginalDir = root.appendingPathComponent("legacy-no-original")
        try FileManager.default.createDirectory(at: noOriginalDir, withIntermediateDirectories: true)
        try Data("earlier-unknown-history".utf8).write(to: noOriginalDir.appendingPathComponent("enh-old.jpg"))
        _ = try PhotoVersionHistory.trackExisting(id: "old", imageFile: "enh-old.jpg", priorFile: nil, directory: noOriginalDir)
        let unknownStage = try PhotoVersionHistory.saveEdit(jpeg: Data("staged-preview".utf8), id: "new-stage", parentID: "old", sourceID: "old",
            edit: "stage", style: "modern", disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: noOriginalDir)
        let unknownIndex = try PhotoVersionHistory.load(directory: noOriginalDir)
        check(unknownStage.reviewSourceFile(in: unknownIndex) == "enh-old.jpg", "legacy staging without orig file compares retained pre-furniture source")
        check(!unknownStage.originalVerified && unknownStage.caption.contains("unaltered original has not been verified"), "retained comparison cannot certify an unverified original")

        let customDir = root.appendingPathComponent("custom-preview")
        try PhotoVersionHistory.saveCapture(original: original, enhanced: enhanced, id: "custom-root", directory: customDir)
        let custom = try PhotoVersionHistory.saveEdit(jpeg: Data("lighting-preview".utf8), id: "custom-one", parentID: "custom-root", sourceID: "custom-root", edit: "custom", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: customDir)
        var customIndex = try PhotoVersionHistory.load(directory: customDir)
        check(custom.customReviewed == false && custom.needsCustomReview, "a new custom output explicitly starts as an unreviewed preview")
        check(!custom.canAutomaticallySelectForListing, "unreviewed custom cannot automatically replace the main photo")
        check(customIndex.current["custom-root"] == "custom-one", "custom preview remains visible for comparison in latest history")
        check(customIndex.listingSelections?["custom-root"] == "custom-root", "the prior photo remains on the listing until custom review")
        check((try? PhotoVersionHistory.publicationVersions(directory: customDir)?.map(\.id)) == ["custom-root"], "sync publishes the retained selected source, never the new custom preview")
        rejected("unreviewed custom cannot become cover") { try PhotoVersionHistory.select(id: "custom-one", directory: customDir) }
        rejected("unreviewed custom cannot become a listing photo") { try PhotoVersionHistory.selectForPublication(id: "custom-one", directory: customDir) }
        rejected("a staging-only acknowledgement cannot approve a custom edit") { try PhotoVersionHistory.selectForPublication(id: "custom-one", directory: customDir, reviewed: true) }
        rejected("raw-file save cannot bypass persisted custom download review") {
            try PhotoVersionHistory.requireDownloadReview(imageURL: customDir.appendingPathComponent(custom.imageFile))
        }
        try PhotoVersionHistory.requireDownloadReview(imageURL: customDir.appendingPathComponent("orig-custom-root.jpg"))
        check((try? PhotoVersionHistory.load(directory: customDir).versions[custom.id]?.customReviewed) == false,
              "admitting a retained original cannot approve its custom image")
        let completeCustomReview = PhotoVersionHistory.CustomReview(comparedSource: true, fixedFeaturesMatch: true,
            colorsAndMaterialsMatch: true, onlyRequestedChange: true)
        for flags in 0..<15 {
            let partialReview = PhotoVersionHistory.CustomReview(comparedSource: flags & 1 != 0, fixedFeaturesMatch: flags & 2 != 0,
                colorsAndMaterialsMatch: flags & 4 != 0, onlyRequestedChange: flags & 8 != 0)
            rejected("an incomplete custom review cannot approve edited downloads") {
                try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: custom.imageFile,
                    sourceFile: "orig-custom-root.jpg", review: partialReview, directory: customDir)
            }
        }
        rejected("custom download approval must match the displayed exact output file") {
            try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: "enh-custom-root.jpg",
                sourceFile: "orig-custom-root.jpg", review: completeCustomReview, directory: customDir)
        }
        rejected("custom download approval must compare the exact retained source") {
            try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: custom.imageFile,
                sourceFile: "enh-custom-root.jpg", review: completeCustomReview, directory: customDir)
        }
        let retainedSource = customDir.appendingPathComponent("orig-custom-root.jpg")
        let retainedSourceBytes = try Data(contentsOf: retainedSource)
        try FileManager.default.removeItem(at: retainedSource)
        rejected("missing retained source cannot be approved by checking boxes") {
            try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: custom.imageFile,
                sourceFile: "orig-custom-root.jpg", review: completeCustomReview, directory: customDir)
        }
        try retainedSourceBytes.write(to: retainedSource)
        let beforeDownloadReview = try PhotoVersionHistory.load(directory: customDir)
        try PhotoVersionHistory.confirmCustomReview(id: custom.id, imageFile: custom.imageFile,
            sourceFile: "orig-custom-root.jpg", review: completeCustomReview, directory: customDir)
        let downloadReview = try PhotoVersionHistory.load(directory: customDir)
        check(downloadReview.versions[custom.id]?.customReviewed == true, "complete download-only comparison persists on the exact custom output")
        try PhotoVersionHistory.requireDownloadReview(imageURL: customDir.appendingPathComponent(custom.imageFile))
        check((try? Data(contentsOf: customDir.appendingPathComponent(custom.imageFile))) == Data("lighting-preview".utf8),
              "reviewed direct file download preserves the saved output bytes")
        check(downloadReview.current == beforeDownloadReview.current && downloadReview.listingSelections == beforeDownloadReview.listingSelections,
              "download-only review does not publish a photo or replace the editing workspace")
        check((try? PhotoVersionHistory.publicationVersions(directory: customDir)?.map(\.id)) == ["custom-root"],
              "the selected listing and cover source remain unchanged after download approval")
        try PhotoVersionHistory.selectForPublication(id: "custom-one", directory: customDir, customReviewed: true)
        customIndex = try PhotoVersionHistory.load(directory: customDir)
        check(customIndex.versions["custom-one"]?.customReviewed == true, "exact custom output review survives disk reload")
        try PhotoVersionHistory.selectForPublication(id: "custom-root", directory: customDir)
        try PhotoVersionHistory.select(id: "custom-one", directory: customDir)
        check((try? PhotoVersionHistory.publicationVersions(directory: customDir)?.map(\.id)) == ["custom-one"], "a reviewed exact custom output can be reselected without a paid rerun")
        let secondCustom = try PhotoVersionHistory.saveEdit(jpeg: Data("second-preview".utf8), id: "custom-two", parentID: "custom-one", sourceID: "custom-one", edit: "custom", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: customDir)
        check(secondCustom.customReviewed == false, "review cannot transfer to a newly generated sibling custom output")
        rejected("new custom cannot inherit earlier custom approval") { try PhotoVersionHistory.selectForPublication(id: "custom-two", directory: customDir) }
        let customDescendant = try PhotoVersionHistory.saveEdit(jpeg: Data("custom-then-sky".utf8), id: "custom-sky", parentID: "custom-two", sourceID: "custom-two", edit: "sky", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: customDir)
        check(customDescendant.needsCustomReview && !customDescendant.canAutomaticallySelectForListing, "a preset cannot launder an unreviewed custom ancestor")
        rejected("descendant of custom remains fenced from publication") { try PhotoVersionHistory.selectForPublication(id: "custom-sky", directory: customDir) }
        let customStage = try PhotoVersionHistory.saveEdit(jpeg: Data("custom-then-stage".utf8), id: "custom-stage", parentID: "custom-sky", sourceID: "custom-sky", edit: "stage", style: "modern", disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: customDir)
        check(customStage.needsCustomReview, "custom and staging lineage retain separate review requirements")
        rejected("custom acknowledgement alone cannot approve unreviewed staging") { try PhotoVersionHistory.selectForPublication(id: "custom-stage", directory: customDir, customReviewed: true) }
        rejected("staging acknowledgement alone cannot approve unreviewed custom lineage") { try PhotoVersionHistory.selectForPublication(id: "custom-stage", directory: customDir, reviewed: true) }
        try PhotoVersionHistory.selectForPublication(id: "custom-stage", directory: customDir, reviewed: true, customReviewed: true)
        check((try? PhotoVersionHistory.load(directory: customDir).versions["custom-stage"]?.customReviewed) == true, "combined custom/staging review only approves that exact output")
        check((try? Data(contentsOf: customDir.appendingPathComponent("orig-custom-root.jpg"))) == original, "custom review and presets preserve retained original bytes")

        // An older on-disk custom version has no new review marker. Preserve its
        // existing selection, without silently recording that it was reviewed.
        let customIndexURL = customDir.appendingPathComponent(".photo-history.json")
        let encoded = try Data(contentsOf: customIndexURL)
        var olderJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var olderVersions = olderJSON["versions"] as! [String: [String: Any]]
        olderVersions["custom-stage"]?.removeValue(forKey: "customReviewed")
        olderJSON["versions"] = olderVersions
        try JSONSerialization.data(withJSONObject: olderJSON).write(to: customIndexURL)
        check((try? PhotoVersionHistory.load(directory: customDir).versions["custom-stage"]?.customReviewed) == nil, "missing legacy marker decodes without certifying a review")
        check((try? PhotoVersionHistory.publicationVersions(directory: customDir)?.map(\.id)) == ["custom-stage"], "legacy already selected outputs remain backward compatible")
        // A damaged selection must not bypass a new explicit false marker.
        olderVersions["custom-stage"]?["customReviewed"] = false
        olderJSON["versions"] = olderVersions
        try JSONSerialization.data(withJSONObject: olderJSON).write(to: customIndexURL)
        rejected("an erroneously selected unreviewed custom is fenced at actual publication") { _ = try PhotoVersionHistory.publicationVersions(directory: customDir) }
        check((try? PhotoVersionHistory.availableCoverVersion(directory: customDir)) == nil, "cover fallback cannot pick an erroneously selected unreviewed custom")

        let customCloudDir = root.appendingPathComponent("new-cloud-altered-preview")
        try FileManager.default.createDirectory(at: customCloudDir, withIntermediateDirectories: true)
        try original.write(to: customCloudDir.appendingPathComponent("cloud-original.jpg"))
        try Data("remote-custom-result".utf8).write(to: customCloudDir.appendingPathComponent("cloud-result.jpg"))
        try PhotoVersionHistory.registerImport(id: "remote", imageFile: "cloud-result.jpg", originalFile: "cloud-original.jpg", staged: false, altered: true, directory: customCloudDir)
        var remoteIndex = try PhotoVersionHistory.load(directory: customCloudDir)
        let remote = remoteIndex.versions["remote"]!
        check(remote.needsCustomReview && !remote.canAutomaticallySelectForListing, "new cloud altered imports require review when exact edit identity is unavailable")
        check(remote.reviewSourceFile(in: remoteIndex) == "cloud-original.jpg", "cloud comparison uses the exact retained source attached to this import")
        check(!remote.originalVerified, "a cloud comparison does not certify an unaltered original")
        check(remoteIndex.isSelectedForListing("remote-source"), "cloud import keeps the retained source selected for the listing")
        rejected("cloud custom import cannot become cover without comparison") { try PhotoVersionHistory.select(id: "remote", directory: customCloudDir) }
        rejected("cloud custom import cannot be selected for publication without comparison") { try PhotoVersionHistory.selectForPublication(id: "remote", directory: customCloudDir) }
        let remoteSky = try PhotoVersionHistory.saveEdit(jpeg: Data("remote-then-sky".utf8), id: "remote-sky", parentID: "remote", sourceID: "remote", edit: "sky", style: nil, disclosure: nil, provenanceID: nil, provenanceRecorded: false, directory: customCloudDir)
        check(remoteSky.needsCustomReview && !remoteSky.canAutomaticallySelectForListing, "a preset cannot launder unreviewed unknown cloud AI lineage")
        rejected("cloud custom descendant still cannot become public") { try PhotoVersionHistory.selectForPublication(id: "remote-sky", directory: customCloudDir) }
        try PhotoVersionHistory.selectForPublication(id: "remote", directory: customCloudDir, customReviewed: true)
        try PhotoVersionHistory.selectForPublication(id: "remote-source", directory: customCloudDir)
        try PhotoVersionHistory.selectForPublication(id: "remote", directory: customCloudDir)
        remoteIndex = try PhotoVersionHistory.load(directory: customCloudDir)
        check(remoteIndex.versions["remote"]?.customReviewed == true && remoteIndex.isSelectedForListing("remote"), "exact reviewed cloud output can be reselected without generation")
        try PhotoVersionHistory.registerImport(id: "remote", imageFile: "cloud-result.jpg", originalFile: "cloud-original.jpg", staged: false, altered: true, directory: customCloudDir)
        check((try? PhotoVersionHistory.load(directory: customCloudDir).versions["remote"]?.customReviewed) == true, "repeat import cannot erase an existing exact review")
        var legacyCloudJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: customCloudDir.appendingPathComponent(".photo-history.json"))) as! [String: Any]
        var legacyCloudVersions = legacyCloudJSON["versions"] as! [String: [String: Any]]
        legacyCloudVersions["remote"]?.removeValue(forKey: "customReviewed")
        legacyCloudJSON["versions"] = legacyCloudVersions
        try JSONSerialization.data(withJSONObject: legacyCloudJSON).write(to: customCloudDir.appendingPathComponent(".photo-history.json"))
        try PhotoVersionHistory.registerImport(id: "remote", imageFile: "cloud-result.jpg", originalFile: "cloud-original.jpg", staged: false, altered: true, directory: customCloudDir)
        check((try? PhotoVersionHistory.load(directory: customCloudDir).versions["remote"]?.customReviewed) == nil, "preexisting cloud ids are not retroactively rewritten or certified")
        check((try? Data(contentsOf: customCloudDir.appendingPathComponent("cloud-original.jpg"))) == original, "cloud import review preserves exact retained source bytes")

        typealias Layout = PhotoExportLayout
        check(Layout.size(width: 4032, height: 3024, aspect: .original, framing: .crop) == .init(width: 4032, height: 3024), "default preserves every original pixel")
        check(Layout.size(width: 4032, height: 3024, aspect: .landscape, framing: .crop) == .init(width: 4032, height: 3024), "4:3 same source")
        check(Layout.size(width: 4000, height: 3000, aspect: .wide, framing: .crop) == .init(width: 4000, height: 2250), "wide crop removes top and bottom")
        check(Layout.size(width: 4000, height: 3000, aspect: .portrait, framing: .crop) == .init(width: 1688, height: 3000), "portrait crop trims sides")
        check(Layout.size(width: 4000, height: 3000, aspect: .portrait, framing: .fit) == .init(width: 2250, height: 4000), "fit canvas bounded by source long edge")
        check(Layout.size(width: 3000, height: 4000, aspect: .wide, framing: .fit) == .init(width: 4000, height: 2250), "landscape fit never increases longest side")
        for width in [1024, 2048, 4032, 6000] {
            for height in [768, 2048, 4032] {
                for aspect in Layout.Aspect.allCases {
                    for framing in Layout.Framing.allCases {
                        let size = Layout.size(width: width, height: height, aspect: aspect, framing: framing)
                        check(size.width > 0 && size.height > 0, "positive export dimensions")
                        check(max(size.width, size.height) <= max(width, height), "no upscale across ratios")
                        if framing == .crop { check(size.width <= width && size.height <= height, "crop never stretches source") }
                    }
                }
            }
        }
        print("Photo history/export geometry: \(checks) passed")
    }
}
