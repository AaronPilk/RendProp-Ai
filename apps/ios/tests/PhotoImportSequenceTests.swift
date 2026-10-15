import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)); exit(1) }
}

@main struct PhotoImportSequenceTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Rendprop-photo-import-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = PhotoImportContext(owner: "owner", revision: 4, workspace: UUID())
        require(context.matches(owner: "owner", revision: 4, workspace: context.workspace), "matching account context")
        require(!context.matches(owner: "another", revision: 4, workspace: context.workspace), "owner change refused")
        require(!context.matches(owner: "owner", revision: 5, workspace: context.workspace), "session change refused")
        require(!context.matches(owner: "owner", revision: 4, workspace: UUID()), "workspace change refused")

        let staged = root.appendingPathComponent("large-batch")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let cancellation = PhotoImportCancellation(), complete = DispatchSemaphore(value: 0)
        let stateLock = NSLock()
        var admitted: [Int] = [], active = 0, peak = 0
        var resultItems: [PhotoImportItem] = [], resultFailures: [PhotoImportFailure] = []
        PhotoImportSerialLoader.start(count: 40, cancellation: cancellation, load: { position, reply in
            stateLock.lock(); admitted.append(position); active += 1; peak = max(peak, active); stateLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + (position.isMultiple(of: 2) ? 0.001 : 0.002)) {
                stateLock.lock(); active -= 1; stateLock.unlock()
                if position == 17 { reply(.failure(NSError(domain: "ProviderUnavailable", code: 17))); return }
                let url = staged.appendingPathComponent("\(position).heic")
                try! Data("EXACT-ORIGINAL-\(position)".utf8).write(to: url)
                reply(.success(url))
                if position == 8 { reply(.success(url)) } // a bad duplicate callback cannot duplicate admission
            }
        }, completion: { items, failures in resultItems = items; resultFailures = failures; complete.signal() })
        require(complete.wait(timeout: .now() + 10) == .success, "40-file selection finishes")
        require(admitted == Array(0..<40), "all selections beyond15 are admitted once in chosen order")
        require(peak == 1, "one provider request at a time")
        require(resultItems.map(\.position) == Array(0..<40).filter { $0 != 17 }, "success order preserved despite provider delays")
        require(resultFailures.map(\.position) == [17], "provider failure reported by exact selection position")

        let batch = PhotoImportBatch(id: UUID(), requestedCount: 40, items: resultItems,
            failures: resultFailures, directory: staged, context: context, cancellation: cancellation)
        let listingID = UUID()
        FileStore.documents = root
        let saved = EnhancedPhoto.directory(for: listingID)
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        var savedIDs: [String] = [], savedPositions: [Int] = []
        var report: PhotoImportReport?
        let saveComplete = DispatchSemaphore(value: 0)
        PhotoImportWriter.save(batch, existingIDs: [], process: { item, id in
            if item.position == 25 { throw NSError(domain: "DiskFull", code: 25) }
            let raw = try Data(contentsOf: item.url)
            require(raw == Data("EXACT-ORIGINAL-\(item.position)".utf8), "original bytes not resized, converted or recompressed")
            try PhotoVersionHistory.saveCapture(original: raw, enhanced: Data("ENHANCED-\(item.position)".utf8), id: id, directory: saved, importOrderID: id)
            savedIDs.append(id); savedPositions.append(item.position)
        }, completion: { report = $0; saveComplete.signal() })
        require(saveComplete.wait(timeout: .now() + 10) == .success, "large batch saving finishes")
        require(savedPositions.count == 38 && savedPositions == Array(0..<40).filter { $0 != 17 && $0 != 25 }, "partial saves continue in selection order")
        require(savedIDs == savedIDs.sorted(by: >), "gallery descending IDs preserve first-selected-first")
        require(report?.failures.map(\.position).sorted() == [17, 25], "both load and save failure positions reported")
        require(report?.message?.contains("38 of 40 photos saved") == true && report?.message?.contains("18, 26") == true, "partial failure message names missing selections without silent drops")
        let history = try PhotoVersionHistory.load(directory: saved)
        require(history.versions.count == 38, "all38 successful photos persist in actual history without15count ceiling")
        let displayed = history.orderedForLibrary(Array(history.versions.values)).map(\.id)
        require(displayed == savedIDs, "actual persisted gallery ordering keeps selected order independently of write timestamps")
        require(EnhancedPhoto.loadAll(listingID: listingID).map(\.id) == savedIDs,
                "actual local gallery displays selected order")
        let published = try EnhancedPhoto.loadForListing(listingID: listingID)
        require(published.map(\.id) == savedIDs, "actual publication reader keeps selected order")
        require(NewVideoPhotoSelection.selectionInUploadOrder([savedIDs[2],savedIDs[0],savedIDs[2]], photos: published) == [savedIDs[0],savedIDs[2]],
                "checking photos out of sequence keeps upload-relative picker positions")
        for (position, id) in zip(savedPositions, savedIDs) {
            let original = saved.appendingPathComponent("orig-\(id).jpg")
            require(try! Data(contentsOf: original) == Data("EXACT-ORIGINAL-\(position)".utf8), "exact retained original survives actual durable save")
        }
        // Completion is deliberately called before defer cleanup; wait until the
        // serial writer admits its next batch, proving prior temp cleanup too.
        let nextDir = root.appendingPathComponent("repeat-batch"); try FileManager.default.createDirectory(at: nextDir, withIntermediateDirectories: true)
        var repeatItems: [PhotoImportItem] = []
        for position in 0..<25 {
            let url = nextDir.appendingPathComponent("\(position).png");try Data("REPEAT-\(position)".utf8).write(to: url)
            repeatItems.append(PhotoImportItem(position: position, url: url))
        }
        let repeatBatch = PhotoImportBatch(id: UUID(), requestedCount: 25, items: repeatItems, failures: [], directory: nextDir, context: context, cancellation: PhotoImportCancellation())
        var repeatedIDs: [String] = [];let repeatComplete = DispatchSemaphore(value: 0)
        PhotoImportWriter.save(repeatBatch, existingIDs: savedIDs, process: { item, id in
            require(!FileManager.default.fileExists(atPath: staged.path), "first batch's temporary source files cleaned before next batch")
            try PhotoVersionHistory.saveCapture(original: Data(contentsOf: item.url), enhanced: Data("BRIGHT-\(item.position)".utf8), id: id, directory: saved, importOrderID: id)
            repeatedIDs.append(id)
        }, completion: { next in require(next.savedPositions.count == 25 && next.failures.isEmpty, "repeat25 import accepted");repeatComplete.signal() })
        require(repeatComplete.wait(timeout: .now() + 10) == .success, "repeat batch finishes")
        require(repeatedIDs == repeatedIDs.sorted(by: >) && repeatedIDs.last! > savedIDs.first!, "legacy capture IDs remain unique and monotonic across batches")
        let afterRepeated = try PhotoVersionHistory.load(directory: saved)
        require(afterRepeated.versions.count == 63, "63 durablephotos across repeated imports, no total15 ceiling")
        require(EnhancedPhoto.loadAll(listingID: listingID).map(\.id) == savedIDs + repeatedIDs,
                "later uploaded batch appends below earlier selected photos")
        require(try! EnhancedPhoto.loadForListing(listingID: listingID).map(\.id) == savedIDs + repeatedIDs,
                "new video picker receives both batches in upload order")
        let edited = try PhotoVersionHistory.saveEdit(jpeg: Data("LATER EDIT OF FIRST PHOTO".utf8), id: "edited-first",
            parentID: savedIDs[0], sourceID: savedIDs[0], edit: "declutter", style: nil,
            disclosure: "AI decluttered", provenanceID: UUID().uuidString, provenanceRecorded: true, directory: saved)
        let expectedCurrent = [edited.id] + Array(savedIDs.dropFirst()) + repeatedIDs
        require(EnhancedPhoto.loadAll(listingID: listingID).map(\.id) == expectedCurrent,
                "later saved edit retains its original family's position")
        let editedIndex = try PhotoVersionHistory.ensureOriginalSources(directory: saved)
        require(editedIndex.libraryVersions(.original).map(\.familyID) == savedIDs + repeatedIDs,
                "Originals keep source-family upload order across batches")
        require(editedIndex.libraryVersions(.latest).map(\.id) == expectedCurrent,
                "Latest variants keep source-family upload order")
        require(try! EnhancedPhoto.loadForListing(listingID: listingID).map(\.id) == expectedCurrent,
                "reviewed publication choices inherit source-family order rather than edit dates")
        require(NewVideoPhotoSelection.selectionInUploadOrder([repeatedIDs[1],savedIDs[0]],
                photos: try! EnhancedPhoto.loadForListing(listingID: listingID), index: editedIndex) == [edited.id,repeatedIDs[1]],
                "new video selection retains the chosen source family after an approved version changes")
        try PhotoVersionHistory.selectForPublication(id: savedIDs[0] + "-original", directory: saved, reviewed: true)
        require(try! EnhancedPhoto.loadForListing(listingID: listingID).first?.id == savedIDs[0] + "-original",
                "selecting an Original changes only the exact version in its family slot")
        require(try! Data(contentsOf: saved.appendingPathComponent("orig-\(savedIDs[0]).jpg")) == Data("EXACT-ORIGINAL-0".utf8),
                "ordering and version selection never rewrite original master bytes")
        var legacyIndex = afterRepeated
        legacyIndex.familyOrder = nil
        let decodedLegacy = try JSONDecoder().decode(PhotoVersionHistory.Index.self, from: JSONEncoder().encode(legacyIndex))
        require(decodedLegacy.orderedForLibrary(Array(decodedLegacy.versions.values)).map(\.id) == savedIDs + repeatedIDs,
                "older histories without family order recover original capture chronology without edit timestamps")
        _ = try PhotoVersionHistory.saveEdit(jpeg: Data("STAGED THIRD FAMILY".utf8), id: "stage-third",
            parentID: savedIDs[2], sourceID: savedIDs[2], edit: "stage", style: "modern", disclosure: "Virtually staged",
            provenanceID: UUID().uuidString, provenanceRecorded: true, directory: saved)
        _ = try PhotoVersionHistory.saveEdit(jpeg: Data("STAGED SECOND FAMILY".utf8), id: "stage-second",
            parentID: savedIDs[1], sourceID: savedIDs[1], edit: "stage", style: "modern", disclosure: "Virtually staged",
            provenanceID: UUID().uuidString, provenanceRecorded: true, directory: saved)
        let stagedIndex = try PhotoVersionHistory.load(directory: saved)
        require(stagedIndex.libraryVersions(.staged).map(\.familyID) == [savedIDs[1],savedIDs[2]],
                "Saved staged variants stay grouped in source upload order rather than edit completion order")
        require(NewVideoPhotoSelection.selectionInUploadOrder(["stage-third","stage-second"],
                photos: try! EnhancedPhoto.loadForListing(listingID: listingID), index: stagedIndex) == [savedIDs[1],savedIDs[2]],
                "new video binds the exact approved listing versions while newer staging previews remain unselected")
        let legacyListing = UUID(), legacyDirectory = EnhancedPhoto.directory(for: legacyListing)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        for (offset, id) in ["older-first", "older-second"].enumerated() {
            let image = legacyDirectory.appendingPathComponent("enh-\(id).jpg")
            try Data(id.utf8).write(to: image)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1_000 + Double(offset))], ofItemAtPath: image.path)
        }
        try Data("CLOUD IMPORT".utf8).write(to: legacyDirectory.appendingPathComponent("enh-cloud-order.jpg"))
        try Data("CLOUD SOURCE".utf8).write(to: legacyDirectory.appendingPathComponent("orig-cloud-order.jpg"))
        try PhotoVersionHistory.registerImport(id: "cloud-order", imageFile: "enh-cloud-order.jpg",
            originalFile: "orig-cloud-order.jpg", staged: false, altered: false, directory: legacyDirectory)
        require(EnhancedPhoto.loadAll(listingID: legacyListing).map(\.id) == ["older-first", "older-second", "cloud-order"],
                "new cloud import appends after older files awaiting legacy history adoption")

        let cancel = PhotoImportCancellation(), cancelDone = DispatchSemaphore(value: 0)
        var cancelPositions: [Int] = [], cancelledFailures: [PhotoImportFailure] = []
        PhotoImportSerialLoader.start(count: 30, cancellation: cancel, load: { position, reply in
            cancelPositions.append(position)
            if position == 8 { reply(.failure(CancellationError())) }
            else { reply(.success(root.appendingPathComponent("fake-\(position)"))) }
        }, completion: { _, failures in cancelledFailures = failures;cancelDone.signal() })
        require(cancelDone.wait(timeout: .now() + 10) == .success, "cancellation completes")
        require(cancelPositions == Array(0...8), "cancellation admits no more provider reads")
        require(cancelledFailures.map(\.position) == Array(8..<30), "every unattempted selection is accounted for on cancellation")
        let noWrites = DispatchSemaphore(value: 0), cancelledDir = root.appendingPathComponent("cancelled")
        try FileManager.default.createDirectory(at: cancelledDir, withIntermediateDirectories: true)
        let stoppedBatch = PhotoImportBatch(id: UUID(), requestedCount: 2,
            items: [PhotoImportItem(position: 0, url: cancelledDir.appendingPathComponent("0")), PhotoImportItem(position: 1, url: cancelledDir.appendingPathComponent("1"))], failures: [], directory: cancelledDir, context: context, cancellation: cancel)
        var writes = 0
        PhotoImportWriter.save(stoppedBatch, existingIDs: [], process: { _, _ in writes += 1 }, completion: { stopped in
            require(stopped.savedPositions.isEmpty && stopped.failures.count == 2, "cancelled pending files are reported, never saved");noWrites.signal()
        })
        require(noWrites.wait(timeout: .now() + 10) == .success && writes == 0, "cancelled account context produces no writes")
        let parallelDone = DispatchSemaphore(value: 0), writerLock = NSLock()
        var activeWriters = 0, peakWriters = 0
        for batchNumber in 0..<2 {
            let parallelDir = root.appendingPathComponent("parallel-\(batchNumber)")
            try FileManager.default.createDirectory(at: parallelDir, withIntermediateDirectories: true)
            let file = parallelDir.appendingPathComponent("raw.heic")
            try Data("UNCHANGED-PARALLEL-SOURCE".utf8).write(to: file)
            let simultaneous = PhotoImportBatch(id: UUID(), requestedCount: 21,
                items: (0..<21).map { PhotoImportItem(position: $0, url: file) }, failures: [],
                directory: parallelDir, context: context, cancellation: PhotoImportCancellation())
            PhotoImportWriter.save(simultaneous, existingIDs: [], process: { item, _ in
                writerLock.lock(); activeWriters += 1; peakWriters = max(peakWriters, activeWriters);writerLock.unlock()
                defer { writerLock.lock(); activeWriters -= 1;writerLock.unlock() }
                Thread.sleep(forTimeInterval: 0.002)
                require(try! Data(contentsOf: item.url) == Data("UNCHANGED-PARALLEL-SOURCE".utf8), "serial writer preserves each staged source")
            }, completion: { result in
                require(result.savedPositions.count == 21 && result.failures.isEmpty, "both queued large imports finish")
                parallelDone.signal()
            })
        }
        require(parallelDone.wait(timeout: .now() + 10) == .success && parallelDone.wait(timeout: .now() + 10) == .success,
                "simultaneous import batches finish")
        require(peakWriters == 1, "one photo decode/write is active across simultaneous batches")
        print("PASS:40 selections, serial loads, duplicates fenced, ordered63 durable repeats, exact originals, partial failures and cancellation")
    }
}
