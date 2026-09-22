import Foundation
import SwiftData
import BacklistCore

/// Owns the persisted library and everything that writes to it.
///
/// Scanning, importing and merging all funnel through here so there is exactly one
/// place that decides when two records are the same book.
@MainActor
final class LibraryStore {

    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - Lookup

    func allWorks() throws -> [StoredWork] {
        try context.fetch(FetchDescriptor<StoredWork>())
    }

    /// Find an existing record for a book, in descending order of certainty.
    ///
    /// CloudKit forbids unique constraints, so identity is enforced here rather
    /// than by the store. Getting this wrong shows up as duplicate rows in the
    /// grid, which is exactly the problem the app exists to solve.
    func findWork(asin: String?, isbn13: String?, matchKey: MatchKey?) throws -> StoredWork? {
        let candidates = try allWorks()

        if let asin, !asin.isEmpty,
           let hit = candidates.first(where: { $0.asin == asin }) {
            return hit
        }
        if let isbn13, !isbn13.isEmpty,
           let hit = candidates.first(where: { $0.isbn13 == isbn13 }) {
            return hit
        }
        guard let matchKey else { return nil }

        // Only an exact title-and-author agreement merges automatically. Anything
        // weaker becomes a suggestion the user confirms, because silently merging
        // two different books is worse than showing two rows.
        return candidates.first { stored in
            stored.work.matchKey.confidence(against: matchKey) == .exact
        }
    }

    // MARK: - Goodreads import

    @discardableResult
    func importGoodreads(csv text: String) throws -> GoodreadsCSVImporter.Summary {
        let summary = try GoodreadsCSVImporter().import(csv: text)

        // History only: Goodreads fills the Read tab and nothing else.
        for book in summary.readHistory {
            let existing = try findWork(
                asin: nil,
                isbn13: book.work.isbn13,
                matchKey: book.work.matchKey
            )
            let record = existing ?? StoredWork(identifier: book.work.id)
            if existing == nil { context.insert(record) }

            apply(book, to: record, overwritingJudgements: existing == nil)
        }
        try context.save()
        return summary
    }

    /// Copy an imported row onto a record.
    ///
    /// `overwritingJudgements` guards the fields that represent the user's own
    /// opinion. On a re-import, a rating or review already in the app must not be
    /// clobbered by a stale CSV — the export is a snapshot, and the app has been
    /// the source of truth since the first import.
    private func apply(
        _ book: GoodreadsCSVImporter.ImportedBook,
        to record: StoredWork,
        overwritingJudgements: Bool
    ) {
        record.title = book.work.title
        record.authors = book.work.authors
        record.isbn13 = record.isbn13 ?? book.work.isbn13
        record.publishedYear = record.publishedYear ?? book.work.publishedYear
        record.goodreadsID = book.goodreadsID
        record.tags = Array(Set(record.tags + book.tags)).sorted()

        if overwritingJudgements {
            record.shelf = book.shelf
            record.intent = book.intent
            record.rating = book.journal.rating
            record.review = book.journal.review
            record.finishedAt = book.journal.finishedAt
            record.readCount = book.journal.readCount
            record.addedAt = book.work.addedAt
        } else {
            record.rating = record.rating ?? book.journal.rating
            record.review = record.review ?? book.journal.review
            record.finishedAt = record.finishedAt ?? book.journal.finishedAt
            record.readCount = max(record.readCount, book.journal.readCount)
        }
    }

    // MARK: - Library scan

    struct ScanReport {
        var discovered: Int
        var newWorks: Int
        var attachedToExisting: Int
        var duplicateGroups: Int
        var reclaimableBytes: Int64
    }

    /// Fold a source's files into the library.
    ///
    /// Runs the duplicate resolver first so that a book present in several folders
    /// becomes one record with one copy, not one record per folder.
    @discardableResult
    func scan(source: some LibrarySource) async throws -> ScanReport {
        let items = try await source.scan()
        let resolved = DuplicateResolver.resolve(items)

        var newWorks = 0
        var attached = 0

        for item in resolved.unique + resolved.groups.map(\.canonical) {
            let parsed = item.parsedName
            let asin: String?
            let isbn: String?
            switch parsed.catalogID {
            case .asin(let value): asin = value; isbn = nil
            case .isbn10(let value): asin = nil; isbn = FolderNameParser.isbn13(fromISBN10: value)
            case nil: asin = nil; isbn = nil
            }

            let key = MatchKey(title: parsed.title, author: nil)
            let existing = try findWork(asin: asin, isbn13: isbn, matchKey: key)

            let record: StoredWork
            if let existing {
                record = existing
                attached += 1
                // Wanted, and a file has turned up: it is owned now.
                if record.shelf == .want {
                    record.shelf = .owned
                    record.intent = .none
                }
            } else {
                record = StoredWork(title: parsed.title)
                record.addedAt = item.modifiedAt ?? Date()
                // A file the user filed under a shelf carries that intent. A file
                // still sitting in a download tool's output folder carries none,
                // which is what stops new arrivals importing as already finished.
                record.shelf = item.shelfHint ?? .owned
                context.insert(record)
                newWorks += 1
            }

            record.asin = record.asin ?? asin
            if record.isbn13 == nil, let isbn { record.isbn13 = isbn }
            attachCopy(for: item, to: record)
        }

        try context.save()
        return ScanReport(
            discovered: items.count,
            newWorks: newWorks,
            attachedToExisting: attached,
            duplicateGroups: resolved.groups.count,
            reclaimableBytes: resolved.reclaimableBytes
        )
    }

