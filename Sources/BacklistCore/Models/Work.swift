import Foundation

/// A book as a *work*, independent of the format you happen to hold it in.
///
/// This is the deliberate split at the centre of Backlist: `Work` is the thing an
/// author wrote, `BookCopy` is a thing you own. Keeping them apart is what lets the
/// library express states the old folder tree could not — "I own the audio but not
/// the ebook", "I want this but own nothing", and the ~54 titles finished on
/// Goodreads with no audio file anywhere in Drive.
public struct Work: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var title: String
    /// Display order matters; first author is the primary one.
    public var authors: [String]
    public var narrators: [String]
    public var isbn13: String?
    /// Audible ASIN when known. Present for 76 of the 106 existing books, absent for
    /// anything bought elsewhere, so nothing may depend on it.
    public var asin: String?
    public var publishedYear: Int?
    public var summary: String?
    /// Where the cover came to us from. Local file first, remote as fallback.
    public var coverRef: CoverRef?
    public var addedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        authors: [String] = [],
        narrators: [String] = [],
        isbn13: String? = nil,
        asin: String? = nil,
        publishedYear: Int? = nil,
        summary: String? = nil,
        coverRef: CoverRef? = nil,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.authors = authors
        self.narrators = narrators
        self.isbn13 = isbn13
        self.asin = asin
        self.publishedYear = publishedYear
        self.summary = summary
        self.coverRef = coverRef
        self.addedAt = addedAt
    }

    public var primaryAuthor: String? { authors.first }

    /// Title and first author, normalised for fuzzy matching. See `MatchKey`.
    public var matchKey: MatchKey {
        MatchKey(title: title, author: authors.first)
    }
}

public enum CoverRef: Hashable, Codable, Sendable {
    /// Extracted from the `covr` atom of the audio file and cached on disk.
    case embedded(cacheKey: String)
    /// Fetched from Open Library / Google Books for works with no local file.
    case remote(url: URL)
}
