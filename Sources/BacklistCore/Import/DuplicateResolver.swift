import Foundation

/// Collapses the same book appearing in several folders into one `Work`, and
/// reports what could be deleted.
///
/// The live library has 202 folders holding 106 distinct books — 96 redundant
/// copies, roughly 37.5 GB. Every duplicate involves the download tool's own dump
/// folder, because that folder was never cleared after files were filed elsewhere.
public enum DuplicateResolver {

    public struct Group: Identifiable, Sendable {
        public var id: String { canonical.id }
        /// The copy to keep.
        public var canonical: DiscoveredItem
        /// Copies that say the same thing and could go.
        public var redundant: [DiscoveredItem]
        /// Why these were grouped, so the UI can be honest about certainty.
        public var basis: Basis

        public var reclaimableBytes: Int64 {
            redundant.reduce(0) { $0 + ($1.byteCount ?? 0) }
        }

        /// Only exact-id matches are safe to act on without asking.
        public var isSafeToAutoMerge: Bool {
            switch basis {
            case .catalogID: return true
            case .titleAndAuthor(let confidence): return confidence == .exact
            }
        }
    }

    public enum Basis: Hashable, Sendable {
        case catalogID(CatalogID)
        case titleAndAuthor(MatchKey.Confidence)
    }

    public struct Result: Sendable {
        public var groups: [Group]
        /// Items that appeared exactly once. Nothing to decide about these.
        public var unique: [DiscoveredItem]

        public var totalItems: Int {
            unique.count + groups.reduce(0) { $0 + 1 + $1.redundant.count }
        }
        public var distinctBooks: Int { unique.count + groups.count }
        public var redundantCount: Int { groups.reduce(0) { $0 + $1.redundant.count } }
        public var reclaimableBytes: Int64 { groups.reduce(0) { $0 + $1.reclaimableBytes } }
    }

    /// Group items that describe the same book.
    ///
    /// Two passes, deliberately in this order:
    ///   1. Exact catalogue id. Unambiguous, and covers the whole existing library.
    ///   2. Normalised title + author, for files with no id — which is everything
    ///      arriving from a store that does not use the `Title [ID]` convention.
    public static func resolve(_ items: [DiscoveredItem]) -> Result {
        var byID: [CatalogID: [DiscoveredItem]] = [:]
        var withoutID: [DiscoveredItem] = []

        for item in items {
            if let id = item.parsedName.catalogID {
                byID[id, default: []].append(item)
            } else {
                withoutID.append(item)
            }
        }

        var groups: [Group] = []
        var unique: [DiscoveredItem] = []

        for (id, bucket) in byID {
            guard bucket.count > 1 else {
                unique.append(contentsOf: bucket)
                continue
            }
            let ordered = bucket.sorted(by: canonicalOrder)
            groups.append(
                Group(
                    canonical: ordered[0],
                    redundant: Array(ordered.dropFirst()),
                    basis: .catalogID(id)
                )
            )
        }

        // Fuzzy pass over whatever had no id.
        //
        // Author is deliberately nil here: at scan time all we have is a file name.
        // Authors only become available once `MP4AtomReader` has read the embedded
        // tags, which happens later and costs a network round trip per book. That
        // ceiling means this pass can never reach `.exact`, so nothing it groups is
        // ever auto-merged — it surfaces candidates for a human instead.
        var remaining = withoutID
        while let seed = remaining.first {
            remaining.removeFirst()
            let seedKey = MatchKey(title: seed.parsedName.title, author: nil)

            var matched: [DiscoveredItem] = []
            var best: MatchKey.Confidence = .none
            remaining.removeAll { candidate in
                let key = MatchKey(title: candidate.parsedName.title, author: nil)
                let confidence = seedKey.confidence(against: key)
                guard confidence >= .weak else { return false }
                if confidence > best { best = confidence }
                matched.append(candidate)
                return true
            }

            if matched.isEmpty {
                unique.append(seed)
            } else {
                let ordered = ([seed] + matched).sorted(by: canonicalOrder)
                groups.append(
                    Group(
                        canonical: ordered[0],
                        redundant: Array(ordered.dropFirst()),
                        basis: .titleAndAuthor(best)
                    )
                )
            }
        }

        return Result(groups: groups.sorted { $0.reclaimableBytes > $1.reclaimableBytes },
                      unique: unique)
    }

    /// Which copy to keep. Ordered so the first element wins.
    ///
    /// A file the user deliberately filed under a shelf beats one still sitting in
    /// the tool's dump folder — that is precisely the shape of all 96 duplicates in
    /// the live library, and keeping the filed copy preserves the shelf information
    /// that would otherwise be lost.
    static func canonicalOrder(_ a: DiscoveredItem, _ b: DiscoveredItem) -> Bool {
        if a.isInDumpFolder != b.isInDumpFolder { return !a.isInDumpFolder }
        if (a.shelfHint != nil) != (b.shelfHint != nil) { return a.shelfHint != nil }
        // Prefer the larger file: a truncated or failed download is the likelier
        // explanation for a size difference than a better encode.
        let aBytes = a.byteCount ?? 0
        let bBytes = b.byteCount ?? 0
        if aBytes != bBytes { return aBytes > bBytes }
        // Stable tiebreak so results do not shuffle between runs.
        return a.id < b.id
    }
}
