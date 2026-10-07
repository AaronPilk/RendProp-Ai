import Foundation

/// Local, durable photo lineage. Image files are immutable; selecting a newer
/// version never deletes its source or the retained pre-enhancement capture.
/// This is a local history, not a claim that a cloud provenance row was saved.
enum PhotoVersionHistory {
    /// A user's review of one displayed version, not an automated quality verdict.
    struct StagingReview {
        var comparedSource = false
        var fixedFeaturesMatch = false
        var accessIsClear = false
        var furnitureMatchesOtherViews = false
        var isComplete: Bool {
            comparedSource && fixedFeaturesMatch && accessIsClear && furnitureMatchesOtherViews
        }
    }
    enum LibraryKind: String, CaseIterable, Identifiable, Sendable {
        case latest = "Latest", decluttered = "Decluttered", staged = "Staged"
        var id: String { rawValue }
    }
    struct Version: Codable, Hashable, Sendable, Identifiable {
        let id: String
        let familyID: String
        let imageFile: String
        let originalFile: String?
        let originalVerified: Bool
        let parentID: String?
        let sourceID: String?
        let stagingBaseID: String?
        let edit: String
        let style: String?
        let effects: [String]
        let sourceHistoryKnown: Bool
        let disclosure: String?
        let provenanceID: String?
        let originalAssetID: String?
        let serverListingID: String?
        let provenanceRecorded: Bool
        let createdAt: Date
        var stagingReviewed: Bool? = nil
        var stagingReferenceID: String? = nil
        var stagingBrief: String? = nil

        var visibleLabel: String? {
            var parts: [String] = []
            if effects.contains("stage") { parts.append("Virtually staged") }
            if effects.contains("declutter") { parts.append("Digitally decluttered") }
            if effects.contains(where: { $0 != "stage" && $0 != "declutter" }) { parts.append("AI edited") }
            if !sourceHistoryKnown { parts.append("Earlier edits unverified") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }

        /// Presentation may correct old copy; immutable recorded disclosure is
        /// retained verbatim in the saved audit/history, not used as a geometry certificate.
        var reviewDisclosure: String? {
            guard !effects.isEmpty else { return disclosure }
            let change: String
            if effects.contains("stage") {
                change = "This photo was virtually staged with AI: furniture and decor were digitally added or restyled."
            } else if effects.contains("declutter") {
                change = "This photo was digitally decluttered with AI: clutter and personal items were removed."
            } else if edit == "twilight" {
                change = "This photo was digitally altered with AI to simulate dusk."
            } else if edit == "sky" {
                change = "This photo was digitally altered with AI: the sky was replaced."
            } else if edit == "lawn" {
                change = "This photo was digitally altered with AI: the lawn and landscaping were digitally repaired."
            } else {
                change = "This photo was digitally altered with AI."
            }
            return change + " Compare with the original to check fixed features, layout and access before publication."
        }

        var caption: String {
            var parts: [String] = []
            if let visibleLabel { parts.append(visibleLabel + ".") }
            if let reviewDisclosure, !reviewDisclosure.isEmpty { parts.append(reviewDisclosure) }
            if !originalVerified { parts.append("An unaltered original has not been verified for this photo.") }
            return parts.isEmpty ? "Brightness, color and sharpness enhanced on this phone. Review the source before publishing." : parts.joined(separator: " ")
        }

        var title: String {
            switch edit {
            case "capture": return "Original enhancement"
            case "legacy": return "Earlier photo · history unverified"
            case "stage": return "Virtual staging" + (style.map { " · \($0.capitalized)" } ?? "")
            case "declutter": return "Decluttered"
            case "twilight": return "Twilight sky"
            case "sky": return "Blue sky"
            case "lawn": return "Green lawn"
            default: return "AI edit"
            }
        }

        /// An old import may lack an orig-* file, but its retained pre-edit
        /// version is still a useful, explicitly unverified review source.
        func reviewSourceFile(in index: Index) -> String {
            if let originalFile { return originalFile }
            if let stagingBaseID, let base = index.versions[stagingBaseID] { return base.imageFile }
            if let sourceID, let source = index.versions[sourceID] { return source.imageFile }
            if let parentID, let parent = index.versions[parentID] { return parent.imageFile }
            return imageFile
        }
    }