    private func attachCopy(for item: DiscoveredItem, to record: StoredWork) {
        let existing = (record.copies ?? []).first { $0.sourceRef == item.sourceRef }
        let copy = existing ?? StoredCopy()

        copy.format = .audiobook
        copy.provenance = .audioFile
        copy.sourceRef = item.sourceRef
        copy.byteCount = item.byteCount

        if existing == nil {
            copy.work = record
            context.insert(copy)
        }
    }

    // MARK: - Metadata enrichment

    /// Fill in what the file itself knows. Called lazily, a few books at a time,
    /// because each one costs a network round trip.
    func enrich(_ record: StoredWork, with metadata: AudioMetadata) {
        if let title = metadata.bestTitle, record.title.isEmpty { record.title = title }
        if record.authors.isEmpty, let author = metadata.author { record.authors = [author] }
        if record.narrators.isEmpty, let narrator = metadata.narrator {
            record.narrators = [narrator]
        }
        record.publishedYear = record.publishedYear ?? metadata.year
        record.summary = record.summary ?? metadata.summary

        if record.asin == nil, case .asin(let value)? = metadata.catalogID {
            record.asin = value
        }
        for copy in record.copies ?? [] where copy.duration == nil {
            copy.duration = metadata.duration
        }
    }

    // MARK: - Reconciliation

    /// Merge each scanned book into the same book imported from Goodreads.
    ///
    /// Without this the library shows every book you have both read and kept
    /// twice: once from the folder, with the file, and once from Goodreads, with
    /// your history. The matching decision lives in `Reconciler`, where it is
    /// tested; this applies it. Safe to run repeatedly.
    @discardableResult
    func reconcile() throws -> Int {
        let works = try allWorks()
        let hasCopies = { (work: StoredWork) in !(work.copies ?? []).isEmpty }

        // A scanned book with no author yet cannot be matched safely; it will be
        // eligible once `MetadataEnricher` has read its tags.
        let fileBacked = works.filter { hasCopies($0) && !$0.authors.isEmpty }
        let trackedOnly = works.filter { !hasCopies($0) }

        func candidate(_ work: StoredWork) -> Reconciler.Candidate {
            Reconciler.Candidate(id: work.identifier, key: work.work.matchKey, isbn13: work.isbn13)
        }
        let pairs = Reconciler.pairs(
            fileBacked: fileBacked.map(candidate),
            trackedOnly: trackedOnly.map(candidate)
        )

        let byID = Dictionary(works.map { ($0.identifier, $0) }, uniquingKeysWith: { first, _ in first })
        for pair in pairs {
            guard let scanned = byID[pair.fileBacked], let tracked = byID[pair.tracked] else { continue }
            merge(scanned, into: tracked)
        }
        try context.save()
        return pairs.count
    }

    /// Keep the tracked record, which holds the user's own rating, review and
    /// dates, and move the files onto it.
    private func merge(_ scanned: StoredWork, into tracked: StoredWork) {
        let copies = scanned.copies ?? []
        // Detach before deleting: `scanned` cascades to its copies, and they must
        // survive the delete on their new owner.
        scanned.copies = []
        for copy in copies { copy.work = tracked }

        tracked.asin = tracked.asin ?? scanned.asin
        tracked.isbn13 = tracked.isbn13 ?? scanned.isbn13
        if tracked.authors.isEmpty { tracked.authors = scanned.authors }
        if tracked.narrators.isEmpty { tracked.narrators = scanned.narrators }
        tracked.summary = tracked.summary ?? scanned.summary
        tracked.publishedYear = tracked.publishedYear ?? scanned.publishedYear
        tracked.coverCacheKey = tracked.coverCacheKey ?? scanned.coverCacheKey

        // A book on the Want list that turns out to have a file is owned: it
        // belongs in Waiting to Read, not on the shopping list.
        if tracked.shelf == .want {
            tracked.shelf = .owned
            tracked.intent = .none
        }
        context.delete(scanned)
    }

    // MARK: - Shelf transitions

    /// Mark finished. This is the transition that removes a book from the Waiting
    /// to Read grid, and the one that starts the storage grace period.
    func markFinished(_ record: StoredWork, at date: Date = Date()) throws {
        record.shelf = .finished
        record.finishedAt = date
        record.readCount += 1
        record.intent = .none
        for copy in record.copies ?? [] { copy.queuePosition = nil }
        try context.save()
    }

    func markReading(_ record: StoredWork) throws {
        if record.startedAt == nil { record.startedAt = Date() }
        record.shelf = .reading
        try context.save()
    }

    /// Recompute Up Next. Reading comes before owned-but-unstarted; within each,
    /// most recently touched first.
    func refreshQueue() throws {
        let works = try allWorks().filter(\.isWaitingToRead)
        let ordered = works.sorted { a, b in
            let ra = a.shelf == .reading ? 0 : 1
            let rb = b.shelf == .reading ? 0 : 1
            if ra != rb { return ra < rb }
            return a.addedAt > b.addedAt
        }

        for (index, work) in ordered.enumerated() {
            for copy in work.copies ?? [] where copy.isPlayable {
                copy.queuePosition = index
            }
        }
        try context.save()
    }

    // MARK: - Storage

    func managedFiles(nowPlaying: UUID?) throws -> [ManagedFile] {
        try allWorks().flatMap { work in
            (work.copies ?? []).map { copy in
                copy.managedFile(
                    shelf: work.shelf,
                    finishedAt: work.finishedAt,
                    isNowPlaying: copy.identifier == nowPlaying
                )
            }
        }
    }
}
