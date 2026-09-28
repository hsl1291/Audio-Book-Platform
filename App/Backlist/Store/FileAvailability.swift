import Foundation
import BacklistCore

/// Whether an audiobook's bytes are actually on this device.
///
/// A books folder picked in Files can live in iCloud Drive or in another app's
/// storage — Google Drive, Dropbox, OneDrive — surfaced through a File Provider.
/// Items there are often *dataless*: the file appears in its folder with its full
/// size, but the bytes are still in the cloud. `fileExists` says yes to those, and
/// reading even a few bytes forces the whole file down. Across this library that
/// would mean pulling ~50 GB just to read cover art, so every read goes through
/// this check first.
enum FileAvailability {

    static func status(of url: URL) -> LocalAvailability {
        let keys: Set<URLResourceKey> = [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemIsDownloadingKey,
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            // Nothing at the real name yet — typically a legacy iCloud placeholder.
            return .cloudOnly
        }
        guard values.isUbiquitousItem == true else {
            // Plain local storage ("On My iPhone"): always here.
            return .downloaded
        }
        switch values.ubiquitousItemDownloadingStatus {
        case .current?, .downloaded?:
            return .downloaded
        default:
            return values.ubiquitousItemIsDownloading == true ? .partial : .cloudOnly
        }
    }

    static func isUbiquitous(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?.isUbiquitousItem == true
    }

    /// Ask the owning cloud service for the bytes. Returns immediately; arrival
    /// is observed by polling `status(of:)`.
    static func requestDownload(_ url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Drop the local bytes and keep the cloud copy.
    ///
    /// Refuses anything that is not a cloud item. A file that exists only on this
    /// device has no other copy, and "free up space" must never mean "delete".
    static func removeLocalCopy(_ url: URL) throws {
        guard isUbiquitous(url) else { throw Failure.notInCloud }
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    enum Failure: LocalizedError {
        case notInCloud
        var errorDescription: String? {
            "This file is stored only on this device, so removing it would delete it. Backlist will not do that."
        }
    }
}
