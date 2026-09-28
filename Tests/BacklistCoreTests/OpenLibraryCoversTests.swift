import XCTest
@testable import BacklistCore

final class OpenLibraryCoversTests: XCTestCase {

    private func json(_ docs: String) -> Data {
        #"{"numFound":3,"docs":[\#(docs)]}"#.data(using: .utf8)!
    }

    // MARK: - URLs

    func testISBNSearchAsksOnlyForTheFieldsItUses() {
        let url = OpenLibraryCovers.searchURL(isbn13: "9780316017930").absoluteString
        XCTAssertTrue(url.hasPrefix("https://openlibrary.org/search.json?"))
        XCTAssertTrue(url.contains("isbn=9780316017930"))
        XCTAssertTrue(url.contains("fields=title,author_name,cover_i"))
    }

    func testTitleSearchDropsTheSubtitle() {
        // Subtitles differ between editions; searching on them misses the book.
        let url = OpenLibraryCovers.searchURL(
            title: "Outliers: The Story of Success", author: "Malcolm Gladwell"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "Outliers")
        XCTAssertEqual(items.first { $0.name == "author" }?.value, "Malcolm Gladwell")
    }

    func testTitleSearchWithoutAuthorOmitsTheParameter() {
        let url = OpenLibraryCovers.searchURL(title: "Spare", author: nil)
        XCTAssertFalse(url.absoluteString.contains("author="))
    }

    func testCoverURLUsesTheUnlimitedIDEndpoint() {
        XCTAssertEqual(
            OpenLibraryCovers.coverURL(coverID: 8231856).absoluteString,
            "https://covers.openlibrary.org/b/id/8231856-L.jpg"
        )
    }

    // MARK: - Choosing a result

    func testISBNSearchTakesTheFirstResultWithACover() {
        let data = json(#"""
            {"title":"Outliers","author_name":["Malcolm Gladwell"]},
            {"title":"Outliers","author_name":["Malcolm Gladwell"],"cover_i":111}
            """#)
        XCTAssertEqual(OpenLibraryCovers.firstCoverID(in: data), 111)
    }

    func testTitleSearchRejectsAStudyGuideByAnotherAuthor() {
        let data = json(#"""
            {"title":"Outliers: Summary and Analysis","author_name":["BookRags"],"cover_i":1},
            {"title":"Outliers","author_name":["Malcolm Gladwell"],"cover_i":2}
            """#)
        let key = MatchKey(title: "Outliers: The Story of Success", author: "Malcolm Gladwell")
        XCTAssertEqual(OpenLibraryCovers.bestCoverID(in: data, for: key), 2)
    }

    func testTitleSearchPrefersAnExactMatchOverAPrefixMatch() {
        let data = json(#"""
            {"title":"Spare Parts","author_name":["Prince Harry"],"cover_i":1},
            {"title":"Spare","author_name":["Prince Harry"],"cover_i":2}
            """#)
        let key = MatchKey(title: "Spare", author: "Prince Harry")
        XCTAssertEqual(OpenLibraryCovers.bestCoverID(in: data, for: key), 2)
    }

    func testNoConfidentMatchMeansNoCover() {
        // A wrong cover is worse than the placeholder.
        let data = json(#"{"title":"Outliers","author_name":["Someone Else"],"cover_i":1}"#)
        let key = MatchKey(title: "Outliers", author: "Malcolm Gladwell")
        XCTAssertNil(OpenLibraryCovers.bestCoverID(in: data, for: key))
    }

    func testMalformedResponseIsNil() {
        let junk = "<html>busy</html>".data(using: .utf8)!
        XCTAssertNil(OpenLibraryCovers.firstCoverID(in: junk))
        XCTAssertNil(OpenLibraryCovers.bestCoverID(
            in: junk, for: MatchKey(title: "x", author: "y")
        ))
    }

    // MARK: - Image sanity

    func testRejectsTheOnePixelPlaceholder() {
        // Open Library's "no cover" GIF is 43 bytes.
        let gif = Data([0x47, 0x49, 0x46, 0x38]) + Data(repeating: 0, count: 39)
        XCTAssertFalse(OpenLibraryCovers.isPlausibleCover(gif))
    }

    func testAcceptsJPEGAndPNG() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0, count: 2_000)
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0, count: 2_000)
        XCTAssertTrue(OpenLibraryCovers.isPlausibleCover(jpeg))
        XCTAssertTrue(OpenLibraryCovers.isPlausibleCover(png))
    }

    func testRejectsAnErrorPage() {
        let html = String(repeating: "<p>Not found</p>", count: 100).data(using: .utf8)!
        XCTAssertFalse(OpenLibraryCovers.isPlausibleCover(html))
    }
}
