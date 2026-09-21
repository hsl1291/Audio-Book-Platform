import Foundation

/// What we can learn about an audiobook from the file itself.
///
/// Every field is optional on purpose: files arrive from different stores and none
/// of them tag identically. The identification cascade treats this as the most
/// trustworthy source when present, and falls through when it is not.
public struct AudioMetadata: Hashable, Sendable {
    public var title: String?
    public var subtitle: String?
    public var author: String?
    public var narrator: String?
    public var album: String?
    public var genre: String?
    public var year: Int?
    public var summary: String?
    public var duration: TimeInterval?
    /// Raw bytes of the embedded cover, with the image type that was declared.
    public var artwork: Artwork?
    /// Any catalogue identifier the file declared about itself.
    public var catalogID: CatalogID?

    public init(
        title: String? = nil,
        subtitle: String? = nil,
        author: String? = nil,
        narrator: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        year: Int? = nil,
        summary: String? = nil,
        duration: TimeInterval? = nil,
        artwork: Artwork? = nil,
        catalogID: CatalogID? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.author = author
        self.narrator = narrator
        self.album = album
        self.genre = genre
        self.year = year
        self.summary = summary
        self.duration = duration
        self.artwork = artwork
        self.catalogID = catalogID
    }

    public struct Artwork: Hashable, Sendable {
        public enum Kind: Sendable { case jpeg, png, unknown }
        public var kind: Kind
        public var data: Data

        public init(kind: Kind, data: Data) {
            self.kind = kind
            self.data = data
        }
    }

    public var isEmpty: Bool {
        title == nil && author == nil && narrator == nil && album == nil
            && duration == nil && artwork == nil
    }

    /// Best guess at the work title. Falls back to the album, since audiobook
    /// taggers disagree about which of the two carries the book's name.
    public var bestTitle: String? {
        title ?? album
    }

    /// A match key built from what the file claims about itself. Unlike the
    /// scan-time key, this one has an author, so it can reach full confidence.
    public var matchKey: MatchKey? {
        guard let bestTitle else { return nil }
        return MatchKey(title: bestTitle, author: author)
    }
}
