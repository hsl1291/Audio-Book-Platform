import XCTest
@testable import BacklistCore

/// Builds synthetic MP4 byte structures so the parser can be exercised without a
/// real 400 MB audiobook in the repository.
enum MP4Builder {

    /// `size(4) + type(4) + payload`. Types are encoded as ISO Latin-1 so that the
    /// `©` leading several standard tags is one byte, as the format requires —
    /// UTF-8 would emit two and desynchronise every following atom.
    static func atom(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        let size = UInt32(8 + payload.count)
        out.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        out.append(type.data(using: .isoLatin1)!)
        out.append(payload)
        return out
    }

    static func be32(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF),
        ])
    }

    static func be64(_ value: UInt64) -> Data {
        var out = Data()
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((value >> UInt64(shift)) & 0xFF))
        }
        return out
    }

    /// A `data` atom: typeIndicator(4) + locale(4) + payload.
    static func dataAtom(text: String) -> Data {
        atom("data", be32(1) + be32(0) + text.data(using: .utf8)!)
    }

    static func dataAtom(imageIndicator: UInt32, bytes: Data) -> Data {
        atom("data", be32(imageIndicator) + be32(0) + bytes)
    }

    static func textTag(_ type: String, _ value: String) -> Data {
        atom(type, dataAtom(text: value))
    }

    /// Freeform tag: `mean` + `name` + `data`.
    static func freeform(name: String, value: String) -> Data {
        let mean = atom("mean", be32(0) + "com.apple.iTunes".data(using: .utf8)!)
        let nameAtom = atom("name", be32(0) + name.data(using: .utf8)!)
        return atom("----", mean + nameAtom + dataAtom(text: value))
    }

    static func mvhd(version: UInt8, timescale: UInt32, duration: UInt64) -> Data {
        var payload = Data([version, 0, 0, 0])
        if version == 1 {
            payload += be64(0) + be64(0) + be32(timescale) + be64(duration)
        } else {
            payload += be32(0) + be32(0) + be32(timescale) + be32(UInt32(clamping: duration))
        }
        payload += Data(repeating: 0, count: 80)   // the rest of mvhd, unread
        return atom("mvhd", payload)
    }

    /// `meta` carries four bytes of version/flags before its children.
    static func meta(ilst: Data) -> Data {
        atom("meta", be32(0) + atom("ilst", ilst))
    }

    static func moov(mvhdAtom: Data = Data(), ilst: Data) -> Data {
        atom("moov", mvhdAtom + atom("udta", meta(ilst: ilst)))
    }

    static func ftyp() -> Data {
        atom("ftyp", "M4B isom".data(using: .isoLatin1)!)
    }

    static func mdat(byteCount: Int) -> Data {
        atom("mdat", Data(repeating: 0xAB, count: byteCount))
    }
}

final class MP4AtomReaderTests: XCTestCase {

    private func read(_ file: Data) async throws -> AudioMetadata {
        try await MP4AtomReader().metadata(from: DataRangeReader(file))
    }

    private var sampleTags: Data {
        MP4Builder.textTag("\u{00A9}nam", "21st Century Monetary Policy")
            + MP4Builder.textTag("\u{00A9}ART", "Ben S. Bernanke")
            + MP4Builder.textTag("\u{00A9}alb", "21st Century Monetary Policy")
    }

    // MARK: - Layout independence

    func testReadsFaststartLayout() async throws {
        // moov before mdat
        let file = MP4Builder.ftyp()
            + MP4Builder.moov(ilst: sampleTags)
            + MP4Builder.mdat(byteCount: 4096)

        let meta = try await read(file)
        XCTAssertEqual(meta.title, "21st Century Monetary Policy")
        XCTAssertEqual(meta.author, "Ben S. Bernanke")
    }

    func testReadsMoovLastLayout() async throws {
        // mdat before moov — the case a fixed head-of-file window would miss.
        let file = MP4Builder.ftyp()
            + MP4Builder.mdat(byteCount: 4096)
            + MP4Builder.moov(ilst: sampleTags)

        let meta = try await read(file)
        XCTAssertEqual(meta.title, "21st Century Monetary Policy")
        XCTAssertEqual(meta.author, "Ben S. Bernanke")
    }

