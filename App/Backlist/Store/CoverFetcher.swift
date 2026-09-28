import Foundation
import SwiftData
import BacklistCore

/// Fetches covers from Open Library for books with no audio file to read one from,
/// and caches them on the device so they show offline.
///
/// Runs in the background after an import and on launch. Private books are never
/// looked up: their titles do not leave the device.
@MainActor
final class CoverFetcher {

    private let context: ModelContext
    private var task: Task<Void, Never>?

    /// A miss is retried after this long; Open Library gains covers over time.
    private static let retryAfter: TimeInterval = 30 * 86_400

    init(context: ModelContext) {
        self.context = context
    }

    func run() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.fetchMissing()
            self?.task = nil
        }
    }

    private func fetchMissing() async {
        let now = Date()
        let works = ((try? LibraryStore(context: context).allWorks()) ?? []).filter { work in
            guard work.coverCacheKey == nil, !work.isPrivate else { return false }
            guard let last = work.coverLookupAt else { return true }
            return now.timeIntervalSince(last) > Self.retryAfter
        }

        for work in works {
            if Task.isCancelled { return }
            // A file-backed book may still get its embedded cover once it is
            // downloaded; that is better art, so only look those up when the
            // file has already been read and had none.
            if work.hasPlayableCopy && (work.copies ?? []).contains(where: { $0.duration == nil }) {
                continue
            }

            let key = "ol-\(work.identifier.uuidString)"
            if let data = await Self.cover(isbn13: work.isbn13, key: work.work.matchKey,
                                           title: work.title, author: work.authors.first) {
                await CoverCache.shared.store(data, forKey: key)
                work.coverCacheKey = key
            }
            work.coverLookupAt = Date()
            try? context.save()

            // Be a polite client of a free service.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Network

    nonisolated private static func cover(
        isbn13: String?, key: MatchKey, title: String, author: String?
    ) async -> Data? {
        var coverID: Int?
        if let isbn13, let json = await get(OpenLibraryCovers.searchURL(isbn13: isbn13)) {
            coverID = OpenLibraryCovers.firstCoverID(in: json)
        }
        if coverID == nil,
           let json = await get(OpenLibraryCovers.searchURL(title: title, author: author)) {
            coverID = OpenLibraryCovers.bestCoverID(in: json, for: key)
        }
        guard let coverID,
              let data = await get(OpenLibraryCovers.coverURL(coverID: coverID)),
              OpenLibraryCovers.isPlausibleCover(data)
        else { return nil }
        return data
    }

    nonisolated private static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 20)
        // Open Library asks clients to identify themselves.
        request.setValue("Backlist/1.0 (personal audiobook library)", forHTTPHeaderField: "User-Agent")
        guard let result = try? await URLSession.shared.data(for: request),
              (result.1 as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return result.0
    }
}
