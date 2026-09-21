import Foundation

#if canImport(FoundationNetworking)
// URLRequest lives here rather than in Foundation on non-Apple platforms.
import FoundationNetworking
#endif

/// Somewhere playable files can be found.
///
/// The whole app is written against this protocol rather than against any one
/// storage provider, which is what makes "the folder is the contract" real: adding
/// a provider means one conformance, and switching providers costs nothing above
/// this line.
public protocol LibrarySource: Sendable {
    /// Stable identifier for this source, so items can be attributed after a scan.
    var identifier: String { get }
    /// Shown in settings.
    var displayName: String { get }

    /// Every playable file currently visible, with enough path context to infer
    /// which shelf the user filed it under.
    func scan() async throws -> [DiscoveredItem]

    /// Random access to one item's bytes, for metadata reads that must not pull
    /// the whole file.
    func rangeReader(for item: DiscoveredItem) async throws -> any ByteRangeReader

    /// A request the download manager can hand to a background `URLSession`.
    /// Returns nil for sources whose bytes are already local.
    func downloadRequest(for item: DiscoveredItem) async throws -> URLRequest?

    /// Bytes already on this device, when the source itself can answer that —
    /// iCloud Drive knows; a remote API does not.
    func localURL(for item: DiscoveredItem) async throws -> URL?
}

extension LibrarySource {
    public func localURL(for item: DiscoveredItem) async throws -> URL? { nil }
}

/// File extensions the scanner treats as playable.
///
/// Deliberately broad. The existing library is entirely `.m4b`, but files from other
/// stores arrive as `.m4a` or `.mp3`, and refusing them would quietly hide books the
/// user owns.
public enum PlayableExtension {
    public static let all: Set<String> = [
        "m4b", "m4a", "mp3", "aac", "flac", "ogg", "opus", "wav",
    ]

    public static func matches(_ fileName: String) -> Bool {
        guard let dot = fileName.lastIndex(of: ".") else { return false }
        let ext = fileName[fileName.index(after: dot)...].lowercased()
        return all.contains(ext)
    }

    /// True for files that carry chapters and a single-file book, which is what the
    /// player is happiest with. Used only to rank candidates when a folder holds
    /// several playable files.
    public static func isPreferredContainer(_ fileName: String) -> Bool {
        fileName.lowercased().hasSuffix(".m4b")
    }
}