    struct Index: Codable, Sendable {
        var schema = 1
        var versions: [String: Version] = [:]
        var current: [String: String] = [:]
        /// Staged previews stay separate from the approved public choice.
        /// Optional so older on-disk indexes continue to decode unchanged.
        var listingSelections: [String: String]? = nil
        var hiddenFamilies: Set<String> = []

        func history(for id: String) -> [Version] {
            guard let family = versions[id]?.familyID else { return [] }
            return versions.values.filter { $0.familyID == family }.sorted {
                $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id
            }
        }
        func isVisible(_ id: String) -> Bool {
            guard let version = versions[id] else { return true }
            return !hiddenFamilies.contains(version.familyID) && current[version.familyID] == id
        }
        /// A saved declutter remains available after staging. Choose one newest
        /// matching version per photo; a staged photo is never a declutter-only
        /// export, even when its lineage includes decluttering.
        func libraryVersions(_ kind: LibraryKind) -> [Version] {
            let candidates = versions.values.filter { version in
                guard !hiddenFamilies.contains(version.familyID) else { return false }
                switch kind {
                case .latest: return current[version.familyID] == version.id
                case .decluttered: return version.effects.contains("declutter") && !version.effects.contains("stage")
                case .staged: return version.effects.contains("stage")
                }
            }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id }
            var families: Set<String> = []
            return candidates.filter { families.insert($0.familyID).inserted }
        }

        func isSelectedForListing(_ id: String) -> Bool {
            guard let version = versions[id], !hiddenFamilies.contains(version.familyID) else { return false }
            return (listingSelections ?? current)[version.familyID] == id
        }

        /// A Latest tile may have a decluttered predecessor on the listing.
        /// Resolve that family's choice from metadata, even when a different
        /// family's selected image is missing and publication must stop.
        func publicationChoice(for id: String) -> Version? {
            guard let version = versions[id], !hiddenFamilies.contains(version.familyID),
                  let selected = (listingSelections ?? current)[version.familyID] else { return nil }
            return versions[selected]
        }
        func publicationLabel(for id: String) -> String? {
            guard let chosen = publicationChoice(for: id) else { return nil }
            if chosen.id == id { return "Selected for listing" }
            if chosen.effects.contains("stage") { return "Staged version on listing" }
            if chosen.effects.contains("declutter") { return "Decluttered version on listing" }
            if !chosen.effects.isEmpty { return "Edited version on listing" }
            return "Earlier version on listing"
        }
    }

    enum Failure: LocalizedError {
        case invalidHistory, missingImage, duplicate, changedVersion, reviewRequired, coverNotSelected
        var errorDescription: String? {
            switch self {
            case .invalidHistory: return "This photo's saved history couldn't be read. Its files are still safe. Reopen Photos or contact support before editing it."
            case .missingImage: return "A source photo is missing from this phone. Import it again before editing."
            case .duplicate: return "That photo version is already saved. Reopen Photos to see it."
            case .changedVersion: return "This photo changed while the edit was running. Reopen Photos before editing again."
            case .reviewRequired: return "Review this staged photo against its original before using it on the listing or as its cover."
            case .coverNotSelected: return "The cover isn't among the photos selected for this listing. Open Photos and choose a cover from a reviewed version. Your published gallery has been kept."
            }
        }
    }

