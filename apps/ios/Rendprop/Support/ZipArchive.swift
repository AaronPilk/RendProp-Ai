import Foundation

/// A minimal ZIP writer: PKZIP 2.0 "store" entries with UTF-8 names, one
/// archive an agent can hand to whoever runs their file — a transaction
/// coordinator, an office, a client — instead of fifty loose attachments.
///
/// Why store, not deflate: every photo this app exports is already a JPEG
/// (or a retained HEIC/PNG source), so compression would cost seconds and
/// save nothing; the disclosure text files are a few hundred bytes. Storing
/// keeps the bytes exact and the writer small enough to read in one sitting.
/// Nothing it packages is modified, and the archive is never read back here.
/// Zip64 is deliberately not implemented: an export over 4 GB fails loudly.
enum ZipArchive {
    struct Entry: Sendable {
        /// The name inside the archive: a plain file name or `folder/name`.
        let name: String
        /// The bytes to store, read twice (checksum, then copy).
        let url: URL
    }

    struct Failure: LocalizedError, Sendable {
        let message: String
        var errorDescription: String? { message }
    }

    /// Classic ZIP limits. Sizes and offsets are 32-bit without Zip64.
    static let maximumBytes: UInt64 = 0xFFFF_FFFE
    static let maximumEntries = 65_534
    private static let readChunk = 1 << 20

    /// Write `entries`, in order, to `destination` (replaced if it exists).
    @discardableResult
    static func write(_ entries: [Entry], to destination: URL, modified: Date = Date()) throws -> URL {
        guard !entries.isEmpty else { throw Failure(message: "There is nothing to package.") }
        guard entries.count <= maximumEntries else { throw Failure(message: "Too many files for one ZIP archive.") }
        var seen = Set<String>()
        for entry in entries {
            guard isSafeName(entry.name) else { throw Failure(message: "A file name cannot be stored in a ZIP archive: \(entry.name)") }
            guard seen.insert(entry.name).inserted else { throw Failure(message: "Two files share the name \(entry.name).") }
        }
        let (dosTime, dosDate) = dosTimestamp(modified)
        try? FileManager.default.removeItem(at: destination)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw Failure(message: "Couldn't create the ZIP archive. Free some space and try again.")
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var centralDirectory = Data()
        var offset: UInt64 = 0
        for entry in entries {
            let (crc, size) = try checksum(of: entry.url)
            guard size <= maximumBytes else { throw Failure(message: "\(entry.name) is too large for a ZIP archive.") }
            let name = Data(entry.name.utf8)
            var local = Data(capacity: 30 + name.count)
            local.append(le32(0x0403_4b50))          // local file header
            local.append(le16(20))                   // version needed: 2.0
            local.append(le16(0x0800))               // flags: names are UTF-8
            local.append(le16(0))                    // method: store
            local.append(le16(dosTime))
            local.append(le16(dosDate))
            local.append(le32(crc))
            local.append(le32(UInt32(size)))         // compressed size (= stored)
            local.append(le32(UInt32(size)))         // uncompressed size
            local.append(le16(UInt16(name.count)))
            local.append(le16(0))                    // no extra field
            local.append(name)
            try output.write(contentsOf: local)
            try copy(entry.url, to: output, expectedSize: size, expectedCRC: crc, name: entry.name)
            var record = Data(capacity: 46 + name.count)
            record.append(le32(0x0201_4b50))         // central directory header
            record.append(le16(20))                  // version made by: 2.0, MS-DOS attributes
            record.append(le16(20))                  // version needed
            record.append(le16(0x0800))
            record.append(le16(0))
            record.append(le16(dosTime))
            record.append(le16(dosDate))
            record.append(le32(crc))
            record.append(le32(UInt32(size)))
            record.append(le32(UInt32(size)))
            record.append(le16(UInt16(name.count)))
            record.append(le16(0))                   // extra
            record.append(le16(0))                   // comment
            record.append(le16(0))                   // disk number start
            record.append(le16(0))                   // internal attributes
            record.append(le32(0))                   // external attributes
            guard offset <= maximumBytes else { throw Failure(message: "The export is too large for one ZIP archive.") }
            record.append(le32(UInt32(offset)))      // local header offset
            record.append(name)
            centralDirectory.append(record)
            offset += UInt64(local.count) + size
        }
        guard offset <= maximumBytes, UInt64(centralDirectory.count) <= maximumBytes,
              offset + UInt64(centralDirectory.count) <= maximumBytes else {
            throw Failure(message: "The export is too large for one ZIP archive.")
        }
        try output.write(contentsOf: centralDirectory)
        var end = Data(capacity: 22)
        end.append(le32(0x0605_4b50))                // end of central directory
        end.append(le16(0))                          // this disk
        end.append(le16(0))                          // disk with the central directory
        end.append(le16(UInt16(entries.count)))      // entries on this disk
        end.append(le16(UInt16(entries.count)))      // entries total
        end.append(le32(UInt32(centralDirectory.count)))
        end.append(le32(UInt32(offset)))             // central directory offset
        end.append(le16(0))                          // no comment
        try output.write(contentsOf: end)
        try output.synchronize()
        return destination
    }

