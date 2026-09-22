import Foundation

/// A catalogue identifier recovered from a file or folder name.
public enum CatalogID: Hashable, Sendable {
    case asin(String)
    case isbn10(String)

    public var rawValue: String {
        switch self {
        case .asin(let s), .isbn10(let s): return s
        }
    }
}

/// What a `Title [ID]` name yielded.
public struct ParsedName: Hashable, Sendable {
    /// Title with the bracketed id removed and sanitised punctuation restored.
    public let title: String
    /// Present only when the trailing bracket held something we could verify.
    public let catalogID: CatalogID?

    public init(title: String, catalogID: CatalogID?) {
        self.title = title
        self.catalogID = catalogID
    }
}

/// Parses the `Title [ID]` convention used by the existing Drive library.
///
/// **This is a hint, never a requirement.** 106 of 106 current books follow it
/// because they came from one tool, but files from other stores will not, so every
/// caller must cope with `catalogID == nil` and fall through to embedded tags and
/// fuzzy matching. See `BookIdentifier`.
public enum FolderNameParser {

    /// Parse a folder name (`Title [ID]`) or a file name (`Title [ID].m4b`).
    public static func parse(_ rawName: String) -> ParsedName {
        var name = rawName

        // Drop a media extension if this was a file rather than a folder.
        for ext in [".m4b", ".m4a", ".mp3", ".mp4", ".aac", ".ogg", ".opus", ".flac"]
        where name.lowercased().hasSuffix(ext) {
            name = String(name.dropLast(ext.count))
            break
        }
        name = name.trimmingCharacters(in: .whitespaces)

        guard name.hasSuffix("]"), let open = name.lastIndex(of: "[") else {
            return ParsedName(title: restorePunctuation(name), catalogID: nil)
        }

        let idStart = name.index(after: open)
        let idEnd = name.index(before: name.endIndex)
        guard idStart < idEnd else {
            return ParsedName(title: restorePunctuation(name), catalogID: nil)
        }

        let candidate = String(name[idStart..<idEnd])
        let title = String(name[name.startIndex..<open])
            .trimmingCharacters(in: .whitespaces)

        // An unrecognised bracket is probably part of the title ("[Unabridged]"),
        // so keep the whole string rather than silently truncating it.
        guard let id = classify(candidate) else {
            return ParsedName(title: restorePunctuation(name), catalogID: nil)
        }
        return ParsedName(title: restorePunctuation(title), catalogID: id)
    }

    /// Identify a bracketed token, or return nil if it is not a catalogue id.
    public static func classify(_ token: String) -> CatalogID? {
        if isASIN(token) { return .asin(token) }
        if isValidISBN10(token) { return .isbn10(token.uppercased()) }
        return nil
    }

    /// Amazon/Audible ASINs are `B` followed by nine uppercase alphanumerics.
    /// Because they always start with `B`, they can never collide with an ISBN-10.
    public static func isASIN(_ token: String) -> Bool {
        guard token.count == 10, token.hasPrefix("B") else { return false }
        return token.dropFirst().allSatisfy { $0.isNumber || ($0.isLetter && $0.isUppercase) }
    }

    /// Full ISBN-10 checksum, not a shape check. Verified against all 30 ISBN-10s
    /// in the existing library — every one passes, so strictness costs nothing and
    /// buys a confident ASIN/ISBN/garbage discrimination.
    public static func isValidISBN10(_ token: String) -> Bool {
        guard token.count == 10 else { return false }
        var sum = 0
        for (offset, char) in token.enumerated() {
            let value: Int
            if offset == 9, char == "X" || char == "x" {
                value = 10
            } else if let digit = char.wholeNumberValue, char.isNumber {
                value = digit
            } else {
                return false
            }
            sum += (10 - offset) * value
        }
        return sum % 11 == 0
    }

    /// Convert an ISBN-10 to the ISBN-13 that denotes the same book.
    ///
    /// Goodreads exports ISBN-13 and the folder names carry ISBN-10, so without
    /// this the 30 ISBN-named books in the library could never match their own
    /// reading history. Returns nil for anything that is not a valid ISBN-10.
    public static func isbn13(fromISBN10 isbn10: String) -> String? {
        guard isValidISBN10(isbn10) else { return nil }
        let body = "978" + isbn10.prefix(9)
        var sum = 0
        for (offset, char) in body.enumerated() {
            guard let digit = char.wholeNumberValue else { return nil }
            sum += digit * (offset.isMultiple(of: 2) ? 1 : 3)
        }
        return body + String((10 - sum % 10) % 10)
    }

    /// Restore punctuation that filesystem-safe naming destroyed.
    ///
    /// A colon is illegal in many filesystems, so tools substitute `_`. The library
    /// contains e.g. `Too Sensitive_ Rejection, Resilience, and the Science of
    /// Feeling Deeply`, which is really a title with a subtitle. Recovering the
    /// colon lets `MatchKey.stripSubtitle` do its job.
    ///
    /// Only `_` *followed by a space* is converted, so genuine underscores inside a
    /// word (`snake_case`) are left alone.
    public static func restorePunctuation(_ title: String) -> String {
        title.replacingOccurrences(of: "_ ", with: ": ")
            .trimmingCharacters(in: .whitespaces)
    }
}
