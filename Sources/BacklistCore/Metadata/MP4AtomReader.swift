import Foundation

/// Reads MP4/M4B metadata without downloading the file.
///
/// ## Why this exists
///
/// The library is ~41 GB across ~106 files averaging 400 MB, with the largest at
/// 920 MB. Showing a cover grid must not mean downloading any of that.
///
/// ## How it finds the metadata
///
/// An MP4 file is a flat chain of top-level atoms, each announcing its own length:
///
/// ```
/// [ftyp ~32B][moov ~1MB][mdat ~400MB]      "faststart" layout
/// [ftyp ~32B][mdat ~400MB][moov ~1MB]      the other common layout
/// ```
///
/// Because every header states its size, the chain can be *walked* — read 16 bytes,
/// learn the size, seek past it, repeat. Locating `moov` therefore costs three or
/// four 16-byte reads regardless of where it sits or how large `mdat` is. Only then
/// is the `moov` atom itself fetched, typically well under 1 MB.
///
/// This is strictly better than fetching a fixed window from each end of the file
/// and hoping `moov` fell inside it: it is exact rather than heuristic, it transfers
/// less, and it cannot be defeated by an unusually large `moov`.
///
/// Chapters are deliberately not parsed here. They live in a separate track whose
/// sample tables are expensive to walk, and once a file is on the device
/// `AVAsset.chapterMetadataGroups` reads them correctly for free.
public struct MP4AtomReader: Sendable {

    /// Cap on how much `moov` we will pull in one go. Well above any realistic
    /// audiobook, but present so a corrupt size field cannot request gigabytes.
    public static let maxMoovBytes = 32 * 1024 * 1024

    /// How many top-level atoms to walk before giving up on a malformed file.
    private static let maxTopLevelAtoms = 64

    public init() {}

    public enum Failure: Error, CustomStringConvertible {
        case notAnMP4
        case moovNotFound
        case moovTooLarge(Int64)

        public var description: String {
            switch self {
            case .notAnMP4: return "file does not begin with a recognisable MP4 atom"
            case .moovNotFound: return "no moov atom in the top-level chain"
            case .moovTooLarge(let size): return "moov claims \(size) bytes, refusing to read"
            }
        }
    }

    // MARK: - Entry point

    public func metadata(from reader: some ByteRangeReader) async throws -> AudioMetadata {
        let total = try await reader.totalLength
        let moov = try await locateMoov(in: reader, total: total)

        guard moov.payloadLength <= Int64(Self.maxMoovBytes) else {
            throw Failure.moovTooLarge(moov.payloadLength)
        }
        let body = try await reader.read(
            offset: moov.payloadOffset,
            length: Int(moov.payloadLength)
        )

        return Self.parse(moovBody: body)
    }

    // MARK: - Locating moov

    struct AtomHeader {
        var type: String
        /// Total atom size including its header.
        var totalSize: Int64
        var headerSize: Int
        var offset: Int64

        var payloadOffset: Int64 { offset + Int64(headerSize) }
        var payloadLength: Int64 { max(0, totalSize - Int64(headerSize)) }
        var next: Int64 { offset + totalSize }
    }

    /// Walk the top-level chain, reading only each atom's header.
    func locateMoov(in reader: some ByteRangeReader, total: Int64) async throws -> AtomHeader {
        var offset: Int64 = 0
        var seen = 0

        while offset < total, seen < Self.maxTopLevelAtoms {
            // 16 bytes covers a 64-bit extended size header.
            let head = try await reader.read(offset: offset, length: 16)
            guard let header = Self.parseHeader(head, at: offset, fileLength: total) else {
                if seen == 0 { throw Failure.notAnMP4 }
                throw Failure.moovNotFound
            }
            if header.type == "moov" { return header }

            // A zero-size atom means "to end of file"; nothing can follow it, and
            // treating it as a step of zero would spin forever.
            guard header.next > offset else { throw Failure.moovNotFound }
            offset = header.next
            seen += 1
        }
        throw Failure.moovNotFound
    }

    /// Decode one atom header. Returns nil when the bytes are not a plausible atom.
    static func parseHeader(_ bytes: Data, at offset: Int64, fileLength: Int64) -> AtomHeader? {
        guard let rawSize = bytes.beUInt32(at: 0), let type = bytes.fourCC(at: 4) else {
            return nil
        }
        guard Self.isPlausibleType(type) else { return nil }

        var totalSize = Int64(rawSize)
        var headerSize = 8

        if rawSize == 1 {
            // 64-bit extended size follows the type.
            guard let extended = bytes.beUInt64(at: 8), extended >= 16 else { return nil }
            totalSize = Int64(clamping: extended)
            headerSize = 16
        } else if rawSize == 0 {
            // Runs to end of file.
            totalSize = fileLength - offset
        } else if rawSize < 8 {
            return nil
        }

        guard totalSize >= Int64(headerSize), offset + totalSize <= fileLength else {
            // A size running past the end means we have lost the chain.
            return nil
        }
        return AtomHeader(type: type, totalSize: totalSize, headerSize: headerSize, offset: offset)
    }

