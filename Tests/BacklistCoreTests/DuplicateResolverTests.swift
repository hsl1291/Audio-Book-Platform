import XCTest
@testable import BacklistCore

final class DuplicateResolverTests: XCTestCase {

    // MARK: - Helpers

    private func item(
        _ fileID: String,
        folder: String,
        path: [String],
        bytes: Int64 = 400_000_000
    ) -> DiscoveredItem {
        DiscoveredItem(
            sourceRef: .googleDrive(fileID: fileID),
            fileName: "\(folder).m4b",
            folderName: folder,
            pathComponents: path,
            byteCount: bytes
        )
    }

    /// The exact shape of all 96 duplicates in the live library: one copy filed
    /// under a shelf, one left behind in the download tool's dump folder.
    private func realWorldPair(
        _ folder: String,
        shelf: String
    ) -> (filed: DiscoveredItem, dumped: DiscoveredItem) {
        (
            filed: item("filed-\(folder)", folder: folder, path: ["Books", shelf]),
            dumped: item(
                "dumped-\(folder)",
                folder: folder,
                path: ["Books", "_Read", "Books (Last Download)"]
            )
        )
    }

    // MARK: - Grouping

    func testCollapsesDuplicateASINAcrossFolders() {
        let (filed, dumped) = realWorldPair("21st Century Monetary Policy [B09WRTNSPV]", shelf: "_Read")
        let result = DuplicateResolver.resolve([dumped, filed])

        XCTAssertEqual(result.distinctBooks, 1)
        XCTAssertEqual(result.redundantCount, 1)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].basis, .catalogID(.asin("B09WRTNSPV")))
    }

    func testFiledCopyBeatsDumpFolderCopy() {
        // This is the decision that preserves shelf information. If the dump-folder
        // copy won, every deduped book would lose its read/to-read state.
        let (filed, dumped) = realWorldPair("The House of Morgan [B00H9JEIDA]", shelf: "_Too Read")
        let result = DuplicateResolver.resolve([dumped, filed])

        XCTAssertEqual(result.groups.first?.canonical.id, filed.id)
        XCTAssertEqual(result.groups.first?.redundant.first?.id, dumped.id)
    }

    func testFiledCopyWinsEvenWhenSmaller() {
        // Shelf intent is worth more than a few megabytes.
        let filed = item("filed", folder: "Outliers [B002UZDRK8]", path: ["Books", "_Read"], bytes: 300_000_000)
        let dumped = item(
            "dumped", folder: "Outliers [B002UZDRK8]",
            path: ["Books", "_Read", "Books (Last Download)"], bytes: 900_000_000
        )
        let result = DuplicateResolver.resolve([dumped, filed])
        XCTAssertEqual(result.groups.first?.canonical.id, filed.id)
    }

    func testLargerFileWinsWhenNeitherIsFiled() {
        let small = item("small", folder: "Book [B002UZDRK8]", path: ["Books"], bytes: 100)
        let large = item("large", folder: "Book [B002UZDRK8]", path: ["Books"], bytes: 900)
        let result = DuplicateResolver.resolve([small, large])
        XCTAssertEqual(result.groups.first?.canonical.id, large.id)
    }

    // MARK: - Reclaimable space

    func testReportsReclaimableBytes() {
        let (filed, dumped) = realWorldPair("Spare [B0BJ4X9D2F]", shelf: "_Read")
        let result = DuplicateResolver.resolve([filed, dumped])
        XCTAssertEqual(result.reclaimableBytes, dumped.byteCount)
    }

    func testAggregateMatchesTheLiveLibraryShape() {
        // 3 books, each duplicated once, plus 2 that exist only in the dump folder
        // (in the live library those are Scandalized and The Seven Husbands of
        // Evelyn Hugo — deleting the dump folder wholesale would lose them).
        var items: [DiscoveredItem] = []
        for asin in ["B09WRTNSPV", "B00H9JEIDA", "B0BJ4X9D2F"] {
            let (filed, dumped) = realWorldPair("Book \(asin) [\(asin)]", shelf: "_Read")
            items.append(filed)
            items.append(dumped)
        }
        items.append(
            item("only-1", folder: "Scandalized [B09V3G52H4]",
                 path: ["Books", "_Read", "Books (Last Download)"])
        )
        items.append(
            item("only-2", folder: "The Seven Husbands of Evelyn Hugo [B072359S7K]",
                 path: ["Books", "_Read", "Books (Last Download)"])
        )

        let result = DuplicateResolver.resolve(items)
        XCTAssertEqual(result.totalItems, 8)
        XCTAssertEqual(result.distinctBooks, 5)
        XCTAssertEqual(result.redundantCount, 3)
        XCTAssertEqual(result.unique.count, 2, "dump-folder-only titles must survive as unique")
    }

    // MARK: - Files with no catalogue id

    func testFilesWithoutIDsStillGroupOnTitle() {
        // What arrives from a store that does not use the Title [ID] convention.
        let a = item("a", folder: "Some Book Title", path: ["Books", "_Inbox"])
        let b = item("b", folder: "Some Book Title", path: ["Books", "_Read"])
        let result = DuplicateResolver.resolve([a, b])
        XCTAssertEqual(result.distinctBooks, 1)
        if case .titleAndAuthor = result.groups.first?.basis {} else {
            XCTFail("expected a title-based grouping")
        }
    }

    func testTitleOnlyGroupingIsNotAutoMergeable() {
        // Without an author to corroborate, this needs a human to confirm.
        let a = item("a", folder: "Principles", path: ["Books", "_Inbox"])
        let b = item("b", folder: "Principles", path: ["Books", "_Read"])
        let result = DuplicateResolver.resolve([a, b])
        XCTAssertFalse(result.groups.first?.isSafeToAutoMerge ?? true)
    }

    func testCatalogIDGroupingIsAutoMergeable() {
        let (filed, dumped) = realWorldPair("Outliers [B002UZDRK8]", shelf: "_Read")
        let result = DuplicateResolver.resolve([filed, dumped])
        XCTAssertTrue(result.groups.first?.isSafeToAutoMerge ?? false)
    }

    func testDifferentBooksAreNotMerged() {
        let a = item("a", folder: "Outliers [B002UZDRK8]", path: ["Books", "_Read"])
        let b = item("b", folder: "Spare [B0BJ4X9D2F]", path: ["Books", "_Read"])
        let result = DuplicateResolver.resolve([a, b])
        XCTAssertEqual(result.distinctBooks, 2)
        XCTAssertEqual(result.redundantCount, 0)
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testEmptyInput() {
        let result = DuplicateResolver.resolve([])
        XCTAssertEqual(result.totalItems, 0)
        XCTAssertEqual(result.distinctBooks, 0)
        XCTAssertEqual(result.reclaimableBytes, 0)
    }

    // MARK: - Shelf inference

    func testShelfHintFromUserFiledFolders() {
        XCTAssertEqual(ShelfHint.classify("_Read"), .finished)
        XCTAssertEqual(ShelfHint.classify("_Too Read"), .owned)
        XCTAssertEqual(ShelfHint.classify("to read"), .owned)
        XCTAssertNil(ShelfHint.classify("Images"))
    }

    func testDumpFolderImpliesNoShelfEvenWhenNestedInsideAShelf() {
        // The bug in the current tree: the download folder lives at
        // Books/_Read/Books (Last Download)/, so a naive walk up the path reports
        // every brand-new download as already finished. It must report nothing.
        let dumped = item(
            "d", folder: "New Book [B0GBY3NQCY]",
            path: ["Books", "_Read", "Books (Last Download)"]
        )
        XCTAssertTrue(dumped.isInDumpFolder)
        XCTAssertNil(dumped.shelfHint, "a fresh download must not inherit _Read")
    }

    func testDeliberatelyFiledItemDoesReportItsShelf() {
        let filed = item("f", folder: "Outliers [B002UZDRK8]", path: ["Books", "_Read"])
        XCTAssertFalse(filed.isInDumpFolder)
        XCTAssertEqual(filed.shelfHint, .finished)
    }
}
