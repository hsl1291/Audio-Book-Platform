import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads byte ranges of a remote file over HTTP.
///
/// This is what lets `MP4AtomReader` pull a cover out of a 920 MB audiobook sitting
/// in cloud storage for a few kilobytes of transfer.
public actor HTTPRangeReader: ByteRangeReader {

    public enum Failure: Error, CustomStringConvertible {
        case rangeUnsupported
        case unexpectedStatus(Int)
        case noContentLength

        public var description: String {
            switch self {
            case .rangeUnsupported:
                return "server ignored the Range header and returned the whole file"
            case .unexpectedStatus(let code):
                return "HTTP \(code)"
            case .noContentLength:
                return "server did not report a content length"
            }
        }
    }

    private let url: URL
    private let session: URLSession
    private let extraHeaders: [String: String]
    private var cachedLength: Int64?

    public init(
        url: URL,
        session: URLSession = .shared,
        headers: [String: String] = [:],
        knownLength: Int64? = nil
    ) {
        self.url = url
        self.session = session
        self.extraHeaders = headers
        self.cachedLength = knownLength
    }

    public var totalLength: Int64 {
        get async throws {
            if let cachedLength { return cachedLength }

            // A HEAD is the polite way to ask, but plenty of file-serving endpoints
            // reject it. Fall back to a one-byte ranged GET, which also proves the
            // server honours Range before we rely on it.
            if let length = try? await lengthViaHEAD() {
                cachedLength = length
                return length
            }
            let length = try await lengthViaProbe()
            cachedLength = length
            return length
        }
    }

    public func read(offset: Int64, length: Int) async throws -> Data {
        guard length > 0 else { return Data() }
        let end = offset + Int64(length) - 1

        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.unexpectedStatus(-1)
        }

        switch http.statusCode {
        case 206:
            return data
        case 200:
            // The server ignored Range and sent everything. Slicing locally keeps
            // the caller correct, but the transfer already happened — which for a
            // 920 MB file is exactly what this class exists to avoid.
            guard offset < Int64(data.count) else { return Data() }
            let start = Int(offset)
            let stop = min(start + length, data.count)
            return data.subdata(in: start..<stop)
        case 416:
            // Asked past the end; a short read is the honest answer.
            return Data()
        default:
            throw Failure.unexpectedStatus(http.statusCode)
        }
    }

    // MARK: - Length discovery

    private func lengthViaHEAD() async throws -> Int64 {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure.noContentLength
        }
        guard let raw = http.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(raw)
        else { throw Failure.noContentLength }
        return length
    }

    /// `Content-Range: bytes 0-0/12345` gives the total even when HEAD is refused.
    private func lengthViaProbe() async throws -> Int64 {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.noContentLength
        }
        guard http.statusCode == 206,
              let contentRange = http.value(forHTTPHeaderField: "Content-Range"),
              let total = Self.totalFromContentRange(contentRange)
        else {
            throw Failure.rangeUnsupported
        }
        return total
    }

    /// Parse the total out of `bytes 0-0/12345`. Returns nil for `*` totals.
    static func totalFromContentRange(_ header: String) -> Int64? {
        guard let slash = header.lastIndex(of: "/") else { return nil }
        let tail = header[header.index(after: slash)...].trimmingCharacters(in: .whitespaces)
        return Int64(tail)
    }
}