    func testWalkSkipsLargeMdatWithoutReadingIt() async throws {
        // Proves the walk seeks past payload rather than scanning it.
        let file = MP4Builder.ftyp()
            + MP4Builder.mdat(byteCount: 2_000_000)
            + MP4Builder.moov(ilst: sampleTags)

        let counting = CountingReader(DataRangeReader(file))
        let meta = try await MP4AtomReader().metadata(from: counting)

        XCTAssertEqual(meta.title, "21st Century Monetary Policy")
        let read = await counting.bytesRead
        XCTAssertLessThan(read, 100_000, "must not transfer the mdat payload")
    }

    // MARK: - The meta version/flags trap

    func testMetaVersionFlagsAreSkipped() async throws {
        // If the four bytes were not skipped, ilst would never be found and every
        // tag would silently vanish.
        let file = MP4Builder.ftyp() + MP4Builder.moov(ilst: sampleTags)
        let meta = try await read(file)
        XCTAssertNotNil(meta.title)
    }

    func testMetaDirectlyUnderMoovAlsoWorks() async throws {
        let moov = MP4Builder.atom("moov", MP4Builder.meta(ilst: sampleTags))
        let meta = try await read(MP4Builder.ftyp() + moov)
        XCTAssertEqual(meta.title, "21st Century Monetary Policy")
    }

    // MARK: - Duration

    func testDurationFromVersion0MVHD() async throws {
        let file = MP4Builder.ftyp()
            + MP4Builder.moov(
                mvhdAtom: MP4Builder.mvhd(version: 0, timescale: 1000, duration: 7_200_000),
                ilst: sampleTags
            )
        let meta = try await read(file)
        XCTAssertEqual(meta.duration ?? 0, 7200, accuracy: 0.001)
    }

    func testDurationFromVersion1MVHD() async throws {
        // 64-bit durations appear on long audiobooks; the 920 MB title in the
        // library is over 30 hours.
        let file = MP4Builder.ftyp()
            + MP4Builder.moov(
                mvhdAtom: MP4Builder.mvhd(version: 1, timescale: 44100, duration: 44100 * 115_200),
                ilst: sampleTags
            )
        let meta = try await read(file)
        XCTAssertEqual(meta.duration ?? 0, 115_200, accuracy: 0.01)
    }

    func testUnknownDurationSentinelIsNil() {
        var payload = Data([0, 0, 0, 0])
        payload += MP4Builder.be32(0) + MP4Builder.be32(0)
        payload += MP4Builder.be32(1000) + MP4Builder.be32(UInt32.max)
        XCTAssertNil(MP4AtomReader.duration(fromMVHD: payload))
    }

    func testZeroTimescaleDoesNotDivideByZero() {
        var payload = Data([0, 0, 0, 0])
        payload += MP4Builder.be32(0) + MP4Builder.be32(0)
        payload += MP4Builder.be32(0) + MP4Builder.be32(1000)
        XCTAssertNil(MP4AtomReader.duration(fromMVHD: payload))
    }

    // MARK: - Artwork

