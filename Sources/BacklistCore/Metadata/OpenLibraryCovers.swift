import Foundation

/// Cover art for books that have no audio file to read it from.
///
/// About 54 finished books and everything on the Want list have no embedded
/// artwork. Open Library has covers for most published books and needs no key.
///
/// Lookups go through the search API, which returns a cover *ID*, and the image is
/// then fetched by that ID. The shorter-looking `/b/isbn/…` endpoint is rate
/// limited to 100 requests per five minutes, which a first import of a reading
/// history would exceed; fetches by cover ID are not limited.
public enum OpenLibraryCovers {

    public enum Size: String, Sendable {
        case medium = "M", large = "L"
    }

    // MARK: - URLs

    /// Search by ISBN. An ISBN hit is decisive; no title check is needed.
    public static func searchURL(isbn13: String) -> URL {
        search([URLQueryItem(name: "isbn", value: isbn13)])
    }

    /// Search by title and, when known, author.
    public static func searchURL(title: String, author: String?) -> URL {
        var items = [URLQueryItem(name: "title", value: MatchKey.stripSubtitle(title))]
        if let author, !author.isEmpty {
            items.append(URLQueryItem(name: "author", value: author))
        }
        return search(items)
    }

    public static func coverURL(coverID: Int, size: Size = .large) -> URL {
        URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-\(size.rawValue).jpg")!
    }

    private static func search(_ items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = items + [
            URLQueryItem(name: "fields", value: "title,author_name,cover_i"),
            URLQueryItem(name: "limit", value: "10"),
        ]
        return components.url!
    }

    // MARK: - Parsing

    private struct SearchResponse: Decodable {
        struct Doc: Decodable {
            var title: String?
            var author_name: [String]?
            var cover_i: Int?
        }
        var docs: [Doc]
    }

    /// The first result with a cover. Used for ISBN searches, where any hit is
    /// the book.
    public static func firstCoverID(in json: Data) -> Int? {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: json) else {
            return nil
        }
        return response.docs.lazy.compactMap(\.cover_i).first
    }

    /// The best-matching result with a cover, or nil if nothing matches well.
    ///
    /// A title search returns study guides, summaries and same-titled books by
    /// other authors. A wrong cover is worse than the coloured placeholder, so a
    /// result needs `.strong` agreement — title and author — to be used.
    public static func bestCoverID(in json: Data, for key: MatchKey) -> Int? {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: json) else {
            return nil
        }
        var best: (id: Int, confidence: MatchKey.Confidence)?
        for doc in response.docs {
            guard let id = doc.cover_i, let title = doc.title else { continue }
            let candidate = MatchKey(title: title, author: doc.author_name?.first)
            let confidence = candidate.confidence(against: key)
            guard confidence >= .strong else { continue }
            if best == nil || confidence > best!.confidence {
                best = (id, confidence)
            }
        }
        return best?.id
    }

    /// True when the bytes are a real image rather than an error page or the
    /// 1×1 placeholder Open Library serves for missing covers.
    public static func isPlausibleCover(_ data: Data) -> Bool {
        guard data.count >= 1_000 else { return false }
        let jpeg: [UInt8] = [0xFF, 0xD8, 0xFF]
        let png: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
        let head = Array(data.prefix(4))
        return head.starts(with: jpeg) || head.starts(with: png)
    }
}
