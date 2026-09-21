import XCTest
@testable import BacklistCore

/// Fixtures here are real names taken from the live Drive library, not invented
/// ones. If the parser regresses, it regresses against the actual corpus.
final class FolderNameParserTests: XCTestCase {

    // MARK: - ASIN

    func testParsesASINFolder() {
        let parsed = FolderNameParser.parse("21st Century Monetary Policy [B09WRTNSPV]")
        XCTAssertEqual(parsed.title, "21st Century Monetary Policy")
        XCTAssertEqual(parsed.catalogID, .asin("B09WRTNSPV"))
    }

    func testParsesASINFileWithExtension() {
        let parsed = FolderNameParser.parse(
            "21st Century Monetary Policy_ The Federal Reserve from the Great Inflation to COVID-19 [B09WRTNSPV].m4b"
        )
        XCTAssertEqual(parsed.catalogID, .asin("B09WRTNSPV"))
        // The sanitised colon must come back, or subtitle stripping cannot work.
        XCTAssertEqual(
            parsed.title,
            "21st Century Monetary Policy: The Federal Reserve from the Great Inflation to COVID-19"
        )
    }

    // MARK: - ISBN-10

    func testParsesISBN10Folder() {
        let parsed = FolderNameParser.parse("The Liar's Ball [1690587881]")
        XCTAssertEqual(parsed.title, "The Liar's Ball")
        XCTAssertEqual(parsed.catalogID, .isbn10("1690587881"))
    }

    func testParsesISBN10WithCheckDigitX() {
        // Two real examples end in X; a naive all-digits check would drop both.
        XCTAssertEqual(
            FolderNameParser.parse("The Key Man [006299624X]").catalogID,
            .isbn10("006299624X")
        )
        XCTAssertEqual(
            FolderNameParser.parse("Entangled Life [059320980X]").catalogID,
            .isbn10("059320980X")
        )
    }

    func testEveryRealISBN10InTheLibraryValidates() {
        let real = [
            "1690587881", "0593148193", "006299624X", "1549182803", "0062876902",
            "0063138700", "0593290747", "0593340167", "1797122525", "1683644506",
            "0593413105", "1797115782", "1508296057", "1797130978", "1473578132",
            "0593107098", "0593215753", "1797119265", "0062997483", "1984838873",
            "1666111724", "0593416910", "1797103164", "0593290321", "1684579295",
            "059320980X", "154917486X", "1952125081", "1684415632", "0593399978",
        ]
        for isbn in real {
            XCTAssertTrue(
                FolderNameParser.isValidISBN10(isbn),
                "\(isbn) is a real library id and must validate"
            )
        }
    }

    func testRejectsBadChecksum() {
        // Same digits as a real id with one transposed.
        XCTAssertFalse(FolderNameParser.isValidISBN10("1690587882"))
        XCTAssertFalse(FolderNameParser.isValidISBN10("ABCDEFGHIJ"))
        XCTAssertFalse(FolderNameParser.isValidISBN10("12345"))
    }

    func testASINAndISBNCannotCollide() {
        // ASINs always start with B, which is not a digit, so no ISBN-10 can be
        // mistaken for one and vice versa.
        XCTAssertTrue(FolderNameParser.isASIN("B09WRTNSPV"))
        XCTAssertFalse(FolderNameParser.isValidISBN10("B09WRTNSPV"))
        XCTAssertFalse(FolderNameParser.isASIN("1690587881"))
    }

    // MARK: - Names that do not follow the convention

    func testNonConformingNameYieldsNoIDButKeepsTitle() {
        // What a Libro.fm or Downpour download might look like.
        let parsed = FolderNameParser.parse("Some Book Title - Jane Author.m4b")
        XCTAssertNil(parsed.catalogID)
        XCTAssertEqual(parsed.title, "Some Book Title - Jane Author")
    }

    func testUnrecognisedBracketIsTreatedAsPartOfTheTitle() {
        // Truncating here would silently lose "[Unabridged]" from the title.
        let parsed = FolderNameParser.parse("Some Book [Unabridged]")
        XCTAssertNil(parsed.catalogID)
        XCTAssertEqual(parsed.title, "Some Book [Unabridged]")
    }

    func testEmptyBracketIsHarmless() {
        let parsed = FolderNameParser.parse("Some Book []")
        XCTAssertNil(parsed.catalogID)
        XCTAssertEqual(parsed.title, "Some Book []")
    }

    func testUnderscoreInsideWordIsNotConvertedToColon() {
        XCTAssertEqual(FolderNameParser.restorePunctuation("snake_case_title"), "snake_case_title")
        XCTAssertEqual(FolderNameParser.restorePunctuation("Title_ Subtitle"), "Title: Subtitle")
    }
}