    /// Atom types are four printable characters, optionally led by `©`.
    static func isPlausibleType(_ type: String) -> Bool {
        guard type.count == 4 else { return false }
        return type.unicodeScalars.allSatisfy { scalar in
            scalar == "\u{00A9}" || (scalar.value >= 0x20 && scalar.value <= 0x7E)
        }
    }

    // MARK: - Parsing moov

    /// Walk children of an atom body, calling `visit` for each.
    static func forEachChild(
        in body: Data,
        startingAt start: Int = 0,
        _ visit: (_ type: String, _ payload: Data) -> Void
    ) {
        var cursor = start
        while cursor + 8 <= body.count {
            guard let rawSize = body.beUInt32(at: cursor),
                  let type = body.fourCC(at: cursor + 4)
            else { return }

            var size = Int(rawSize)
            var headerSize = 8
            if rawSize == 1 {
                guard let extended = body.beUInt64(at: cursor + 8) else { return }
                size = Int(clamping: extended)
                headerSize = 16
            } else if rawSize == 0 {
                size = body.count - cursor
            }
            // Any of these means the chain is corrupt; stop rather than loop.
            guard size >= headerSize, cursor + size <= body.count else { return }

            let payloadStart = body.startIndex + cursor + headerSize
            let payloadEnd = body.startIndex + cursor + size
            visit(type, body[payloadStart..<payloadEnd])

            cursor += size
        }
    }

    /// Walk a `moov` body and collect everything we understand.
    ///
    /// `forEachChild` takes a non-escaping closure, so these nested walks can refer
    /// to `result` directly — no accumulator object, and no state that could survive
    /// between files.
    static func parse(moovBody: Data) -> AudioMetadata {
        var result = AudioMetadata()

        forEachChild(in: moovBody) { type, payload in
            switch type {
            case "mvhd":
                if let duration = duration(fromMVHD: payload) {
                    result.duration = duration
                }
            case "udta":
                forEachChild(in: payload) { udtaType, udtaPayload in
                    guard udtaType == "meta" else { return }
                    parseMeta(udtaPayload, into: &result)
                }
            case "meta":
                // Some taggers hang `meta` directly off `moov` rather than off
                // `udta`. Both layouts occur in the wild.
                parseMeta(payload, into: &result)
            default:
                break
            }
        }
        return result
    }

    /// A `meta` box carries four bytes of version and flags *before* its children.
    /// Failing to skip them is the single most common way MP4 tag parsers break —
    /// the first child header reads as garbage and the whole tag list is lost.
    static func parseMeta(_ payload: Data, into result: inout AudioMetadata) {
        forEachChild(in: payload, startingAt: 4) { metaType, metaPayload in
            guard metaType == "ilst" else { return }
            parseILST(metaPayload, into: &result)
        }
    }

    // MARK: - mvhd

    static func duration(fromMVHD payload: Data) -> TimeInterval? {
        guard let versionByte = payload.first else { return nil }
        let version = versionByte

        let timescale: UInt32?
        let units: UInt64?
        if version == 1 {
            // version+flags(4) creation(8) modification(8) timescale(4) duration(8)
            timescale = payload.beUInt32(at: 20)
            units = payload.beUInt64(at: 24)
        } else {
            // version+flags(4) creation(4) modification(4) timescale(4) duration(4)
            timescale = payload.beUInt32(at: 12)
            units = payload.beUInt32(at: 16).map(UInt64.init)
        }

        guard let scale = timescale, scale > 0, let value = units else { return nil }
        // 0xFFFFFFFF is the conventional "unknown duration" marker.
        guard value != UInt64(UInt32.max) else { return nil }
        return TimeInterval(value) / TimeInterval(scale)
    }

    // MARK: - ilst

