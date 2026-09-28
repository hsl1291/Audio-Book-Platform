import Foundation

/// Reads the Kindle books you own out of an Amazon data export.
///
/// There is no Kindle API. Amazon's "Request My Data" archive is the only record,
/// and it is not one documented format: it is a folder of CSV and JSON files whose
/// names and column headings have changed between exports. So this reads *any*
/// CSV or JSON file, recognises columns by a list of synonyms, and keeps the rows
/// that look like Kindle books. A file with nothing recognisable yields nothing
/// rather than an error, so a whole folder can be offered file by file.
///
/// Track-only: this records that a book is owned as an ebook. Reading happens in
/// the Kindle app.
public enum KindleImporter {

    public struct Book: Hashable, Sendable {
        /// The *Kindle* ASIN. Not the audiobook's ASIN — the same book has a
        /// different ASIN in each format, so this must never be used to match
        /// against an audiobook.
        public var asin: String
        public var title: String
        public var author: String?
        public var acquiredAt: Date?

        public var matchKey: MatchKey { MatchKey(title: title, author: author) }
    }

    public struct Summary: Sendable {
        public var books: [Book]
        /// Rows recognised but left out: Audible titles, apps, music, video.
        public var skippedNonBooks: Int
    }

    // MARK: - Entry points

    /// Import one file. The format is decided by content, not by extension, since
    /// exports are often renamed.
    public static func `import`(_ data: Data) -> Summary {
        if let json = try? JSONSerialization.jsonObject(with: data) {
            return summarise(rows(fromJSON: json))
        }
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1),
              let table = try? CSVParser.rows(from: text)
        else { return Summary(books: [], skippedNonBooks: 0) }
        return summarise(rows(fromCSV: table))
    }

    /// Combine several files' results, keeping one entry per ASIN.
    public static func merge(_ summaries: [Summary]) -> Summary {
        summarise(
            summaries.flatMap { $0.books.map(Row.init) },
            skipped: summaries.reduce(0) { $0 + $1.skippedNonBooks }
        )
    }

    // MARK: - Column recognition

    enum Field: CaseIterable {
        case asin, title, author, date, category
    }

    /// Header synonyms, compared after lowercasing and removing everything but
    /// letters and digits, so "Product Name", "product_name" and "ProductName" are
    /// one heading.
    static let synonyms: [Field: Set<String>] = [
        .asin: ["asin", "productasin", "bookasin"],
        .title: ["title", "producttitle", "productname", "booktitle", "name", "itemtitle"],
        .author: ["author", "authors", "authorname", "contributor", "contributors", "creator"],
        .date: ["orderdate", "purchasedate", "acquireddate", "acquired", "dateadded",
                "creationdate", "orderdatetime"],
        .category: ["productcategory", "category", "contenttype", "producttype",
                    "resourcetype", "itemtype", "binding", "format"],
    ]

    static func squash(_ header: String) -> String {
        String(header.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }

    static func field(for header: String) -> Field? {
        let key = squash(header)
        return Field.allCases.first { synonyms[$0]?.contains(key) == true }
    }

    // MARK: - Rows

    struct Row {
        var asin: String?
        var title: String?
        var author: String?
        var date: String?
        var category: String?

        init(asin: String?, title: String?, author: String?, date: String?, category: String?) {
            self.asin = asin
            self.title = title
            self.author = author
            self.date = date
            self.category = category
        }

        init(_ book: Book) {
            asin = book.asin
            title = book.title
            author = book.author
            date = book.acquiredAt?.ISO8601Format()
            category = nil
        }

        mutating func set(_ field: Field, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "not available" else { return }
            switch field {
            case .asin: asin = asin ?? trimmed
            case .title: title = title ?? trimmed
            case .author: author = author ?? trimmed
            case .date: date = date ?? trimmed
            case .category: category = category ?? trimmed
            }
        }
    }

    static func rows(fromCSV table: [[String]]) -> [Row] {
        guard let header = table.first else { return [] }
        let fields = header.map(field(for:))
        guard fields.contains(.asin), fields.contains(.title) else { return [] }

        return table.dropFirst().map { cells in
            var row = Row(asin: nil, title: nil, author: nil, date: nil, category: nil)
            for (index, cell) in cells.enumerated() where index < fields.count {
                if let field = fields[index] { row.set(field, cell) }
            }
            return row
        }
    }

    /// Any object anywhere in the tree with both an ASIN and a title is a row.
    static func rows(fromJSON value: Any) -> [Row] {
        var found: [Row] = []
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                var row = Row(asin: nil, title: nil, author: nil, date: nil, category: nil)
                for (key, child) in object {
                    guard let field = field(for: key) else { continue }
                    if let text = child as? String {
                        row.set(field, text)
                    } else if let list = child as? [String], let first = list.first {
                        row.set(field, first)
                    }
                }
                if row.asin != nil && row.title != nil { found.append(row) }
                object.values.forEach(walk)
            } else if let array = node as? [Any] {
                array.forEach(walk)
            }
        }
        walk(value)
        return found
    }

    // MARK: - Filtering

    /// Kindle ASINs are ten characters starting "B0". Anything else — an ISBN, an
    /// order number in the wrong column — is not a Kindle book.
    static func isKindleASIN(_ value: String) -> Bool {
        value.count == 10 && value.uppercased().hasPrefix("B0")
            && value.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Digital-order exports mix in Audible titles, apps, music and video. With a
    /// category column, keep only rows that say they are books and do not say
    /// they are audio. Without one, keep everything that has a Kindle ASIN.
    static func isBookCategory(_ category: String?) -> Bool {
        guard let raw = category?.lowercased(), !raw.isEmpty else { return true }
        let audio = ["audible", "audio", "music", "mp3", "video", "app", "game"]
        if audio.contains(where: raw.contains) { return false }
        return ["kindle", "ebook", "e-book", "book", "digital_text", "digital text"]
            .contains(where: raw.contains)
    }

    /// Store titles carry edition noise that other sources do not.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw
        for noise in [" (Kindle Edition)", " Kindle Edition", " (Kindle eBook)", " eBook"] {
            if let range = title.range(of: noise, options: [.caseInsensitive, .backwards]),
               range.upperBound == title.endIndex {
                title.removeSubrange(range)
            }
        }
        // Trailing series note: "Project Hail Mary (A Novel)", "Dune (Dune Book 1)".
        if title.hasSuffix(")"), let open = title.range(of: " (", options: .backwards),
           open.lowerBound > title.startIndex {
            title = String(title[..<open.lowerBound])
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func summarise(_ rows: [Row], skipped: Int = 0) -> Summary {
        var seen: Set<String> = []
        var books: [Book] = []
        var skippedNonBooks = skipped

        for row in rows {
            guard let asin = row.asin?.uppercased(), let title = row.title else { continue }
            guard isKindleASIN(asin), isBookCategory(row.category) else {
                skippedNonBooks += 1
                continue
            }
            guard seen.insert(asin).inserted else { continue }
            books.append(Book(
                asin: asin,
                title: cleanTitle(title),
                author: row.author,
                acquiredAt: row.date.flatMap(parseDate)
            ))
        }
        return Summary(books: books, skippedNonBooks: skippedNonBooks)
    }

    static func parseDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSX", "yyyy-MM-dd'T'HH:mm:ssX",
                       "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "MM/dd/yyyy"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