    func testExtractsJPEGCover() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x11, count: 64)
        let tags = sampleTags
            + MP4Builder.atom("covr", MP4Builder.dataAtom(imageIndicator: 13, bytes: jpeg))
        let meta = try await read(MP4Builder.ftyp() + MP4Builder.moov(ilst: tags))

        XCTAssertEqual(meta.artwork?.kind, .jpeg)
        XCTAssertEqual(meta.artwork?.data.count, jpeg.count)
    }

    func testExtractsPNGCover() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0x22, count: 64)
        let tags = sampleTags
            + MP4Builder.atom("covr", MP4Builder.dataAtom(imageIndicator: 14, bytes: png))
        let meta = try await read(MP4Builder.ftyp() + MP4Builder.moov(ilst: tags))
        XCTAssertEqual(meta.artwork?.kind, .png)
    }

    func testCoverWithZeroIndicatorIsSniffedNotDiscarded() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x33, count: 64)
        let tags = sampleTags
            + MP4Builder.atom("covr", MP4Builder.dataAtom(imageIndicator: 0, bytes: jpeg))
        let meta = try await read(MP4Builder.ftyp() + MP4Builder.moov(ilst: tags))
        XCTAssertEqual(meta.artwork?.kind, .jpeg, "a good cover must not be thrown away")
    }

    // MARK: - Freeform tags

    func testNarratorFromFreeformTag() async throws {
        let tags = sampleTags + MP4Builder.freeform(name: "NARRATOR", value: "Grover Gardner")
        let meta = try await read(MP4Builder.ftyp() + MP4Builder.moov(ilst: tags))
        XCTAssertEqual(meta.narrator, "Grover Gardner")
    }

    func testASINFromFreeformTagIsValidated() async throws {
        let tags = sampleTags + MP4Builder.freeform(name: "ASIN", value: "B09WRTNSPV")
        let meta = try await read(MP4Builder.ftyp() + MP4Builder.moov(ilst: tags))
        XCTAssertEqual(meta.catalogID, .asin("B09WRTNSPV"))
    }

    func testGarbageASINIsRejectedRatherThanStored() async throws {
        let tags = sampleTags + MP4Builder.freeform(name: "ASIN", value: "not-an-asin")
        let meta = try await read(MP4Builder.ftyp() + MP4Builder.moov(ilst: tags))
        XCTAssertNil(meta.catalogID)
    }

    // MARK: - Year

    func testYearFromBareValueAndFromTimestamp() {
        XCTAssertEqual(MP4AtomReader.parseYear("2022"), 2022)
        XCTAssertEqual(MP4AtomReader.parseYear("2022-05-17T00:00:00Z"), 2022)
        XCTAssertNil(MP4AtomReader.parseYear("nope"))
        XCTAssertNil(MP4AtomReader.parseYear("99"))
    }

    // MARK: - Malformed input

    func testNonMP4Throws() async {
        let junk = Data(repeating: 0x00, count: 512)
        do {
            _ = try await read(junk)
            XCTFail("expected a failure")
        } catch {}
    }

    func testFileWithNoMoovThrows() async {
        let file = MP4Builder.ftyp() + MP4Builder.mdat(byteCount: 256)
        do {
            _ = try await read(file)
            XCTFail("expected moovNotFound")
        } catch {}
    }

    func testSizeRunningPastEndOfFileDoesNotHang() async {
        // A header claiming more bytes than exist must end the walk, not loop.
        var file = MP4Builder.ftyp()
        file += MP4Builder.be32(0xFFFF_FFF0) + "mdat".data(using: .isoLatin1)!
        do {
            _ = try await read(file)
            XCTFail("expected a failure")
        } catch {}
    }

    func testChildWalkStopsOnCorruptChildSize() {
        // A child claiming to be larger than its parent must not be visited.
        var body = MP4Builder.be32(0xFFFF_FFF0)
        body += "\u{00A9}nam".data(using: .isoLatin1)!
        var visited = 0
        MP4AtomReader.forEachChild(in: body) { _, _ in visited += 1 }
        XCTAssertEqual(visited, 0)
    }

    func testEmptyMoovYieldsEmptyMetadata() async throws {
        let file = MP4Builder.ftyp() + MP4Builder.atom("moov", Data())
        let meta = try await read(file)
        XCTAssertTrue(meta.isEmpty)
    }
}

/// Wraps a reader and records how many bytes were actually transferred, so tests can
/// assert the walk does not pull payload it does not need.
actor CountingReader: ByteRangeReader {
    private let wrapped: DataRangeReader
    private(set) var bytesRead = 0

    init(_ wrapped: DataRangeReader) { self.wrapped = wrapped }

    var totalLength: Int64 { get async throws { wrapped.totalLength } }

    func read(offset: Int64, length: Int) async throws -> Data {
        let data = try await wrapped.read(offset: offset, length: length)
        bytesRead += data.count
        return data
    }
}
