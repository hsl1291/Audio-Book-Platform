import XCTest
@testable import BacklistCore

final class MatchKeyTests: XCTestCase {

    // MARK: - Normalisation

    func testDropsDiacritics() {
        // The library has "Bringing Up Bébé" as a folder; Goodreads spells it with
        // the accents too, but MP4 tags and search input often will not.
        XCTAssertEqual(MatchKey.normalise("Bringing Up Bébé"), MatchKey.normalise("Bringing Up Bebe"))
    }

    func testDropsLeadingArticle() {
        XCTAssertEqual(MatchKey.normalise("The Cult of We"), "cult of we")
        XCTAssertEqual(MatchKey.normalise("A Crack in Creation"), "crack in creation")
        XCTAssertEqual(MatchKey.normalise("An Example"), "example")
    }

    func testArticleInsideTitleSurvives() {
        XCTAssertEqual(MatchKey.normalise("Number Go Up the Sequel"), "number go up the sequel")
    }

    func testCaseAndPunctuationAreIrrelevant() {
        XCTAssertEqual(
            MatchKey.normalise("Order without Design"),
            MatchKey.normalise("ORDER WITHOUT DESIGN")
        )
        XCTAssertEqual(MatchKey.normalise("The Liar's Ball"), "liar s ball")
    }

    // MARK: - Subtitles

    func testStripsColonSubtitle() {
        XCTAssertEqual(
            MatchKey.stripSubtitle(
                "The Liar's Ball: The Extraordinary Saga of How One Building Broke the World's Toughest Tycoons"
            ),
            "The Liar's Ball"
        )
    }

    func testStripsDashSubtitle() {
        XCTAssertEqual(MatchKey.stripSubtitle("Gotham - A History of New York City"), "Gotham")
    }

    func testTitleWithNoSubtitleIsUnchanged() {
        XCTAssertEqual(MatchKey.stripSubtitle("Outliers"), "Outliers")
    }

    func testLeadingColonDoesNotProduceEmptyTitle() {
        XCTAssertEqual(MatchKey.stripSubtitle(": Weird"), ": Weird")
    }

    // MARK: - Author surnames

    func testSurnameFromBothOrderings() {
        // Goodreads exports "Zeke Faux" in one column and "Faux, Zeke" in another.
        XCTAssertEqual(MatchKey.surname("Zeke Faux"), "Faux")
        XCTAssertEqual(MatchKey.surname("Faux, Zeke"), "Faux")
        XCTAssertEqual(MatchKey.surname("Edward O. Thorp"), "Thorp")
        XCTAssertEqual(MatchKey.surname("Thorp, Edward O."), "Thorp")
    }

    func testSurnameOfEmptyOrBlankIsNil() {
        XCTAssertNil(MatchKey.surname(""))
        XCTAssertNil(MatchKey.surname("   "))
    }

    // MARK: - Confidence

    func testTruncatedFolderMatchesFullGoodreadsTitle() {
        // The single most important case: Drive truncates, Goodreads does not.
        let folder = MatchKey(title: "The Liar's Ball", author: "Vicky Ward")
        let goodreads = MatchKey(
            title: "The Liar's Ball: The Extraordinary Saga of How One Building Broke the World's Toughest Tycoons",
            author: "Ward, Vicky"
        )
        XCTAssertGreaterThanOrEqual(folder.confidence(against: goodreads), .strong)
    }

    func testIdenticalTitleAndAuthorIsExact() {
        let a = MatchKey(title: "Outliers", author: "Malcolm Gladwell")
        let b = MatchKey(title: "outliers", author: "Gladwell, Malcolm")
        XCTAssertEqual(a.confidence(against: b), .exact)
    }

    func testSameTitleDifferentAuthorDoesNotMatch() {
        let a = MatchKey(title: "Principles", author: "Ray Dalio")
        let b = MatchKey(title: "Principles", author: "Someone Else")
        XCTAssertEqual(a.confidence(against: b), .none)
    }

    func testSameTitleUnknownAuthorIsOnlyWeak() {
        // Enough to offer as a suggestion, not enough to merge silently.
        let a = MatchKey(title: "Principles", author: nil)
        let b = MatchKey(title: "Principles", author: "Ray Dalio")
        XCTAssertEqual(a.confidence(against: b), .weak)
    }

    func testUnrelatedBooksDoNotMatch() {
        let a = MatchKey(title: "Outliers", author: "Malcolm Gladwell")
        let b = MatchKey(title: "Spare", author: "Prince Harry")
        XCTAssertEqual(a.confidence(against: b), .none)
    }

    func testConfidenceIsOrdered() {
        XCTAssertLessThan(MatchKey.Confidence.none, .weak)
        XCTAssertLessThan(MatchKey.Confidence.weak, .strong)
        XCTAssertLessThan(MatchKey.Confidence.strong, .exact)
    }
}
