import Foundation

/// The user's books folder, remembered across launches.
///
/// iOS grants access to a folder picked in Files only for as long as the app keeps
/// a security-scoped bookmark to it. Without resolving that bookmark, every stored
/// path is relative to a folder the app can no longer open -- which is why books
/// could be listed but never played.
enum LibraryFolder {

    private static let bookmarkKey = "booksFolderBookmark"

    enum Failure: LocalizedError {
        case noFolderChosen
        case fileMissing(String)

        var errorDescription: String? {
            switch self {
            case .noFolderChosen:
                return "Choose your books folder in Settings first."
            case .fileMissing(let name):
                return "\(name) isn't on this device yet. It has been requested from iCloud -- try again once it finishes downloading."
            }
        }
    }

    /// Remember a folder the user just picked. Call while its scope is open.
    static func remember(_ url: URL) throws {
        let data = try url.bookmarkData(
            options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// The remembered folder, with its security scope opened. The caller owns the
    /// scope and must call `stopAccessingSecurityScopedResource()` when done.
    static func openRoot() throws -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            throw Failure.noFolderChosen
        }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data, options: [], relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        _ = url.startAccessingSecurityScopedResource()
        // A stale bookmark still resolves, but will stop doing so; refresh it now
        // while access is open rather than lose the folder on some later launch.
        if isStale { try? remember(url) }
        return url
    }

    /// Absolute URL of a copy stored relative to the books folder.
    ///
    /// If the file is an iCloud placeholder, this asks iCloud for it and throws
    /// rather than blocking: a 400 MB audiobook takes far longer to arrive than any
    /// reasonable wait on a tap.
    static func fileURL(relativePath: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        throw Failure.fileMissing(url.deletingPathExtension().lastPathComponent)
    }
}
