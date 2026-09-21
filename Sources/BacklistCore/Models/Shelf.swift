import Foundation

/// Reading state for a `Work`. One value per work, not a free-form tag set —
/// the four screens depend on these being mutually exclusive.
public enum Shelf: String, Hashable, Codable, Sendable, CaseIterable {
    case want
    case owned
    case reading
    case finished
    case abandoned
    /// Kept deliberately and re-consulted; never expected to leave the library.
    case reference
}

/// Whether, and how urgently, you mean to acquire a work you do not hold.
public enum Intent: String, Hashable, Codable, Sendable, CaseIterable {
    case needToPurchase
    case wishlist
    case none
}

/// Your own record of having read something. Distinct from `Work` metadata, which
/// describes the book; this describes you.
public struct Journal: Hashable, Codable, Sendable {
    public var workID: Work.ID
    /// 1...5, or nil when unrated. Note that every one of the 130 rows on the
    /// Goodreads shelf is unrated, so nil is the common case on import, not an edge.
    public var rating: Int?
    public var review: String?
    public var notes: String?
    public var startedAt: Date?
    public var finishedAt: Date?
    /// Goodreads tracks this and it is worth keeping — a reread is not a new work.
    public var readCount: Int

    public init(
        workID: Work.ID,
        rating: Int? = nil,
        review: String? = nil,
        notes: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        readCount: Int = 0
    ) {
        self.workID = workID
        self.rating = rating
        self.review = review
        self.notes = notes
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.readCount = readCount
    }

    public var isRated: Bool { rating != nil }
    public var hasReview: Bool { !(review ?? "").isEmpty }
}

/// Saved position in an audiobook. Written every 15s and on every chapter boundary,
/// so a crash costs seconds rather than a listening session.
public struct PlaybackPosition: Hashable, Codable, Sendable {
    public var copyID: BookCopy.ID
    public var offset: TimeInterval
    public var chapterIndex: Int?
    /// Per-book, because the right speed for dense nonfiction is not the right
    /// speed for a memoir.
    public var rate: Float
    public var updatedAt: Date

    public init(
        copyID: BookCopy.ID,
        offset: TimeInterval,
        chapterIndex: Int? = nil,
        rate: Float = 1.0,
        updatedAt: Date = Date()
    ) {
        self.copyID = copyID
        self.offset = offset
        self.chapterIndex = chapterIndex
        self.rate = rate
        self.updatedAt = updatedAt
    }
}
