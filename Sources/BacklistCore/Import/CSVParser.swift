import Foundation

/// A minimal RFC 4180 CSV reader.
///
/// Written rather than hand-rolled with `split(separator:)` because Goodreads review
/// text routinely contains commas, doubled quotes, and hard line breaks *inside* a
/// quoted field. Splitting on commas corrupts exactly the data most worth keeping.
public enum CSVParser {

    public enum Failure: Error, CustomStringConvertible {
        case unterminatedQuote(row: Int)
        case noHeader

        public var description: String {
            switch self {
            case .unterminatedQuote(let row):
                return "CSV ends inside a quoted field that opened on row \(row)"
            case .noHeader:
                return "CSV contains no header row"
            }
        }
    }

    /// Parse into rows of fields. Does not interpret the header.
    public static func rows(from text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var quoteOpenedAtRow = 0
        var fieldWasQuoted = false

        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextCharacter() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        func endField() {
            // An unquoted field gets trimmed; a quoted one is preserved verbatim,
            // because leading space inside quotes was deliberate.
            row.append(fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            fieldWasQuoted = false
        }

        func endRow() {
            endField()
            // Skip rows that are entirely empty — trailing newlines are normal.
            if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }
            row = []
        }

        while let char = nextCharacter() {
            if inQuotes {
                if char == "\"" {
                    if let peek = nextCharacter() {
                        if peek == "\"" {
                            field.append("\"")   // "" is an escaped quote
                        } else {
                            inQuotes = false
                            pending = peek
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(char)
                }
                continue
            }

            switch char {
            case "\"":
                inQuotes = true
                fieldWasQuoted = true
                quoteOpenedAtRow = rows.count
            case ",":
                endField()
            case "\r\n", "\n", "\r":
                // Swift iterates by grapheme cluster and CRLF is a *single*
                // Character, not a CR followed by an LF. Matching only "\r" and
                // "\n" therefore never fires on a Windows-authored file: the
                // terminator falls through to `default` and is appended into the
                // field, collapsing the whole document into one row.
                endRow()
            default:
                field.append(char)
            }
        }

        if inQuotes { throw Failure.unterminatedQuote(row: quoteOpenedAtRow) }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Parse into dictionaries keyed by the header row.
    ///
    /// Short rows are padded rather than rejected: a truncated trailing column is
    /// common in real exports and is not worth failing an entire 130-book import over.
    public static func dictionaries(from text: String) throws -> [[String: String]] {
        let rows = try rows(from: text)
        guard let header = rows.first else { throw Failure.noHeader }

        return rows.dropFirst().map { row in
            var dict: [String: String] = [:]
            for (index, key) in header.enumerated() {
                dict[key] = index < row.count ? row[index] : ""
            }
            return dict
        }
    }
}