    private static let lock = NSLock()
    private static let filename = ".photo-history.json"
    private static func safeName(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/") && !value.contains("\\")
    }
    private static func readIndex(directory: URL) throws -> Index {
        let url = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return Index() }
        do {
            let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
            guard index.schema == 1,
                  index.versions.allSatisfy({ key, v in
                      key == v.id && safeName(v.id) && safeName(v.familyID) && safeName(v.imageFile)
                      && (v.originalFile.map(safeName) ?? true)
                  }), index.current.allSatisfy({ family, id in index.versions[id]?.familyID == family }),
                  (index.listingSelections ?? [:]).allSatisfy({ family, id in index.versions[id]?.familyID == family })
            else { throw Failure.invalidHistory }
            return index
        } catch { throw Failure.invalidHistory }
    }
    /// Adopt every legacy sibling together before the first indexed change.
    /// Known hidden/superseded files are never inferred as new families. Merely
    /// having an orig-* filename does not verify an unaltered source.
    private static func loadUnlocked(directory: URL) throws -> Index {
        var index = try readIndex(directory: directory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return index }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
        let knownFiles = Set(index.versions.values.map(\.imageFile))
        let names = Set(files.map(\.lastPathComponent))
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasPrefix("enh-"), !knownFiles.contains(name),
                  ["jpg", "jpeg", "png", "heic", "webp"].contains(file.pathExtension.lowercased()) else { continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .creationDateKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { continue }
            let id = String(file.deletingPathExtension().lastPathComponent.dropFirst(4))
            guard safeName(id), index.versions[id] == nil else { throw Failure.invalidHistory }
            let preferred = "orig-\(id).jpg"
            let prior = names.contains(preferred) ? preferred : names.sorted().first { $0.hasPrefix("orig-\(id).") }
            let version = Version(id: id, familyID: id, imageFile: name, originalFile: prior,
                originalVerified: false, parentID: nil, sourceID: nil, stagingBaseID: nil,
                edit: "legacy", style: nil, effects: [], sourceHistoryKnown: false,
                disclosure: nil, provenanceID: nil, originalAssetID: nil, serverListingID: nil,
                provenanceRecorded: false, createdAt: values.creationDate ?? .distantPast)
            index.versions[id] = version; index.current[id] = id
            index.listingSelections?[id] = id
        }
        return index
    }
    static func load(directory: URL) throws -> Index {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked(directory: directory)
    }
    /// Publication must not silently replace a saved gallery when its history
    /// is corrupt or a selected file is missing. nil means legacy/no index.
    static func publicationVersions(directory: URL) throws -> [Version]? {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let index = try loadUnlocked(directory: directory)
        return try (index.listingSelections ?? index.current).compactMap { family, id in
            guard !index.hiddenFamilies.contains(family) else { return nil }
            guard let version = index.versions[id], version.familyID == family else { throw Failure.invalidHistory }
            try requireImage(version.imageFile, directory: directory)
            return version
        }
    }

    /// Cover fallback must use a real selected image, not the latest staged
    /// workspace. One unavailable family doesn't hide all other candidates.
    static func availableCoverVersion(directory: URL) throws -> Version? {
        let index = try load(directory: directory)
        return (index.listingSelections ?? index.current).compactMap { family, id -> Version? in
            guard !index.hiddenFamilies.contains(family), let version = index.versions[id],
                  (try? requireImage(version.imageFile, directory: directory)) != nil else { return nil }
            return version
        }.sorted { $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id > $1.id }.first
    }

    static func familyContains(id: String, imageFile: String?, directory: URL) throws -> Bool {
        guard let imageFile else { return false }
        let index = try load(directory: directory)
        guard let version = index.versions[id] else { return false }
        return index.versions.values.contains { $0.familyID == version.familyID && $0.imageFile == imageFile }
    }
    private static func save(_ index: Index, directory: URL,
                             write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try write(encoder.encode(index), directory.appendingPathComponent(filename))
    }
    private static func requireImage(_ name: String, directory: URL) throws {
        guard safeName(name),
              let values = try? directory.appendingPathComponent(name).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) > 0 else { throw Failure.missingImage }
    }

    /// Register only a newly captured/imported image whose pre-enhancement bytes
    /// this call owns. Older orig-* files may be AI predecessors, so never infer
    /// this guarantee from a filename.
    static func saveCapture(original: Data, enhanced: Data, id: String, directory: URL,
                            write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws {
        lock.lock(); defer { lock.unlock() }
        var index = try loadUnlocked(directory: directory)
        guard index.versions[id] == nil else { throw Failure.duplicate }
        try PhotoCaptureStorage.writePair(original: original, enhanced: enhanced, id: id, directory: directory, write: write)
        let originalName = "orig-\(id).jpg", imageName = "enh-\(id).jpg"
        do {
            let version = Version(id: id, familyID: id, imageFile: imageName, originalFile: originalName,
                                  originalVerified: true, parentID: nil, sourceID: nil, stagingBaseID: nil,
                                  edit: "capture", style: nil, effects: [], sourceHistoryKnown: true,
                                  disclosure: nil, provenanceID: nil, originalAssetID: nil, serverListingID: nil,
                                  provenanceRecorded: false, createdAt: Date())
            index.versions[id] = version; index.current[id] = id
            index.listingSelections?[id] = id
            try save(index, directory: directory, write: write)
        } catch {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(originalName))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(imageName))
            throw error
        }
    }

    /// Adopt an old photo into the version tree without inventing its provenance.
    /// Its prior-source file remains downloadable, but is not a verified original.
    @discardableResult
    static func trackExisting(id: String, imageFile: String, priorFile: String?, directory: URL) throws -> Version {
        lock.lock(); defer { lock.unlock() }
        var index = try loadUnlocked(directory: directory)
        if let existing = index.versions[id] { return existing }
        guard safeName(id), priorFile.map(safeName) ?? true else { throw Failure.invalidHistory }
        try requireImage(imageFile, directory: directory)
        let version = Version(id: id, familyID: id, imageFile: imageFile, originalFile: priorFile,
                              originalVerified: false, parentID: nil, sourceID: nil, stagingBaseID: nil,
                              edit: "legacy", style: nil, effects: [], sourceHistoryKnown: false,
                              disclosure: nil, provenanceID: nil, originalAssetID: nil, serverListingID: nil,
                                  provenanceRecorded: false, createdAt: Date())
        index.versions[id] = version; index.current[id] = id
        index.listingSelections?[id] = id
        try save(index, directory: directory)
        return version
    }

    /// Restyling starts from the persisted image used BEFORE furniture was added.
    /// Other edits start from the current image. Missing bases fail rather than
    /// silently generating on top of old virtual furniture.
    static func source(for id: String, edit: String, directory: URL) throws -> Version {
        let index = try load(directory: directory)
        guard let parent = index.versions[id], index.isVisible(id) else { throw Failure.changedVersion }
        let source: Version
        if edit == "stage", let base = parent.stagingBaseID {
            guard let saved = index.versions[base], saved.familyID == parent.familyID else { throw Failure.invalidHistory }
            source = saved
        } else { source = parent }
        try requireImage(source.imageFile, directory: directory)
        return source
    }

    /// The image is staged under a name the legacy disk scanner cannot expose.
    /// Only the atomic history commit makes it the current grid/gallery version.
    /// Failure removes only the new output; all old versions remain unchanged.
    static func saveEdit(jpeg: Data, id: String, parentID: String, sourceID: String,
                         edit: String, style: String?, disclosure: String?, provenanceID: String?,
                         provenanceRecorded: Bool, directory: URL, originalAssetID: String? = nil, serverListingID: String? = nil,
                         stagingReferenceID: String? = nil, stagingBrief: String? = nil,
                         write: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> Version {
        lock.lock(); defer { lock.unlock() }
        var index = try loadUnlocked(directory: directory)
        guard safeName(id), !jpeg.isEmpty else { throw Failure.invalidHistory }
        guard index.versions[id] == nil else { throw Failure.duplicate }
        guard let parent = index.versions[parentID], let source = index.versions[sourceID],
              parent.familyID == source.familyID, index.isVisible(parentID) else { throw Failure.changedVersion }
        let expectedSourceID = edit == "stage" ? (parent.stagingBaseID ?? parentID) : parentID
        guard sourceID == expectedSourceID else { throw Failure.changedVersion }
        try requireImage(source.imageFile, directory: directory)
        if let stagingReferenceID {
            guard edit == "stage", let reference = index.versions[stagingReferenceID],
                  reference.effects.contains("stage"), reference.stagingReviewed == true else { throw Failure.reviewRequired }
        }
        let imageName = "edit-\(id).jpg", imageURL = directory.appendingPathComponent("edit-\(id).jpg")
        guard !FileManager.default.fileExists(atPath: imageURL.path) else { throw Failure.duplicate }
        var effects = source.effects
        if !effects.contains(edit) { effects.append(edit) }
        var version = Version(id: id, familyID: parent.familyID, imageFile: imageName,
                              originalFile: parent.originalFile, originalVerified: parent.originalVerified,
                              parentID: parentID, sourceID: sourceID,
                              stagingBaseID: edit == "stage" ? sourceID : source.stagingBaseID,
                              edit: edit, style: style, effects: effects, sourceHistoryKnown: source.sourceHistoryKnown,
                              disclosure: disclosure, provenanceID: provenanceID,
                              originalAssetID: originalAssetID, serverListingID: serverListingID,
                              provenanceRecorded: provenanceRecorded, createdAt: Date())
        version.stagingReferenceID = stagingReferenceID
        version.stagingBrief = stagingBrief
        do {
            try write(jpeg, imageURL)
            if index.listingSelections == nil { index.listingSelections = index.current }
            index.versions[id] = version; index.current[parent.familyID] = id
            // A generated window, displaced fixture, blocked door or mismatched
            // furniture must be reviewed rather than automatically published.
            if !effects.contains("stage") { index.listingSelections?[parent.familyID] = id }
            try save(index, directory: directory, write: write)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            throw error
        }
        return version
    }

    /// Select a saved version without generating again or discarding later edits.
    /// Only a complete retained image can become the listing's current version.
    static func select(id: String, directory: URL, reviewed: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        var index = try loadUnlocked(directory: directory)
        guard let version = index.versions[id], !index.hiddenFamilies.contains(version.familyID) else {
            throw Failure.changedVersion
        }
        try requireImage(version.imageFile, directory: directory)
        guard reviewed || !version.effects.contains("stage") || index.isSelectedForListing(id) else { throw Failure.reviewRequired }
        if reviewed, version.effects.contains("stage") { index.versions[id]?.stagingReviewed = true }
        index.current[version.familyID] = id
        if index.listingSelections == nil { index.listingSelections = index.current }
        index.listingSelections?[version.familyID] = id
        try save(index, directory: directory)
    }

    /// Choosing the public photo doesn't replace the editing workspace's latest
    /// version. Browsing/exporting a saved edit never calls this operation.
    static func selectForPublication(id: String, directory: URL, reviewed: Bool = false) throws {
        lock.lock(); defer { lock.unlock() }
        var index = try loadUnlocked(directory: directory)
        guard let version = index.versions[id], !index.hiddenFamilies.contains(version.familyID) else {
            throw Failure.changedVersion
        }
        try requireImage(version.imageFile, directory: directory)
        guard reviewed || !version.effects.contains("stage") || index.isSelectedForListing(id) else { throw Failure.reviewRequired }
        if reviewed, version.effects.contains("stage") { index.versions[id]?.stagingReviewed = true }
        if index.listingSelections == nil { index.listingSelections = index.current }
        index.listingSelections?[version.familyID] = id
        try save(index, directory: directory)
    }

    /// References are local to this listing directory and require an explicit
    /// user review recorded on this phone. They never replace the target source.
    static func stagingReference(id: String, directory: URL) throws -> Version {
        lock.lock(); defer { lock.unlock() }
        let index = try loadUnlocked(directory: directory)
        guard let version = index.versions[id], version.effects.contains("stage"),
              version.stagingReviewed == true, !index.hiddenFamilies.contains(version.familyID)
        else { throw Failure.reviewRequired }
        try requireImage(version.imageFile, directory: directory)
        return version
    }

    /// Cloud originals remain explicitly unverified; staged imports start as
    /// previews with their retained source selected until reviewed on this phone.
    static func registerImport(id: String, imageFile: String, originalFile: String,
                               staged: Bool, altered: Bool, directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        // Read first, before legacy adoption can misclassify the imported output.
        var index = try readIndex(directory: directory)
        if let existing = index.versions[id] {
            guard !index.hiddenFamilies.contains(existing.familyID) else { throw Failure.changedVersion }
            guard existing.imageFile == imageFile else { throw Failure.duplicate }
            return
        }
        guard safeName(id) else { throw Failure.invalidHistory }
        try requireImage(imageFile, directory: directory); try requireImage(originalFile, directory: directory)
        let baseID = id + "-source"
        guard index.versions[baseID] == nil else { throw Failure.duplicate }
        let source = Version(id: baseID, familyID: id, imageFile: originalFile, originalFile: originalFile,
            originalVerified: false, parentID: nil, sourceID: nil, stagingBaseID: nil,
            edit: "legacy", style: nil, effects: [], sourceHistoryKnown: false, disclosure: nil,
            provenanceID: nil, originalAssetID: nil, serverListingID: nil, provenanceRecorded: false, createdAt: Date())
        let effects = staged ? ["stage"] : altered ? ["cloud-edit"] : []
        let output = Version(id: id, familyID: id, imageFile: imageFile, originalFile: originalFile,
            originalVerified: false, parentID: baseID, sourceID: baseID, stagingBaseID: staged ? baseID : nil,
            edit: staged ? "stage" : altered ? "cloud-edit" : "legacy", style: nil, effects: effects,
            sourceHistoryKnown: false, disclosure: nil, provenanceID: nil, originalAssetID: nil,
            serverListingID: nil, provenanceRecorded: false, createdAt: Date())
        if index.listingSelections == nil { index.listingSelections = index.current }
        index.versions[baseID] = source; index.versions[id] = output; index.current[id] = id
        index.listingSelections?[id] = staged || altered ? baseID : id
        // Save the new metadata before adopting other legacy families; reads
        // reconcile them as a set and the next change makes that set durable.
        try save(index, directory: directory)
    }

    /// Removing a family from the gallery keeps every image needed by its edit
    /// history and prior disclosures. It does not delete an already published asset.
    static func hide(id: String, directory: URL) throws {
        lock.lock(); defer { lock.unlock() }
        var index = try loadUnlocked(directory: directory)
        guard let version = index.versions[id] else { throw Failure.invalidHistory }
        index.hiddenFamilies.insert(version.familyID)
        try save(index, directory: directory)
    }
}