    static func parseILST(_ body: Data, into metadata: inout AudioMetadata) {
        forEachChild(in: body) { type, payload in
            if type == "----" {
                // Freeform tag: `mean` (vendor), `name` (key), `data` (value).
                // Narrator commonly arrives this way rather than in a standard atom.
                var key: String?
                var value: String?
                forEachChild(in: payload) { subType, subPayload in
                    switch subType {
                    case "name":
                        key = decodeText(subPayload, skipping: 4)
                    case "data":
                        value = decodeDataAtomText(subPayload)
                    default:
                        break
                    }
                }
                freeformName = key
                if let key = key?.uppercased(), let value, !value.isEmpty {
                    switch key {
                    case "NARRATOR", "NARRATED_BY", "COMPOSER":
                        metadata.narrator = metadata.narrator ?? value
                    case "SUBTITLE":
                        metadata.subtitle = metadata.subtitle ?? value
                    case "ASIN", "AUDIBLE_ASIN":
                        if let id = FolderNameParser.classify(value) {
                            metadata.catalogID = metadata.catalogID ?? id
                        }
                    case "ISBN":
                        if let id = FolderNameParser.classify(value) {
                            metadata.catalogID = metadata.catalogID ?? id
                        }
                    default:
                        break
                    }
                }
                return
            }

            // Standard tags each wrap a single `data` atom.
            var text: String?
            var artwork: AudioMetadata.Artwork?
            forEachChild(in: payload) { subType, subPayload in
                guard subType == "data" else { return }
                if type == "covr" {
                    artwork = decodeArtwork(subPayload)
                } else {
                    text = decodeDataAtomText(subPayload)
                }
            }

            switch type {
            case "\u{00A9}nam": metadata.title = text ?? metadata.title
            case "\u{00A9}ART": metadata.author = text ?? metadata.author
            case "aART": metadata.author = metadata.author ?? text
            case "\u{00A9}alb": metadata.album = text ?? metadata.album
            case "\u{00A9}wrt": metadata.narrator = metadata.narrator ?? text
            case "\u{00A9}gen", "gnre": metadata.genre = text ?? metadata.genre
            case "\u{00A9}day": metadata.year = text.flatMap(parseYear) ?? metadata.year
            case "desc": metadata.summary = metadata.summary ?? text
            case "ldes": metadata.summary = text ?? metadata.summary
            case "covr": metadata.artwork = artwork ?? metadata.artwork
            default: break
            }
        }
    }

    /// A `data` atom is: typeIndicator(4) locale(4) payload.
    static func decodeDataAtomText(_ payload: Data) -> String? {
        guard payload.count > 8 else { return nil }
        let start = payload.startIndex + 8
        let text = String(data: payload[start...], encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    static func decodeText(_ payload: Data, skipping prefix: Int) -> String? {
        guard payload.count > prefix else { return nil }
        let start = payload.startIndex + prefix
        let text = String(data: payload[start...], encoding: .utf8)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    static func decodeArtwork(_ payload: Data) -> AudioMetadata.Artwork? {
        guard payload.count > 8, let indicator = payload.beUInt32(at: 0) else { return nil }
        let start = payload.startIndex + 8
        let bytes = Data(payload[start...])
        guard !bytes.isEmpty else { return nil }

        let kind: AudioMetadata.Artwork.Kind
        switch indicator {
        case 13: kind = .jpeg
        case 14: kind = .png
        default: kind = Self.sniffImageKind(bytes)
        }
        return AudioMetadata.Artwork(kind: kind, data: bytes)
    }

    /// Some taggers write artwork with a type indicator of 0. Fall back to magic
    /// bytes rather than discarding a perfectly good cover.
    static func sniffImageKind(_ data: Data) -> AudioMetadata.Artwork.Kind {
        guard data.count >= 8 else { return .unknown }
        let b = [UInt8](data.prefix(8))
        if b[0] == 0xFF, b[1] == 0xD8 { return .jpeg }
        if b[0] == 0x89, b[1] == 0x50, b[2] == 0x4E, b[3] == 0x47 { return .png }
        return .unknown
    }

    /// `©day` is sometimes a bare year, sometimes a full ISO timestamp.
    static func parseYear(_ raw: String) -> Int? {
        let digits = raw.prefix(4)
        guard digits.count == 4, let year = Int(digits), (1000...3000).contains(year) else {
            return nil
        }
        return year
    }
}

extension AudioMetadata {
    /// Fill in anything still missing from `other`. Never overwrites a value we
    /// already have, so earlier, more specific sources win.
    mutating func merge(_ other: AudioMetadata) {
        title = title ?? other.title
        subtitle = subtitle ?? other.subtitle
        author = author ?? other.author
        narrator = narrator ?? other.narrator
        album = album ?? other.album
        genre = genre ?? other.genre
        year = year ?? other.year
        summary = summary ?? other.summary
        duration = duration ?? other.duration
        artwork = artwork ?? other.artwork
        catalogID = catalogID ?? other.catalogID
    }
}
