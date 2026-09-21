import XCTest
@testable import BacklistCore

final class PlayableExtensionTests: XCTestCase {

    func testAcceptsTheFormatsStoresActuallyShip() {
        // The existing library is entirely .m4b, but other stores ship .m4a and
        // .mp3. Refusing those would quietly hide books the user owns.
        for name in ["Book.m4b", "Book.m4a", "Book.mp3", "Book.flac", "Book.opus"] {
            XCTAssertTrue(PlayableExtension.matches(name), "\(name) should be playable")
        }
    }

    func testCaseInsensitive() {
        XCTAssertTrue(PlayableExtension.matches("Book.M4B"))
        XCTAssertTrue(PlayableExtension.matches("Book.Mp3"))
    }

    func testRejectsNonAudio() {
        for name in ["cover.jpg", "notes.txt", "Book", "book.m4b.txt", ".hidden"] {
            XCTAssertFalse(PlayableExtension.matches(name), "\(name) should not be playable")
        }
    }

    func testPrefersSingleFileChapteredContainer() {
        XCTAssertTrue(PlayableExtension.isPreferredContainer("Book.m4b"))
        XCTAssertFalse(PlayableExtension.isPreferredContainer("Book.mp3"))
    }
}

final class GoogleDriveSourceTests: XCTestCase {

    func testDecodesAFileEntry() {
        let raw: [String: Any] = [
            "id": "1kwyCTEG68fn2T18GEKVKP6aNOvHeOH5D",
            "name": "Too Sensitive_ Rejection, Resilience [B0GBY3NQCY].m4b",
            "mimeType": "video/mp4",
            "size": "479462365",
            "modifiedTime": "2026-09-20T19:10:17.903Z",
        ]
        let entry = GoogleDriveSource.decodeEntry(raw)

        XCTAssertEqual(entry?.id, "1kwyCTEG68fn2T18GEKVKP6aNOvHeOH5D")
        XCTAssertEqual(entry?.size, 479_462_365, "size arrives as a string and must parse")
        XCTAssertFalse(entry?.isFolder ?? true)
        XCTAssertNotNil(entry?.modifiedTime, "Drive timestamps carry fractional seconds")
    }

    func testDecodesAFolderEntry() {
        let raw: [String: Any] = [
            "id": "1E19DKWOagEKdDi4u_UAaYOnrFNfH-HBn",
            "name": "_Read",
            "mimeType": "application/vnd.google-apps.folder",
        ]
        let entry = GoogleDriveSource.decodeEntry(raw)
        XCTAssertTrue(entry?.isFolder ?? false)
        XCTAssertNil(entry?.size, "folders report no size")
    }

    func testMissingRequiredFieldsYieldNil() {
        XCTAssertNil(GoogleDriveSource.decodeEntry(["name": "x", "mimeType": "y"]))
        XCTAssertNil(GoogleDriveSource.decodeEntry(["id": "x"]))
    }

    func testAudiobooksAreServedWithAVideoMimeType() {
        // Drive labels .m4b as video/mp4. Filtering on mimeType would therefore
        // discard the entire library; the file extension is what counts.
        let raw: [String: Any] = [
            "id": "a", "name": "Book [B09WRTNSPV].m4b", "mimeType": "video/mp4",
        ]
        let entry = GoogleDriveSource.decodeEntry(raw)
        XCTAssertFalse(entry?.isFolder ?? true)
        XCTAssertTrue(PlayableExtension.matches(entry!.name))
    }

    func testMediaURLRequestsContentNotMetadata() {
        let url = GoogleDriveSource.mediaURL(for: "FILEID").absoluteString
        XCTAssertTrue(url.contains("/files/FILEID"))
        XCTAssertTrue(url.contains("alt=media"), "without alt=media Drive returns JSON")
    }
}

final class HTTPRangeReaderTests: XCTestCase {

    func testParsesTotalFromContentRange() {
        XCTAssertEqual(HTTPRangeReader.totalFromContentRange("bytes 0-0/479462365"), 479_462_365)
        XCTAssertEqual(HTTPRangeReader.totalFromContentRange("bytes 100-200/1000"), 1000)
    }

