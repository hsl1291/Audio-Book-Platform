import Foundation

/// A single thing you hold (or intend to hold) of a `Work`.
///
/// Named `BookCopy` rather than `Copy` to stay clear of `Copyable`/`copy` in newer
/// Swift and to read unambiguously at call sites.
public struct BookCopy: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var workID: Work.ID
    public var format: Format
    public var provenance: Provenance
    /// How to reach the bytes. `nil` for formats we only track (Kindle, physical).
    public var sourceRef: SourceRef?
    public var byteCount: Int64?
    public var duration: TimeInterval?
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        workID: Work.ID,
        format: Format,
        provenance: Provenance,
        sourceRef: SourceRef? = nil,
        byteCount: Int64? = nil,
        duration: TimeInterval? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.workID = workID
        self.format = format
        self.provenance = provenance
        self.sourceRef = sourceRef
        self.byteCount = byteCount
        self.duration = duration
        self.addedAt = addedAt
    }

    public enum Format: String, Hashable, Codable, Sendable, CaseIterable {
        case audiobook, ebook, physical
    }

    /// Where a copy came from. Note there is deliberately no `.audible` case: the
    /// app reads playable files and does not model or care which store produced
    /// them. See "the folder is the contract" in the plan.
    public enum Provenance: String, Hashable, Codable, Sendable, CaseIterable {
        /// A playable audio file we found in a watched folder.
        case audioFile
        /// Known to be in the Kindle library, imported from an Amazon data export.
        /// Tracked only — never opened, never synced live.
        case kindle
        case physicalOwned
        case library
        case none
    }

    /// Whether this copy has bytes the player could ever reach.
    public var isPlayable: Bool {
        format == .audiobook && sourceRef != nil
    }
}

public enum SourceRef: Hashable, Codable, Sendable {
    /// A file in the connected Google Drive, by Drive file id.
    case googleDrive(fileID: String)
    /// A file reachable through the on-device file system or iCloud Drive.
    case localFile(relativePath: String)
    /// A Kindle ASIN. Identity only — there is no API behind it.
    case kindleASIN(String)
}

/// Where the bytes currently are, from the phone's point of view. Surfaced on every
/// row so offline state is never a surprise.
public enum LocalAvailability: String, Hashable, Codable, Sendable {
    case downloaded
    case partial
    case cloudOnly
    /// Tracked but not a file at all — Kindle, physical, or want-to-buy.
    case notAFile
}
