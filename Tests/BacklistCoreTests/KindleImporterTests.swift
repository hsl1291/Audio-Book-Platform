import XCTest
@testable import BacklistCore

final class KindleImporterTests: XCTestCase {

    private func data(_ text: String) -> Data { text.data(using: .utf8)! }

    // MARK: - CSV

    func testReadsADigitalItemsCSVWithAmazonHeadings() {
        let csv = """
            ASIN,Product Name,Order Date,Product Category,Contributor
            B00B7NPRY8,Lean In: Women and Work (Kindle Edition),2021-03-04T10:00:00Z,Digital_Ebook_Purchase,Sheryl Sandberg
            B0CHXYZ123,Spare,2023-01-10,Audible Audiobook,Prince Harry
            B01N5AX61W,Some App,2020-01-01,Mobile Apps,Dev Co
            """
        let summary = KindleImporter.import(data(csv))

        XCTAssertEqual(summary.books.count, 1)
        let book = summary.books[0]
        XCTAssertEqual(book.asin, "B00B7NPRY8")
        XCTAssertEqual(book.title, "Lean In: Women and Work", "edition noise is removed")
        XCTAssertEqual(book.author, "Sheryl Sandberg")
        XCTAssertNotNil(book.acquiredAt)
        XCTAssertEqual(summary.skippedNonBooks, 2, "the Audible title and the app are left out")
    }

    func testHeadingsMatchRegardlessOfCaseAndPunctuation() {
        let csv = """
            product_asin,TITLE,author_name
            B07FZ8S74R,Educated,Tara Westover
            """
        let book = KindleImporter.import(data(csv)).books.first
        XCTAssertEqual(book?.title, "Educated")
        XCTAssertEqual(book?.author, "Tara Westover")
    }

    func testWithoutACategoryColumnKeepsEveryKindleASIN() {
        let csv = """
            ASIN,Title
            B07FZ8S74R,Educated
            9780399590504,Educated (hardcover ISBN)
            """
        let summary = KindleImporter.import(data(csv))
        XCTAssertEqual(summary.books.map(\.asin), ["B07FZ8S74R"], "an ISBN is not a Kindle ASIN")
    }

    func testAnUnrelatedFileYieldsNothing() {
        let csv = """
            Device,Timestamp,Event
            Kindle Paperwhite,2021-01-01,Sync
            """
        XCTAssertTrue(KindleImporter.import(data(csv)).books.isEmpty)
        XCTAssertTrue(KindleImporter.import(Data([0xFF, 0xFE, 0x00])).books.isEmpty)
    }

    func testDuplicateASINsCollapse() {
        let csv = """
            ASIN,Title
            B07FZ8S74R,Educated
            b07fz8s74r,Educated
            """
        XCTAssertEqual(KindleImporter.import(data(csv)).books.count, 1)
    }

    // MARK: - JSON

    func testFindsBooksAnywhereInAJSONTree() {
        let json = """
            {"rights": [
              {"resource": {"ASIN": "B07FZ8S74R", "Product Name": "Educated: A Memoir",
                            "resourceType": "KINDLE_EBOOK", "authors": ["Tara Westover"]}},
              {"resource": {"ASIN": "B0CHXYZ123", "Product Name": "Spare",
                            "resourceType": "AUDIBLE_AUDIOBOOK"}}
            ]}
            """
        let summary = KindleImporter.import(data(json))
        XCTAssertEqual(summary.books.map(\.asin), ["B07FZ8S74R"])
        XCTAssertEqual(summary.books.first?.author, "Tara Westover")
        XCTAssertEqual(summary.skippedNonBooks, 1)
    }

    // MARK: - Merging files

    func testMergingFilesKeepsOneEntryPerBook() {
        let a = KindleImporter.import(data("ASIN,Title\nB07FZ8S74R,Educated"))
        let b = KindleImporter.import(data("ASIN,Title\nB07FZ8S74R,Educated\nB00B7NPRY8,Lean In"))
        XCTAssertEqual(KindleImporter.merge([a, b]).books.count, 2)
    }

    // MARK: - Helpers

    func testCleanTitleDropsSeriesNotesButNotLeadingParentheses() {
        XCTAssertEqual(KindleImporter.cleanTitle("Dune (Dune Book 1)"), "Dune")
        XCTAssertEqual(KindleImporter.cleanTitle("Educated Kindle Edition"), "Educated")
        XCTAssertEqual(KindleImporter.cleanTitle("(Un)Stuck"), "(Un)Stuck")
    }

    func testTitleMatchesTheSameBookFromGoodreads() {
        // Kindle and audiobook ASINs differ, so matching across formats relies on
        // title and author alone.
        let kindle = KindleImporter.Book(
            asin: "B07FZ8S74R", title: "Educated", author: "Tara Westover", acquiredAt: nil
        )
        let goodreads = MatchKey(title: "Educated: A Memoir", author: "Westover, Tara")
        XCTAssertGreaterThanOrEqual(kindle.matchKey.confidence(against: goodreads), .strong)
    }
}
