import Foundation

/// One playable file found by scanning a source, before it has been identified as
/// any particular `Work`.
public struct DiscoveredItem: Identifiable, Hashable, Sendable {
    public var id: String { sourceRef.stableID }

    public var sourceRef: SourceRef
    /// Name of the file itself, extension included.
    public var fileName: String
    /// Name of the immediately containing folder, when there is one. The existing
    /// library puts the `Title [ID]` convention on the folder, not always the file.
    public var folderName: String?
    /// Path components from the watched root down to (not including) the file.
    /// Used to infer which shelf the user had filed something under.
    public var pathComponents: [String]
    public var byteCount: Int64?
    public var modifiedAt: Date?

    public init(
        sourceRef: SourceRef,
        fileName: String,
        folderName: String? = nil,
        pathComponents: [String] = [],
        byteCount: Int64? = nil,
        modifiedAt: Date? = nil
    ) {
        self.sourceRef = sourceRef
        self.fileName = fileName
        self.folderName = folderName
        self.pathComponents = pathComponents
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }

    /// Best available `Title [ID]` parse: prefer the folder, fall back to the file.
    ///
    /// The folder is preferred because it is the more stable of the two in the
    /// existing library — folders carry the clean title, files sometimes carry a
    /// filesystem-mangled full title.
    public var parsedName: ParsedName {
        if let folderName, case let folderParse = FolderNameParser.parse(folderName),
           folderParse.catalogID != nil {
            return folderParse
        }
        let fileParse = FolderNameParser.parse(fileName)
        if fileParse.catalogID != nil { return fileParse }
        // Neither had an id; prefer whichever title looks more complete.
        if let folderName {
            let folderParse = FolderNameParser.parse(folderName)
            if fileParse.title.count > folderParse.title.count { return fileParse }
            return folderParse
        }
        return fileParse
    }

    /// Which shelf the containing folder implies, if any.
    ///
    /// Purely a hint from how the user has filed things by hand.
    ///
    /// A file inside a download tool's output directory implies **nothing**, even
    /// when that directory sits inside a shelf folder. This guard is the whole
    /// point: in the live library the dump folder is nested at
    /// `Books/_Read/Books (Last Download)/`, so walking up the path would report
    /// every brand-new download as already finished. Returning nil here is what
    /// makes new arrivals land in Waiting to Read instead of Read.
    public var shelfHint: Shelf? {
        guard !isInDumpFolder else { return nil }
        for component in pathComponents.reversed() {
            if let shelf = ShelfHint.classify(component) { return shelf }
        }
        return nil
    }

    /// True when this file sits in a tool's output directory rather than a folder
    /// the user deliberately filed it into.
    public var isInDumpFolder: Bool {
        pathComponents.contains { ShelfHint.isDumpFolder($0) }
    }
}

public enum ShelfHint {
    /// Folder names the user has actually used, plus the obvious variants.
    /// `_Too Read` is the spelling in the live library — keep it, and accept the
    /// conventional spelling too.
    public static func classify(_ folderName: String) -> Shelf? {
        let n = MatchKey.normalise(folderName)
        switch n {
        case "read", "finished", "done": return .finished
        case "too read", "to read", "toread", "unread", "next": return .owned
        case "reading", "currently reading", "in progress": return .reading
        case "abandoned", "dnf", "did not finish": return .abandoned
        case "reference", "keep": return .reference
        default: return nil
        }
    }

    /// Output directories belonging to download tools. Files here have not been
    /// filed by a human, so their location must not be read as intent.
    public static func isDumpFolder(_ folderName: String) -> Bool {
        let n = MatchKey.normalise(folderName)
        return n.contains("last download") || n == "inbox" || n == "downloads" || n == "new"
    }
}

extension SourceRef {
    /// A stable string identity, used for dictionary keys and diffing across scans.
    public var stableID: String {
        switch self {
        case .googleDrive(let fileID): return "gdrive:\(fileID)"
        case .localFile(let path): return "local:\(path)"
        case .kindleASIN(let asin): return "kindle:\(asin)"
        }
    }
}
