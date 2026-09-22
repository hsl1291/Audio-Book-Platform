import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Supplies a currently-valid OAuth access token.
///
/// Deliberately a closure rather than an embedded OAuth client: token acquisition
/// needs a browser and a keychain, neither of which belongs in a Foundation-only
/// package that must stay testable. The app layer owns refresh; this source only
/// ever asks for a token and uses it.
public typealias AccessTokenProvider = @Sendable () async throws -> String

/// Reads a Google Drive folder tree.
///
/// Scanning a tree requires the `drive.readonly` scope, which Google classes as
/// *restricted*. An unverified OAuth client in Testing mode expires refresh tokens
/// every seven days, which would mean re-authenticating weekly. Settle that before
/// committing to this source — `LocalFilesSource` over iCloud Drive needs no OAuth
/// at all and is the intended fallback.
public struct GoogleDriveSource: LibrarySource {

    public let identifier: String
    public let displayName: String
    /// Drive id of the folder to watch.
    public let rootFolderID: String

    private let token: AccessTokenProvider
    private let session: URLSession

    public init(
        rootFolderID: String,
        displayName: String = "Google Drive",
        identifier: String = "gdrive",
        session: URLSession = .shared,
        token: @escaping AccessTokenProvider
    ) {
        self.rootFolderID = rootFolderID
        self.displayName = displayName
        self.identifier = identifier
        self.session = session
        self.token = token
    }

    public enum Failure: Error, CustomStringConvertible {
        case httpStatus(Int, body: String)
        case malformedResponse
        case notAFile

        public var description: String {
            switch self {
            case .httpStatus(let code, let body):
                return "Drive API returned \(code): \(body.prefix(200))"
            case .malformedResponse: return "Drive API response could not be decoded"
            case .notAFile: return "item has no downloadable content"
            }
        }
    }

    // MARK: - Scanning

    /// Walk the tree breadth-first, collecting every playable file with the path
    /// that led to it — the path is what lets shelf intent be inferred later.
    public func scan() async throws -> [DiscoveredItem] {
        var found: [DiscoveredItem] = []
        var queue: [(id: String, path: [String])] = [(rootFolderID, [])]

        while !queue.isEmpty {
            let (folderID, path) = queue.removeFirst()
            let children = try await listChildren(of: folderID)

            for child in children {
                if child.isFolder {
                    queue.append((child.id, path + [child.name]))
                } else if PlayableExtension.matches(child.name) {
                    found.append(
                        DiscoveredItem(
                            sourceRef: .googleDrive(fileID: child.id),
                            fileName: child.name,
                            folderName: path.last,
                            pathComponents: path,
                            byteCount: child.size,
                            modifiedAt: child.modifiedTime
                        )
                    )
                }
            }
        }
        return found
    }

    struct DriveEntry {
        var id: String
        var name: String
        var mimeType: String
        var size: Int64?
        var modifiedTime: Date?

        var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
    }

    func listChildren(of folderID: String) async throws -> [DriveEntry] {
        var entries: [DriveEntry] = []
        var pageToken: String?

        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            var query = [
                URLQueryItem(name: "q", value: "'\(folderID)' in parents and trashed = false"),
                URLQueryItem(
                    name: "fields",
                    value: "nextPageToken,files(id,name,mimeType,size,modifiedTime)"
                ),
                URLQueryItem(name: "pageSize", value: "1000"),
                // Shared drives are opt-in; without these a shared folder scans empty.
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            ]
            if let pageToken {
                query.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            components.queryItems = query

            let payload = try await get(components.url!)
            guard let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            else { throw Failure.malformedResponse }

            let files = object["files"] as? [[String: Any]] ?? []
            entries.append(contentsOf: files.compactMap(Self.decodeEntry))
            pageToken = object["nextPageToken"] as? String
        } while pageToken != nil

        return entries
    }

    static func decodeEntry(_ raw: [String: Any]) -> DriveEntry? {
        guard let id = raw["id"] as? String,
              let name = raw["name"] as? String,
              let mimeType = raw["mimeType"] as? String
        else { return nil }

        // Drive returns size as a string, because it can exceed 2^53 in JSON.
        let size = (raw["size"] as? String).flatMap(Int64.init)
            ?? (raw["size"] as? NSNumber)?.int64Value

        let modified = (raw["modifiedTime"] as? String).flatMap {
            try? Date($0, strategy: GoogleDriveSource.driveTimestamp)
        }

        return DriveEntry(
            id: id, name: name, mimeType: mimeType, size: size, modifiedTime: modified
        )
    }

    // MARK: - Content

    public func rangeReader(for item: DiscoveredItem) async throws -> any ByteRangeReader {
        guard case .googleDrive(let fileID) = item.sourceRef else { throw Failure.notAFile }
        let accessToken = try await token()
        return HTTPRangeReader(
            url: Self.mediaURL(for: fileID),
            session: session,
            headers: ["Authorization": "Bearer \(accessToken)"],
            knownLength: item.byteCount
        )
    }

    public func downloadRequest(for item: DiscoveredItem) async throws -> URLRequest? {
        guard case .googleDrive(let fileID) = item.sourceRef else { return nil }
        let accessToken = try await token()
        var request = URLRequest(url: Self.mediaURL(for: fileID))
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    static func mediaURL(for fileID: String) -> URL {
        var components = URLComponents(
            string: "https://www.googleapis.com/drive/v3/files/\(fileID)"
        )!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
        ]
        return components.url!
    }

    // MARK: - Transport

    private func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.httpStatus(
                http.statusCode, body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return data
    }
}

extension GoogleDriveSource {
    /// Drive timestamps carry fractional seconds (`2026-09-20T19:10:17.903Z`),
    /// which the default ISO 8601 parse rejects.
    ///
    /// A value-type format style rather than a shared `ISO8601DateFormatter`. The
    /// formatter is a non-Sendable reference type, so holding one in a static is a
    /// data race under Swift 6 -- the only one the language mode found in this
    /// package. The style is Sendable and needs no synchronisation at all.
    static let driveTimestamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
