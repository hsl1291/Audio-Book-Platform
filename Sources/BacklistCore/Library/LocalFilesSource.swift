import Foundation

#if canImport(FoundationNetworking)
// URLRequest lives here rather than in Foundation on non-Apple platforms.
import FoundationNetworking
#endif

/// Reads a folder on the local file system, including an iCloud Drive folder.
///
/// This is the no-authentication path. If the `drive.readonly` token lifetime turns
/// out to be unworkable, pointing downloads at an iCloud Drive folder and using this
/// source removes Google from the design entirely — no OAuth, no tokens, no
/// refresh, no consent screen. The `LibrarySource` protocol is what makes that swap
/// cost days rather than weeks.
///
/// iCloud files may be *placeholders*: the folder lists them and reports their size,
/// but the bytes live in the cloud until requested. That is handled here rather than
/// leaked to callers.
public struct LocalFilesSource: LibrarySource {

    public let identifier: String
    public let displayName: String
    public let root: URL

    private let fileManager: FileManager

    public init(
        root: URL,
        displayName: String = "Files",
        identifier: String = "local",
        fileManager: FileManager = .default
    ) {
        self.root = root
        self.displayName = displayName
        self.identifier = identifier
        self.fileManager = fileManager
    }

    public enum Failure: Error, CustomStringConvertible {
        case notInRoot
        case unreadable(URL)

        public var description: String {
            switch self {
            case .notInRoot: return "item does not belong to this source"
            case .unreadable(let url): return "could not read \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Scanning

    public func scan() async throws -> [DiscoveredItem] {
        var found: [DiscoveredItem] = []
        var queue: [(url: URL, path: [String])] = [(root, [])]

        while !queue.isEmpty {
            let (directory, path) = queue.removeFirst()
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                    .isUbiquitousItemKey,
                ],
                options: [.skipsHiddenFiles]
            )

            for child in children {
                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
                ])

                if values?.isDirectory == true {
                    queue.append((child, path + [child.lastPathComponent]))
                    continue
                }

                let name = Self.materialisedName(of: child)
                guard PlayableExtension.matches(name) else { continue }

                found.append(
                    DiscoveredItem(
                        sourceRef: .localFile(relativePath: relativePath(of: child)),
                        fileName: name,
                        folderName: path.last,
                        pathComponents: path,
                        byteCount: values?.fileSize.map(Int64.init),
                        modifiedAt: values?.contentModificationDate
                    )
                )
            }
        }
        return found
    }

    /// An iCloud placeholder is named `.Original Name.m4b.icloud`. Recovering the
    /// real name matters because otherwise nothing matches the playable extensions
    /// and the whole library scans as empty.
    static func materialisedName(of url: URL) -> String {
        var name = url.lastPathComponent
        guard name.hasSuffix(".icloud") else { return name }
        name = String(name.dropLast(".icloud".count))
        if name.hasPrefix(".") { name.removeFirst() }
        return name
    }

    func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let itemPath = url.standardizedFileURL.path
        guard itemPath.hasPrefix(rootPath) else { return itemPath }
        var relative = String(itemPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }

    public func absoluteURL(for item: DiscoveredItem) throws -> URL {
        guard case .localFile(let relative) = item.sourceRef else { throw Failure.notInRoot }
        return root.appendingPathComponent(relative)
    }

    // MARK: - Content

    public func rangeReader(for item: DiscoveredItem) async throws -> any ByteRangeReader {
        let url = try absoluteURL(for: item)
        try await ensureMaterialised(at: url)
        return try FileHandleRangeReader(url: url)
    }

    /// Local bytes need no download step.
    public func downloadRequest(for item: DiscoveredItem) async throws -> URLRequest? { nil }

    public func localURL(for item: DiscoveredItem) async throws -> URL? {
        let url = try absoluteURL(for: item)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Ask iCloud for the bytes and wait for them to land.
    ///
    /// Polls rather than using an `NSMetadataQuery` observer: this runs once per
    /// file during a scan, the expected wait is short, and a query object would
    /// need a run loop this package cannot assume exists.
    func ensureMaterialised(at url: URL, timeout: TimeInterval = 30) async throws {
        if fileManager.fileExists(atPath: url.path) { return }

        #if canImport(Darwin)
        // iCloud ubiquity has no equivalent outside Apple's platforms. Elsewhere
        // a missing file is simply missing, which the timeout below reports.
        try fileManager.startDownloadingUbiquitousItem(at: url)
        #endif

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fileManager.fileExists(atPath: url.path) { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw Failure.unreadable(url)
    }
}

/// Random access to a local file without loading it into memory.
///
/// A 920 MB audiobook read with `Data(contentsOf:)` would be 920 MB of resident
/// memory for the sake of a few kilobytes of tags.
public actor FileHandleRangeReader: ByteRangeReader {
    private let handle: FileHandle
    private let length: Int64

    public init(url: URL) throws {
        self.handle = try FileHandle(forReadingFrom: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self.length = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    deinit { try? handle.close() }

    public var totalLength: Int64 { length }

    /// Actor isolation serialises the seek-then-read pair. A lock would do the
    /// same job, but NSLock is unavailable from async contexts and becomes a hard
    /// error under the Swift 6 language mode.
    public func read(offset: Int64, length count: Int) async throws -> Data {
        guard offset >= 0, offset < length else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count) ?? Data()
    }
}
