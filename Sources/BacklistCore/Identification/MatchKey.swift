import Foundation

/// A normalised title/author pair used to decide whether two records describe the
/// same book.
///
/// This exists because the same book arrives spelled three different ways:
///
/// | Source | "The Liar's Ball" |
/// |---|---|
/// | Goodreads CSV | `The Liar's Ball: The Extraordinary Saga of How One Building Broke the World's Toughest Tycoons` |
/// | Drive folder | `The Liar's Ball [1690587881]` |
/// | Embedded MP4 tag | `The Liar's Ball` |
///
/// and because diacritics survive in some sources and not others (`Bringing Up
/// Bébé` vs `Bringing Up Bebe`). Exact string equality is useless here.
public struct MatchKey: Hashable, Sendable {
    /// Normalised full title, subtitle included.
    public let full: String
    /// Normalised title with any `:` subtitle removed. Drive folder names are
    /// routinely truncated at the colon, so this is what usually matches.
    public let stem: String
    /// Normalised surname of the first author, or nil.
    public let authorSurname: String?

    public init(title: String, author: String?) {
        let normalisedTitle = MatchKey.normalise(title)
        self.full = normalisedTitle
        self.stem = MatchKey.normalise(MatchKey.stripSubtitle(title))
        self.authorSurname = author.flatMap(MatchKey.surname).map(MatchKey.normalise)
    }

    // MARK: - Normalisation

    /// Lowercase, strip diacritics, drop a leading article, remove punctuation,
    /// collapse whitespace. Order matters: the article is dropped *after* casing so
    /// "The" and "the" behave the same, and *before* punctuation removal so
    /// "The, Thing" does not become "thething".
    public static func normalise(_ raw: String) -> String {
        var s = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        for article in ["the ", "a ", "an "] where s.hasPrefix(article) {
            s = String(s.dropFirst(article.count))
            break
        }

        let kept = s.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) { return Character(scalar) }
            return " "
        }
        return String(kept)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Everything before the first `:` or ` - `, which is where subtitles start.
    /// Returns the input unchanged when there is no subtitle, and never returns
    /// empty — a title that *starts* with a colon keeps its full form.
    public static func stripSubtitle(_ raw: String) -> String {
        for separator in [":", " - ", " \u{2014} "] {
            if let range = raw.range(of: separator) {
                let head = String(raw[raw.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !head.isEmpty { return head }
            }
        }
        return raw
    }

    /// Last name from either `"Zeke Faux"` or `"Faux, Zeke"`. Goodreads exports
    /// both orders in different columns, so both must work.
    public static func surname(_ author: String) -> String? {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let comma = trimmed.firstIndex(of: ",") {
            let head = String(trimmed[trimmed.startIndex..<comma])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return head.isEmpty ? nil : head
        }
        return trimmed.split(separator: " ").last.map(String.init)
    }

    // MARK: - Comparison

    /// How confident we are that two keys describe the same book.
    public enum Confidence: Int, Comparable, Sendable {
        case none = 0
        /// Titles relate but the author disagrees or is missing on one side.
        case weak = 1
        /// One title is a prefix of the other and authors agree — the usual shape
        /// of a truncated Drive folder matching a full Goodreads title.
        case strong = 2
        /// Normalised titles are identical and authors agree.
        case exact = 3

        public static func < (a: Confidence, b: Confidence) -> Bool {
            a.rawValue < b.rawValue
        }
    }

    public func confidence(against other: MatchKey) -> Confidence {
        let authorsAgree: Bool = {
            guard let a = authorSurname, let b = other.authorSurname else { return false }
            return a == b
        }()
        let authorsConflict: Bool = {
            guard let a = authorSurname, let b = other.authorSurname else { return false }
            return a != b
        }()

        let titlesIdentical = full == other.full || stem == other.stem
        let titlesPrefixed =
            full.hasPrefix(other.stem) || other.full.hasPrefix(stem)
            || stem.hasPrefix(other.stem) || other.stem.hasPrefix(stem)

        if titlesIdentical && authorsAgree { return .exact }
        if titlesPrefixed && authorsAgree { return .strong }
        // A bare title match with no corroborating author is not nothing, but it is
        // not enough to merge on silently either.
        if titlesIdentical && !authorsConflict { return .weak }
        return .none
    }
}