    func testUnknownTotalIsNil() {
        XCTAssertNil(HTTPRangeReader.totalFromContentRange("bytes 0-0/*"))
        XCTAssertNil(HTTPRangeReader.totalFromContentRange("nonsense"))
    }
}

final class LocalFilesSourceTests: XCTestCase {

    func testRecoversRealNameFromICloudPlaceholder() {
        // A placeholder is named `.Original.m4b.icloud`. Without unwrapping it,
        // nothing matches the playable extensions and the library scans as empty.
        XCTAssertEqual(
            LocalFilesSource.materialisedName(of: URL(fileURLWithPath: "/x/.Outliers.m4b.icloud")),
            "Outliers.m4b"
        )
    }

    func testOrdinaryNameIsUnchanged() {
        XCTAssertEqual(
            LocalFilesSource.materialisedName(of: URL(fileURLWithPath: "/x/Outliers.m4b")),
            "Outliers.m4b"
        )
    }

    func testPlaceholderNameBecomesPlayable() {
        let name = LocalFilesSource.materialisedName(
            of: URL(fileURLWithPath: "/x/.Book [B09WRTNSPV].m4b.icloud")
        )
        XCTAssertTrue(PlayableExtension.matches(name))
        XCTAssertEqual(FolderNameParser.parse(name).catalogID, .asin("B09WRTNSPV"))
    }

    func testRelativePathIsRootedAtTheSource() {
        let source = LocalFilesSource(root: URL(fileURLWithPath: "/Users/h/Books"))
        let path = source.relativePath(
            of: URL(fileURLWithPath: "/Users/h/Books/_Read/Outliers [B002UZDRK8]/Outliers.m4b")
        )
        XCTAssertEqual(path, "_Read/Outliers [B002UZDRK8]/Outliers.m4b")
    }

    func testAbsoluteURLRoundTrips() throws {
        let source = LocalFilesSource(root: URL(fileURLWithPath: "/Users/h/Books"))
        let item = DiscoveredItem(
            sourceRef: .localFile(relativePath: "_Read/Book/Book.m4b"),
            fileName: "Book.m4b"
        )
        XCTAssertEqual(
            try source.absoluteURL(for: item).path,
            "/Users/h/Books/_Read/Book/Book.m4b"
        )
    }

    // MARK: - Round trip against a real directory tree

    func testScansARealDirectoryAndInfersShelves() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("backlist-scan-\(UUID().uuidString)")
        let fm = FileManager.default

        // Mirrors the live library's shape, dump folder nested inside _Read.
        let filed = root.appendingPathComponent("_Read/Outliers [B002UZDRK8]")
        let dumped = root
            .appendingPathComponent("_Read/Books (Last Download)/Spare [B0BJ4X9D2F]")
        try fm.createDirectory(at: filed, withIntermediateDirectories: true)
        try fm.createDirectory(at: dumped, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data(repeating: 0, count: 16)
            .write(to: filed.appendingPathComponent("Outliers [B002UZDRK8].m4b"))
        try Data(repeating: 0, count: 16)
            .write(to: dumped.appendingPathComponent("Spare [B0BJ4X9D2F].m4b"))
        try "not audio".data(using: .utf8)!
            .write(to: filed.appendingPathComponent("cover.jpg"))

        let items = try await LocalFilesSource(root: root).scan()

        XCTAssertEqual(items.count, 2, "the jpg must not be picked up")

        let outliers = try XCTUnwrap(items.first { $0.fileName.contains("Outliers") })
        XCTAssertEqual(outliers.parsedName.catalogID, .asin("B002UZDRK8"))
        XCTAssertEqual(outliers.shelfHint, .finished)
        XCTAssertFalse(outliers.isInDumpFolder)

        let spare = try XCTUnwrap(items.first { $0.fileName.contains("Spare") })
        XCTAssertTrue(spare.isInDumpFolder)
        XCTAssertNil(spare.shelfHint, "a fresh download must not inherit _Read")
    }
}
