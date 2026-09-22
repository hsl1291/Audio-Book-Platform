import Foundation
import SwiftData
import BacklistCore

/// Reads what each audio file says about itself -- title, author, narrator,
/// duration, cover -- and folds it into the library.
///
/// This is also what makes reconciliation possible. A freshly scanned book knows
/// only its folder name; until its author is read from the file it cannot be
/// matched to the same book imported from Goodreads.
@MainActor
enum MetadataEnricher {

    struct Report {
        var examined = 0
        var enriched = 0
        var notYetLocal = 0
    }

    /// Only files already on the device are read. An iCloud placeholder is skipped
    /// rather than downloaded: fetching 400 MB to learn an author's name is exactly
    /// the trade this app exists to avoid.
    static func run(context: ModelContext, root: URL) async -> Report {
        var report = Report()
        let store = LibraryStore(context: context)
        guard let works = try? store.allWorks() else { return report }

        for work in works {
            for copy in work.copies ?? [] {
                guard let path = copy.localRelativePath else { continue }
                report.examined += 1

                let url = root.appendingPathComponent(path)
                let isLocal = FileManager.default.fileExists(atPath: url.path)
                copy.availability = isLocal ? .downloaded : .cloudOnly
                guard isLocal else {
                    report.notYetLocal += 1
                    continue
                }

                let needsMetadata = copy.duration == nil || work.authors.isEmpty
                let needsCover = work.coverCacheKey == nil
                guard needsMetadata || needsCover else { continue }

                guard let reader = try? FileHandleRangeReader(url: url),
                      let metadata = try? await MP4AtomReader().metadata(from: reader)
                else { continue }

                store.enrich(work, with: metadata)
                if needsCover, let artwork = metadata.artwork {
                    let key = copy.identifier.uuidString
                    await CoverCache.shared.store(artwork.data, forKey: key)
                    work.coverCacheKey = key
                }
                report.enriched += 1
            }
        }
        try? context.save()
        return report
    }
}
