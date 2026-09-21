import Foundation

/// Random access to a byte stream that may be remote.
///
/// Exists so `MP4AtomReader` can walk a 920 MB audiobook sitting in cloud storage
/// without downloading it, while still being testable against an in-memory buffer.
public protocol ByteRangeReader: Sendable {
    var totalLength: Int64 { get async throws }
    /// Read exactly `length` bytes at `offset`, or fewer at end of stream.
    func read(offset: Int64, length: Int) async throws -> Data
}

public enum ByteRangeError: Error, CustomStringConvertible {
    case outOfBounds(offset: Int64, length: Int, total: Int64)
    case truncated(expected: Int, got: Int)

    public var description: String {
        switch self {
        case .outOfBounds(let offset, let length, let total):
            return "range \(offset)..<\(offset + Int64(length)) lies outside \(total) bytes"
        case .truncated(let expected, let got):
            return "expected \(expected) bytes, received \(got)"
        }
    }
}

/// In-memory reader, for tests and for files already on disk and small enough to load.
public struct DataRangeReader: ByteRangeReader {
    private let data: Data

    public init(_ data: Data) { self.data = data }

    public var totalLength: Int64 { Int64(data.count) }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard offset >= 0, offset <= Int64(data.count) else {
            throw ByteRangeError.outOfBounds(offset: offset, length: length, total: Int64(data.count))
        }
        let start = Int(offset)
        let end = min(start + length, data.count)
        return data.subdata(in: start..<end)
    }
}

// MARK: - Big-endian integer reads

extension Data {
    /// Big-endian `UInt32` at a byte offset relative to the start of this `Data`.
    /// Returns nil rather than trapping when the slice is short, because slices
    /// here routinely come from truncated network reads.
    func beUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }

    func beUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        guard let hi = beUInt32(at: offset), let lo = beUInt32(at: offset + 4) else { return nil }
        return (UInt64(hi) << 32) | UInt64(lo)
    }

    /// Four-character atom type. MP4 type codes may include non-ASCII bytes such as
    /// the `©` that prefixes several standard tags, so decode as ISO Latin-1 to keep
    /// them comparable rather than dropping them.
    func fourCC(at offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = startIndex + offset
        let bytes = [self[base], self[base + 1], self[base + 2], self[base + 3]]
        return String(bytes: bytes, encoding: .isoLatin1)
    }
}
