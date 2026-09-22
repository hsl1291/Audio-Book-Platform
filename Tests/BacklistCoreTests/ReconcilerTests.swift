import XCTest
@testable import BacklistCore

final class ISBNConversionTests: XCTestCase {

    func testWorkedExampleFromTheStandard() {
        // The textbook conversion example, independent of this library's data.
        XCTAssertEqual(FolderNameParser.isbn13(fromISBN10: "0306406152"), "9780306406157")
    }

    func testRealLibraryIDsIncludingCheckDigitX() {
        XCTAssertEqual(FolderNameParser.isbn13(fromISBN10: "0593148193"), "9780593148198")
        XCTAssertEqual(FolderNameParser.isbn13(fromISBN10: "1690587881"), "9781690587880")
        XCTAssertEqual(FolderNameParser.isbn13(fromISBN10: "006299624X"), "9780062996244")
        XCTAssertEqual(FolderNameParser.isbn13(fromISBN10: "059320980X"), "9780593209806")
    }

    func testInvalidInputYieldsNil() {
        XCTAssertNil(FolderNameParser.isbn13(fromISBN10: "1690587882"))  // bad checksum
        XCTAssertNil(FolderNameParser.isbn13(fromISBN10: "B09WRTNSPV"))  // an ASIN
    }
}

final class ReconcilerTests: XCTestCase {

    private func candidate(
        _ title: String, _ author: String?, isbn13: String? = nil
    ) -> Reconciler.Candidate {
        Reconciler.Candidate(id: UUID(), key: MatchKey(title: title, author: author), isbn13: isbn13)
    }

    func testISBNMatchIsDecisive() {
        let file = candidate("Totally Different Folder Name", "Someone", isbn13: "9780593148198")
        let tracked = candidate("The Man Who Solved the Market", "Gregory Zuckerman",
                                isbn13: "9780593148198")
        let pairs = Reconciler.pairs(fileBacked: [file], trackedOnly: [tracked])
        XCTAssertEqual(pairs, [Reconciler.Pair(fileBacked: file.id, tracked: tracked.id)])
    }

    func testTruncatedFolderTitleMatchesFullGoodreadsTitle() {
        // The shape of most of the library: folder truncated at the colon, author
        // recovered from the file's own tags, Goodreads carrying the full title.
        let file = candidate("The Liar's Ball", "Vicky Ward")
        let tracked = candidate(
            "The Liar's Ball: The Extraordinary Saga of How One Building Broke the World's Toughest Tycoons",
            "Ward, Vicky"
        )
        XCTAssertEqual(Reconciler.pairs(fileBacked: [file], trackedOnly: [tracked]).count, 1)
    }

    func testTitleAloneNeverMerges() {
        let file = candidate("Principles", nil)
        let tracked = candidate("Principles", "Ray Dalio")
        XCTAssertTrue(Reconciler.pairs(fileBacked: [file], trackedOnly: [tracked]).isEmpty)
    }

    func testSameTitleDifferentAuthorNeverMerges() {
        let file = candidate("Principles", "Someone Else")
        let tracked = candidate("Principles", "Ray Dalio")
        XCTAssertTrue(Reconciler.pairs(fileBacked: [file], trackedOnly: [tracked]).isEmpty)
    }

    func testAmbiguousTieIsSkippedNotGuessed() {
        let file = candidate("Gotham", "Edwin G. Burrows")
        let a = candidate("Gotham", "Edwin G. Burrows")
        let b = candidate("Gotham", "Burrows, Edwin G.")
        XCTAssertTrue(Reconciler.pairs(fileBacked: [file], trackedOnly: [a, b]).isEmpty)
    }

    func testEachTrackedWorkIsClaimedOnce() {
        let fileA = candidate("Outliers", "Malcolm Gladwell")
        let fileB = candidate("Outliers", "Malcolm Gladwell")
        let tracked = candidate("Outliers", "Gladwell, Malcolm")
        let pairs = Reconciler.pairs(fileBacked: [fileA, fileB], trackedOnly: [tracked])
        XCTAssertEqual(pairs.count, 1)
    }

    func testISBNClaimsBeforeFuzzyMatching() {
        // A fuzzy match processed first must not steal the record an exact ISBN
        // match needs.
        let fuzzy = candidate("Outliers", "Malcolm Gladwell")
        let exact = candidate("Folder Name", "Anyone", isbn13: "9780316017923")
        let tracked = candidate("Outliers", "Gladwell, Malcolm", isbn13: "9780316017923")
        let pairs = Reconciler.pairs(fileBacked: [fuzzy, exact], trackedOnly: [tracked])
        XCTAssertEqual(pairs, [Reconciler.Pair(fileBacked: exact.id, tracked: tracked.id)])
    }

    func testNothingToReconcile() {
        XCTAssertTrue(Reconciler.pairs(fileBacked: [], trackedOnly: []).isEmpty)
    }
}
