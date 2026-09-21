import Foundation
import SwiftData
import BacklistCore

// SwiftData models backed by the CloudKit private database.
//
// CloudKit imposes rules that shape every declaration in this file:
//   * every property must be optional or carry a default — CloudKit cannot
//     represent a required field that existing records lack
//   * `@Attribute(.unique)` is unavailable, so uniqueness is enforced in code
//     rather than by the store (see `LibraryStore.upsert`)
//   * every relationship must be optional and needs an explicit inverse
//
// Audio files are deliberately *not* stored here. Only the tracking graph syncs;
// the bytes stay on each device and are re-fetched as needed. That is what keeps
// a 41 GB library inside a free iCloud tier.

@Model
final class StoredWork {
    var identifier: UUID = UUID()
    var title: String = ""
    var authorsJoined: String = ""
    var narratorsJoined: String = ""
    var isbn13: String?
    var asin: String?
    var publishedYear: Int?
    var summary: String?
    var addedAt: Date = Date()

    /// Raw value of `Shelf`. Stored as a string so a future case cannot corrupt
    /// existing records the way a reordered integer enum would.
    var shelfRaw: String = Shelf.want.rawValue
    var intentRaw: String = Intent.none.rawValue

    var rating: Int?
    var review: String?
    var notes: String?
    var startedAt: Date?
    var finishedAt: Date?
    var readCount: Int = 0

    /// Hidden from the home screen, widgets, CarPlay and external displays.
    var isPrivate: Bool = false
    var goodreadsID: String?
    var tagsJoined: String = ""

    /// Locally cached cover, keyed by content hash. Never synced.
    var coverCacheKey: String?
    var remoteCoverURL: String?

    @Relationship(deleteRule: .cascade, inverse: \StoredCopy.work)
    var copies: [StoredCopy]? = []

    init(identifier: UUID = UUID(), title: String = "") {
        self.identifier = identifier
        self.title = title
    }

    // MARK: - Bridging to the domain types

    var shelf: Shelf {
        get { Shelf(rawValue: shelfRaw) ?? .want }
        set { shelfRaw = newValue.rawValue }
    }

    var intent: Intent {
        get { Intent(rawValue: intentRaw) ?? .none }
        set { intentRaw = newValue.rawValue }
    }

    var authors: [String] {
        get { Self.split(authorsJoined) }
        set { authorsJoined = newValue.joined(separator: "\u{001F}") }
    }

    var narrators: [String] {
        get { Self.split(narratorsJoined) }
        set { narratorsJoined = newValue.joined(separator: "\u{001F}") }
    }

    var tags: [String] {
        get { Self.split(tagsJoined) }
        set { tagsJoined = newValue.joined(separator: "\u{001F}") }
    }

    /// Unit separator rather than a comma, because author names contain commas
    /// ("Bird, Kai") and splitting on one would invent an author.
    private static func split(_ joined: String) -> [String] {
        joined.split(separator: "\u{001F}").map(String.init).filter { !$0.isEmpty }
    }

    var work: Work {
        Work(
            id: identifier,
            title: title,
            authors: authors,
            narrators: narrators,
            isbn13: isbn13,
            asin: asin,
            publishedYear: publishedYear,
            summary: summary,
            coverRef: coverCacheKey.map { CoverRef.embedded(cacheKey: $0) }
                ?? remoteCoverURL.flatMap(URL.init(string:)).map(CoverRef.remote),
            addedAt: addedAt
        )
    }

    var journal: Journal {
        Journal(
            workID: identifier,
            rating: rating,
            review: review,
            notes: notes,
            startedAt: startedAt,
            finishedAt: finishedAt,
            readCount: readCount
        )
    }

    // MARK: - Derived state the screens query on

    var hasPlayableCopy: Bool {
        (copies ?? []).contains { $0.isPlayable }
    }

    /// Everything owned and not yet finished. This is the Waiting to Read rule,
    /// and the one the user stated directly: a book leaves the grid the moment it
    /// is marked finished.
    var isWaitingToRead: Bool {
        !(copies ?? []).isEmpty && shelf != .finished && shelf != .abandoned
    }
}

@Model
final class StoredCopy {
    var identifier: UUID = UUID()
    var formatRaw: String = BookCopy.Format.audiobook.rawValue
    var provenanceRaw: String = BookCopy.Provenance.audioFile.rawValue

    /// Discriminated reference to the bytes. Kept as separate scalars because
    /// CloudKit cannot store an associated-value enum.
    var driveFileID: String?
    var localRelativePath: String?
    var kindleASIN: String?

    var byteCount: Int64?
    var duration: Double?
    var addedAt: Date = Date()

    var availabilityRaw: String = LocalAvailability.cloudOnly.rawValue
    var isPinned: Bool = false
    /// Position in Up Next, or nil when not queued.
    var queuePosition: Int?
    var lastPlayedAt: Date?

    var positionOffset: Double = 0
    var positionChapter: Int?
    var playbackRate: Double = 1.0

    var work: StoredWork?

    init(identifier: UUID = UUID()) {
        self.identifier = identifier
    }

    var format: BookCopy.Format {
        get { BookCopy.Format(rawValue: formatRaw) ?? .audiobook }
        set { formatRaw = newValue.rawValue }
    }

    var provenance: BookCopy.Provenance {
        get { BookCopy.Provenance(rawValue: provenanceRaw) ?? .audioFile }
        set { provenanceRaw = newValue.rawValue }
    }

    var availability: LocalAvailability {
        get { LocalAvailability(rawValue: availabilityRaw) ?? .cloudOnly }
        set { availabilityRaw = newValue.rawValue }
    }

    var sourceRef: SourceRef? {
        get {
            if let driveFileID { return .googleDrive(fileID: driveFileID) }
            if let localRelativePath { return .localFile(relativePath: localRelativePath) }
            if let kindleASIN { return .kindleASIN(kindleASIN) }
            return nil
        }
        set {
            driveFileID = nil
            localRelativePath = nil
            kindleASIN = nil
            switch newValue {
            case .googleDrive(let id): driveFileID = id
            case .localFile(let path): localRelativePath = path
            case .kindleASIN(let asin): kindleASIN = asin
            case nil: break
            }
        }
    }

    var isPlayable: Bool {
        format == .audiobook && sourceRef != nil
    }

    var position: PlaybackPosition {
        PlaybackPosition(
            copyID: identifier,
            offset: positionOffset,
            chapterIndex: positionChapter,
            rate: Float(playbackRate)
        )
    }

    /// The policy engine's view of this copy.
    func managedFile(shelf: Shelf, finishedAt: Date?, isNowPlaying: Bool) -> ManagedFile {
        ManagedFile(
            copyID: identifier,
            byteCount: byteCount ?? 0,
            availability: isPlayable ? availability : .notAFile,
            isPinned: isPinned,
            shelf: shelf,
            queuePosition: queuePosition,
            lastPlayedAt: lastPlayedAt,
            finishedAt: finishedAt,
            isNowPlaying: isNowPlaying
        )
    }
}
