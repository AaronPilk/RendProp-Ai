import Foundation

/// User-selected cloud narration/scripts become ordinary local Reel Studio
/// inputs. Metadata never stores a signed URL or grants another account access.
enum CloudVoiceStore {
    private struct Record: Codable {
        var userID: String
        var script: String?
        var audioFilename: String?
        var voiceID: UUID?
        var duration: Double?
        var words: [CaptionWord]?
        var voiceName: String?
        var serverListingID: UUID?
        var voiceTranscript: String?
    }
    private static func metadata(_ listingID: UUID) -> URL {
        Voiceover.voiceoversDirectory.appendingPathComponent("\(listingID.uuidString)-studio.json")
    }
    @MainActor private static func read(_ listingID: UUID) -> Record? {
        guard AuthStore.shared.isIdentified, let data = try? Data(contentsOf: metadata(listingID)), data.count <= 2 * 1024 * 1024,
              let record = try? JSONDecoder().decode(Record.self, from: data), record.userID == AuthStore.shared.userID else { return nil }
        return record
    }
    @MainActor static func script(_ listingID: UUID) -> String? { read(listingID)?.script }
    @MainActor static func saveScript(_ script: String, listingID: UUID) throws {
        guard AuthStore.shared.isIdentified, let userID = AuthStore.shared.userID, script.count <= 100_000 else { throw CloudSyncError.identityChanged }
        var record = read(listingID) ?? Record(userID: userID)
        record.script = script
        try JSONEncoder().encode(record).write(to: metadata(listingID), options: .atomic)
    }
    @MainActor static func saveVoice(_ result: CloudCreative.Result, file: URL, ext: String, listingID: UUID) throws {
        guard AuthStore.shared.isIdentified, let userID = AuthStore.shared.userID, let duration = result.duration_s,
              duration.isFinite, duration > 0, duration <= 3600, ["mp3", "m4a", "wav", "ogg"].contains(ext) else { throw CloudSyncError.invalidResponse }
        let filename = "\(listingID.uuidString)-studio-\(result.id.uuidString).\(ext)"
        let destination = Voiceover.voiceoversDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: file, to: destination) }
        var record = read(listingID) ?? Record(userID: userID)
        record.audioFilename = filename; record.voiceID = result.id; record.duration = duration
        record.words = result.words.map { CaptionWord(text: $0.text, start: $0.start, end: $0.end) }
        record.voiceName = result.voice_name
        record.serverListingID = result.listing_id
        record.voiceTranscript = result.words.map(\.text).joined(separator: " ")
        try JSONEncoder().encode(record).write(to: metadata(listingID), options: .atomic)
    }
    /// Keep a successful native generation and its genuine history receipt.
    /// The caller keeps playable paid audio even if this optional metadata write fails.
    @MainActor static func saveGeneratedVoice(_ voice: Voiceover, listingID: UUID) throws {
        guard AuthStore.shared.isIdentified, let userID = AuthStore.shared.userID,
              let ownerID = UUID(uuidString: userID), let reference = voice.sharedReference,
              reference.ownerID == ownerID, voice.source == .aiVoice,
              voice.duration.isFinite, voice.duration > 0, voice.duration <= 3600 else { throw CloudSyncError.invalidResponse }
        let ext = voice.audioURL.pathExtension.lowercased()
        guard ["mp3", "m4a", "wav", "ogg"].contains(ext) else { throw CloudSyncError.invalidResponse }
        let filename = "\(listingID.uuidString)-studio-\(reference.resultID.uuidString).\(ext)"
        let destination = Voiceover.voiceoversDirectory.appendingPathComponent(filename)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: voice.audioURL, to: destination) }
        var record = read(listingID) ?? Record(userID: userID)
        record.audioFilename = filename; record.voiceID = reference.resultID; record.duration = voice.duration
        record.words = voice.words; record.voiceName = voice.voiceName; record.script = voice.transcript
        record.serverListingID = reference.listingID
        record.voiceTranscript = voice.transcript
        try JSONEncoder().encode(record).write(to: metadata(listingID), options: .atomic)
    }
    @MainActor static func voice(_ listingID: UUID) -> Voiceover? {
        guard let record = read(listingID), let filename = record.audioFilename,
              filename.hasPrefix("\(listingID.uuidString)-studio-"), !filename.contains("/"), !filename.contains("\\"),
              let id = record.voiceID, let duration = record.duration, duration.isFinite, duration > 0 else { return nil }
        let file = Voiceover.voiceoversDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let words = record.words ?? []
        let reference: SharedVoiceReference? = record.serverListingID.flatMap { listingID in
            UUID(uuidString: record.userID).map { SharedVoiceReference(resultID: id, ownerID: $0, listingID: listingID) }
        }
        return Voiceover(id: id, audioURL: file, duration: duration, transcript: record.voiceTranscript ?? words.map(\.text).joined(separator: " "), words: words, source: .aiVoice, voiceName: record.voiceName, sharedReference: reference)
    }
}
