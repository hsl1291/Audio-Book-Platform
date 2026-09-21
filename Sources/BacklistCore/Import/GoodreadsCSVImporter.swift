import Foundation

/// Imports a Goodreads library export.
///
/// Use the real CSV (My Books → Import and export → Export Library), not a printed
/// or saved copy of the shelf page. The printed page carries only title, author and
/// dates; the CSV additionally carries `My Rating`, `My Review`, `ISBN13`,
/// `Bookshelves` and `Read Count`. Since Goodreads retired its API in 2020, this
/// export is the only way those ever leave the site.
public struct GoodreadsCSVImporter {

    public struct ImportedBook: Sendable {
        public var work: Work
        public var journal: Journal
        public var shelf: Shelf
        public var intent: Intent
        /// Goodreads' own `Book Id`, kept so a re-import updates rather than duplicates.
        public var goodreadsID: String?
        /// Free-form shelves the user made, beyond the three exclusive ones.
        public var tags: [String]
    }

    public struct Summary: Sendable {
        public var books: [ImportedBook]
        /// Rows that could not be turned into a book, with the reason.
        public var skipped: [(row: Int, reason: String)]

        public var rated: Int { books.filter { $0.journal.isRated }.count }
        public var reviewed: Int { books.filter { $0.journal.hasReview }.count }
        public var finished: Int { books.filter { $0.shelf == .finished }.count }
        public var wanted: Int { books.filter { $0.shelf == .want }.count }
    }

    public init() {}

    public func `import`(csv text: String) throws -> Summary {
        let rows = try CSVParser.dictionaries(from: text)
        var books: [ImportedBook] = []
        var skipped: [(row: Int, reason: String)] = []

        for (offset, row) in rows.enumerated() {
            let lineNumber = offset + 2   // +1 for zero-indexing, +1 for the header
            let title = row["Title"]?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !title.isEmpty else {
                skipped.append((lineNumber, "no title"))
                continue
            }
            books.append(makeBook(from: row, title: title))
        }

        return Summary(books: books, skipped: skipped)
    }

    // MARK: - Row mapping

    private func makeBook(from row: [String: String], title: String) -> ImportedBook {
        let authors = Self.authors(from: row)
        let shelf = Self.shelf(from: row["Exclusive Shelf"])

        let work = Work(
            title: title,
            authors: authors,
            isbn13: Self.unescapeExcel(row["ISBN13"]),
            publishedYear: Self.year(from: row["Original Publication Year"])
                ?? Self.year(from: row["Year Published"]),
            addedAt: Self.date(from: row["Date Added"]) ?? Date()
        )

        let journal = Journal(
            workID: work.id,
            rating: Self.rating(from: row["My Rating"]),
            review: Self.cleanReview(row["My Review"]),
            notes: Self.nonEmpty(row["Private Notes"]),
            finishedAt: Self.date(from: row["Date Read"]),
            readCount: Int(Self.nonEmpty(row["Read Count"]) ?? "") ?? 0
        )

        return ImportedBook(
            work: work,
            journal: journal,
            shelf: shelf,
            // Anything you want to read but hold no copy of is, by definition, on
            // the shopping list. The Drive scan later downgrades this to .none for
            // books that turn out to have a file.
            intent: shelf == .want ? .needToPurchase : .none,
            goodreadsID: Self.nonEmpty(row["Book Id"]),
            tags: Self.tags(from: row["Bookshelves"])
        )
    }

    // MARK: - Field helpers

    /// Goodreads' three exclusive shelves. Anything unrecognised is treated as
    /// wanted rather than dropped, so nothing silently disappears on import.
    static func shelf(from raw: String?) -> Shelf {
        switch (raw ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "read": return .finished
        case "currently-reading": return .reading
        case "to-read": return .want
        case "abandoned", "did-not-finish", "dnf": return .abandoned
        default: return .want
        }
    }

    /// Prefer the plain `Author` column, then fold in `Additional Authors`.
    /// `Author l-f` is ignored here — `MatchKey.surname` handles either ordering,
    /// so there is no need to carry both.
    static func authors(from row: [String: String]) -> [String] {
        var result: [String] = []
        if let primary = nonEmpty(row["Author"]) {
            result.append(primary)
        } else if let lastFirst = nonEmpty(row["Author l-f"]) {
            result.append(lastFirst)
        }
        if let additional = nonEmpty(row["Additional Authors"]) {
            result.append(
                contentsOf: additional
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
        }
        return result
    }

    /// Goodreads writes 0 for "not rated", which is not a rating of zero stars.
    /// Every one of the 130 rows on the current shelf is unrated, so nil is the
    /// common case here, not an edge case.
    static func rating(from raw: String?) -> Int? {
        guard let value = Int(nonEmpty(raw) ?? ""), (1...5).contains(value) else { return nil }
        return value
    }

    /// ISBN columns are Excel-escaped as `="0593148193"`, and empty ones as `=""`.
    /// Taking these at face value yields an ISBN with literal quotes in it.
    static func unescapeExcel(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("=") { s.removeFirst() }
        if s.hasPrefix("\"") { s.removeFirst() }
        if s.hasSuffix("\"") { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }

    /// Goodreads dates are `YYYY/MM/DD`, in no stated time zone. Parsed as UTC noon
    /// so a device in any zone still reports the same calendar day.
    static func date(from raw: String?) -> Date? {
        guard let s = nonEmpty(raw) else { return nil }
        let parts = s.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar.date(from: components)
    }

    static func year(from raw: String?) -> Int? {
        guard let value = Int(nonEmpty(raw) ?? ""), value > 0 else { return nil }
        return value
    }

    /// Reviews are stored with HTML line breaks. Convert the ones that carry
    /// meaning and leave everything else alone — this is a reader's own prose, not
    /// a document to reformat.
    static func cleanReview(_ raw: String?) -> String? {
        guard let s = nonEmpty(raw) else { return nil }
        let unwrapped = s
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return unwrapped.isEmpty ? nil : unwrapped
    }

    /// User-made shelves, minus the three exclusive ones which are already modelled.
    static func tags(from raw: String?) -> [String] {
        let exclusive: Set<String> = ["read", "currently-reading", "to-read"]
        return (nonEmpty(raw) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !exclusive.contains($0.lowercased()) }
    }

    static func nonEmpty(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return nil
        }
        return s
    }
}
