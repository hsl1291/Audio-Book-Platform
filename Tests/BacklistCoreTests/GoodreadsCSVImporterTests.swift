import XCTest
@testable import BacklistCore

final class CSVParserTests: XCTestCase {

    func testPlainRows() throws {
        let rows = try CSVParser.rows(from: "a,b,c\n1,2,3\n")
        XCTAssertEqual(rows, [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testQuotedFieldWithComma() throws {
        // The reason this parser exists at all.
        let rows = try CSVParser.rows(from: "Title,Review\nSpare,\"Good, but long\"\n")
        XCTAssertEqual(rows[1], ["Spare", "Good, but long"])
    }

    func testEscapedQuotesInsideField() throws {
        let rows = try CSVParser.rows(from: "Review\n\"He said \"\"hello\"\" loudly\"\n")
        XCTAssertEqual(rows[1], ["He said \"hello\" loudly"])
    }

    func testNewlineInsideQuotedField() throws {
        // Goodreads reviews contain hard line breaks; these must not split the row.
        let rows = try CSVParser.rows(from: "Title,Review\nOutliers,\"Line one\nLine two\"\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[1][1], "Line one\nLine two")
    }

    func testCarriageReturnLineEndings() throws {
        let rows = try CSVParser.rows(from: "a,b\r\n1,2\r\n")
        XCTAssertEqual(rows, [["a", "b"], ["1", "2"]])
    }

    func testEmptyFieldsPreserved() throws {
        let rows = try CSVParser.rows(from: "a,b,c\n1,,3\n")
        XCTAssertEqual(rows[1], ["1", "", "3"])
    }

    func testQuotedFieldPreservesLeadingSpace() throws {
        let rows = try CSVParser.rows(from: "a\n\"  padded\"\n")
        XCTAssertEqual(rows[1], ["  padded"])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try CSVParser.rows(from: "a\n\"never closed\n"))
    }

    func testDictionariesKeyedByHeader() throws {
        let dicts = try CSVParser.dictionaries(from: "Title,Author\nSpare,Prince Harry\n")
        XCTAssertEqual(dicts.count, 1)
        XCTAssertEqual(dicts[0]["Title"], "Spare")
        XCTAssertEqual(dicts[0]["Author"], "Prince Harry")
    }

    func testShortRowIsPaddedNotDropped() throws {
        let dicts = try CSVParser.dictionaries(from: "A,B,C\n1,2\n")
        XCTAssertEqual(dicts[0]["C"], "")
    }
}

final class GoodreadsCSVImporterTests: XCTestCase {

    /// Header matching the real Goodreads export column order.
    private let header = """
        Book Id,Title,Author,Author l-f,Additional Authors,ISBN,ISBN13,My Rating,\
        Average Rating,Publisher,Binding,Number of Pages,Year Published,\
        Original Publication Year,Date Read,Date Added,Bookshelves,\
        Bookshelves with positions,Exclusive Shelf,My Review,Spoiler,Private Notes,\
        Read Count,Owned Copies
        """

    private func csv(_ rows: String...) -> String {
        ([header] + rows).joined(separator: "\n") + "\n"
    }

    // MARK: - The shape of the actual library

    func testUnratedUnreviewedRowIsTheCommonCase() throws {
        // Every one of the 130 rows on the live shelf looks like this: rating 0,
        // no review, no date read. If nil handling were wrong, the whole import
        // would be wrong.
        let text = csv(
            #"12345,Number Go Up,Zeke Faux,"Faux, Zeke",,="",="9780593443811",0,4.24,Currency,Hardcover,288,2023,2023,,2026/06/14,read,read (#1),read,,,,1,0"#
        )
        let summary = try GoodreadsCSVImporter().import(csv: text)

        XCTAssertEqual(summary.books.count, 1)
        let book = summary.books[0]
        XCTAssertEqual(book.work.title, "Number Go Up")
        XCTAssertEqual(book.work.authors, ["Zeke Faux"])
        XCTAssertNil(book.journal.rating, "rating 0 means unrated, not zero stars")
        XCTAssertNil(book.journal.review)
        XCTAssertNil(book.journal.finishedAt, "date read is unset on most rows")
        XCTAssertEqual(book.shelf, .finished)
        XCTAssertEqual(summary.rated, 0)
        XCTAssertEqual(summary.reviewed, 0)
    }

    func testExcelEscapedISBNIsUnwrapped() throws {
        let text = csv(
            #"1,Outliers,Malcolm Gladwell,"Gladwell, Malcolm",,="0316017922",="9780316017923",0,4.19,Back Bay,Paperback,309,2008,2008,,2024/01/01,read,,read,,,,1,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertEqual(book.work.isbn13, "9780316017923", "must not keep =\"\" wrapping")
    }

    func testEmptyExcelEscapedISBNBecomesNil() throws {
        let text = csv(
            #"1,Some Book,An Author,"Author, An",,="",="",0,3.5,Pub,Paperback,100,2020,2020,,2024/01/01,read,,read,,,,1,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertNil(book.work.isbn13)
    }

    // MARK: - Ratings and reviews

    func testRatingAndReviewAreCaptured() throws {
        let text = csv(
            #"1,Spare,Prince Harry,"Harry, Prince",,="",="9780593593806",4,3.89,Random,Hardcover,416,2023,2023,2024/02/09,2024/01/27,read,,read,"Better than expected, actually.",,,1,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertEqual(book.journal.rating, 4)
        XCTAssertEqual(book.journal.review, "Better than expected, actually.")
        XCTAssertTrue(book.journal.hasReview)
    }

    func testReviewHTMLLineBreaksBecomeNewlines() throws {
        let text = csv(
            #"1,Book,Author Name,"Name, Author",,="",="",5,4.0,Pub,Hardcover,100,2020,2020,,2024/01/01,read,,read,"First.<br/>Second.",,,1,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertEqual(book.journal.review, "First.\nSecond.")
    }

    func testRatingOutOfRangeIsIgnored() {
        XCTAssertNil(GoodreadsCSVImporter.rating(from: "0"))
        XCTAssertNil(GoodreadsCSVImporter.rating(from: "6"))
        XCTAssertNil(GoodreadsCSVImporter.rating(from: ""))
        XCTAssertEqual(GoodreadsCSVImporter.rating(from: "3"), 3)
    }

    // MARK: - Shelves and intent

    func testExclusiveShelfMapping() {
        XCTAssertEqual(GoodreadsCSVImporter.shelf(from: "read"), .finished)
        XCTAssertEqual(GoodreadsCSVImporter.shelf(from: "currently-reading"), .reading)
        XCTAssertEqual(GoodreadsCSVImporter.shelf(from: "to-read"), .want)
    }

    func testUnknownShelfIsKeptNotDropped() {
        XCTAssertEqual(GoodreadsCSVImporter.shelf(from: "something-odd"), .want)
        XCTAssertEqual(GoodreadsCSVImporter.shelf(from: nil), .want)
    }

    func testWantedBooksGetPurchaseIntent() throws {
        let text = csv(
            #"1,Americana,Bhu Srinivasan,"Srinivasan, Bhu",,="",="",0,4.1,Pub,Hardcover,100,2017,2017,,2025/07/18,to-read,,to-read,,,,0,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertEqual(book.shelf, .want)
        XCTAssertEqual(book.intent, .needToPurchase)
    }

    func testFinishedBooksHaveNoPurchaseIntent() throws {
        let text = csv(
            #"1,Outliers,Malcolm Gladwell,"Gladwell, Malcolm",,="",="",0,4.19,Pub,Paperback,309,2008,2008,,2024/01/01,read,,read,,,,1,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertEqual(book.intent, .none)
    }

    // MARK: - Dates

    func testGoodreadsDateFormat() {
        let date = GoodreadsCSVImporter.date(from: "2024/03/11")
        XCTAssertNotNil(date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date!)
        XCTAssertEqual(parts.year, 2024)
        XCTAssertEqual(parts.month, 3)
        XCTAssertEqual(parts.day, 11)
    }

    func testMalformedDateIsNilNotCrash() {
        XCTAssertNil(GoodreadsCSVImporter.date(from: "not set"))
        XCTAssertNil(GoodreadsCSVImporter.date(from: ""))
        XCTAssertNil(GoodreadsCSVImporter.date(from: nil))
    }

    // MARK: - Authors and tags

    func testAdditionalAuthorsAreFoldedIn() throws {
        let text = csv(
            #"1,American Prometheus,Kai Bird,"Bird, Kai","Martin J. Sherwin",="",="",0,4.3,Pub,Paperback,721,2005,2005,,2024/01/01,read,,read,,,,1,0"#
        )
        let book = try GoodreadsCSVImporter().import(csv: text).books[0]
        XCTAssertEqual(book.work.authors, ["Kai Bird", "Martin J. Sherwin"])
    }

    func testUserShelvesBecomeTagsWithoutTheExclusiveOnes() {
        let tags = GoodreadsCSVImporter.tags(from: "read, finance, favourites")
        XCTAssertEqual(tags, ["finance", "favourites"])
    }

    // MARK: - Robustness

    func testRowWithNoTitleIsSkippedWithAReason() throws {
        let text = csv(
            #"1,,An Author,"Author, An",,="",="",0,3.0,Pub,Paperback,100,2020,2020,,2024/01/01,read,,read,,,,1,0"#
        )
        let summary = try GoodreadsCSVImporter().import(csv: text)
        XCTAssertTrue(summary.books.isEmpty)
        XCTAssertEqual(summary.skipped.count, 1)
    }

    func testMultipleRowsWithMixedShelves() throws {
        let text = csv(
            #"1,Read Book,A Author,"Author, A",,="",="",5,4.0,Pub,HB,100,2020,2020,2024/02/01,2024/01/01,read,,read,"Liked it.",,,1,0"#,
            #"2,Wanted Book,B Author,"Author, B",,="",="",0,4.0,Pub,HB,100,2020,2020,,2024/01/01,to-read,,to-read,,,,0,0"#,
            #"3,Current Book,C Author,"Author, C",,="",="",0,4.0,Pub,HB,100,2020,2020,,2024/01/01,currently-reading,,currently-reading,,,,0,0"#
        )
        let summary = try GoodreadsCSVImporter().import(csv: text)
        XCTAssertEqual(summary.books.count, 3)
        XCTAssertEqual(summary.finished, 1)
        XCTAssertEqual(summary.wanted, 1)
        XCTAssertEqual(summary.rated, 1)
        XCTAssertEqual(summary.reviewed, 1)
        XCTAssertTrue(summary.skipped.isEmpty)
    }
}