    /// Names are relative, forward-slash separated, never escaping the archive.
    static func isSafeName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 65_535, !name.hasPrefix("/"), !name.hasSuffix("/"),
              !name.contains("\\"), !name.contains("\0"), !name.contains("//") else { return false }
        return !name.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }

    /// A file name an archive, Files, Finder and Windows all accept.
    static func safeFileName(_ raw: String, fallback: String = "Rendprop") -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_,.()&#'"))
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where allowed.contains(scalar) { scalars.append(scalar) }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let trimmed = String(collapsed.prefix(80)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? fallback : trimmed
    }

    // MARK: - Bytes

    private static func checksum(of url: URL) throws -> (crc: UInt32, size: UInt64) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt64 = 0
        while let chunk = try input.read(upToCount: readChunk), !chunk.isEmpty {
            crc = update(crc: crc, with: chunk)
            size += UInt64(chunk.count)
        }
        return (crc ^ 0xFFFF_FFFF, size)
    }

    /// Second pass: copy the bytes and re-check them, so a file that changed
    /// between the checksum and the copy fails instead of shipping corrupt.
    private static func copy(_ url: URL, to output: FileHandle, expectedSize: UInt64, expectedCRC: UInt32, name: String) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var crc: UInt32 = 0xFFFF_FFFF
        var size: UInt64 = 0
        while let chunk = try input.read(upToCount: readChunk), !chunk.isEmpty {
            size += UInt64(chunk.count)
            guard size <= expectedSize else { throw Failure(message: "\(name) changed while it was being packaged. Try again.") }
            crc = update(crc: crc, with: chunk)
            try output.write(contentsOf: chunk)
        }
        guard size == expectedSize, crc ^ 0xFFFF_FFFF == expectedCRC else {
            throw Failure(message: "\(name) changed while it was being packaged. Try again.")
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index)
        for _ in 0..<8 { value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func update(crc: UInt32, with data: Data) -> UInt32 {
        var value = crc
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        }
        return value
    }

    /// Standard CRC-32 (IEEE 802.3) of a complete buffer.
    static func crc32(_ data: Data) -> UInt32 { update(crc: 0xFFFF_FFFF, with: data) ^ 0xFFFF_FFFF }

    static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year: Int = min(max(parts.year ?? 1980, 1980), 2107)
        let hour: Int = parts.hour ?? 0
        let minute: Int = parts.minute ?? 0
        let second: Int = parts.second ?? 0
        let month: Int = parts.month ?? 1
        let day: Int = parts.day ?? 1
        let timeValue: Int = (hour << 11) | (minute << 5) | (second / 2)
        let dateValue: Int = ((year - 1980) << 9) | (month << 5) | day
        return (UInt16(timeValue), UInt16(dateValue))
    }

    private static func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
    private static func le32(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }
}