/// Integer geometry is shared by the full-resolution renderer and its tests.
/// Fit adds a neutral border; crop deliberately removes edges. Neither guesses
/// a listing service's requirements or upscales the photo's pixels.
enum PhotoExportLayout {
    enum Aspect: String, CaseIterable, Identifiable, Sendable {
        case original, landscape = "4:3", wide = "16:9", portrait = "9:16"
        var id: String { rawValue }
        var title: String { self == .original ? "Original aspect" : rawValue }
        var ratio: Double? {
            switch self { case .original: return nil; case .landscape: return 4 / 3
            case .wide: return 16 / 9; case .portrait: return 9 / 16 }
        }
    }
    enum Framing: String, CaseIterable, Identifiable, Sendable {
        case fit = "Fit · keep everything", crop = "Crop · trim edges"
        var id: String { rawValue }
    }
    struct Size: Equatable { let width: Int; let height: Int }
    static func size(width: Int, height: Int, aspect: Aspect, framing: Framing) -> Size {
        guard width > 0, height > 0, let ratio = aspect.ratio else { return Size(width: width, height: height) }
        let actual = Double(width) / Double(height)
        if framing == .crop {
            return actual > ratio ? Size(width: max(1, Int((Double(height) * ratio).rounded())), height: height)
                : Size(width: width, height: max(1, Int((Double(width) / ratio).rounded())))
        }
        let longest = max(width, height)
        return ratio >= 1 ? Size(width: longest, height: max(1, Int((Double(longest) / ratio).rounded())))
            : Size(width: max(1, Int((Double(longest) * ratio).rounded())), height: longest)
    }
}
