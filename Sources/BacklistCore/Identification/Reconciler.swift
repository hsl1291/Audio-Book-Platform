import Foundation

/// Decides which file-backed works duplicate which tracked-only works.
///
/// A library built from two sources arrives in two halves. Scanning a folder
/// yields works that have a file but no history; importing Goodreads yields works
/// that have history but no file. The same book in both halves must become one
/// record, or every book you have both read and kept shows up twice -- which is
/// the one outcome a consolidation app cannot have.
///
/// This is a pure decision so it can be tested. The app applies the result.
public enum Reconciler {

    public struct Candidate: Hashable, Sendable {
        public var id: UUID
        public var key: MatchKey
        public var isbn13: String?

        public init(id: UUID, key: MatchKey, isbn13: String?) {
            self.id = id
            self.key = key
            self.isbn13 = isbn13
        }
    }

    public struct Pair: Hashable, Sendable {
        public var fileBacked: UUID
        public var tracked: UUID
    }

    /// Pair each file-backed work with at most one tracked-only work.
    ///
    /// ISBN-13 agreement is decisive. Otherwise title and author must agree at
    /// `.strong` or better -- a title alone never merges, since "Principles" by one
    /// author is not "Principles" by another. When two tracked works tie for the
    /// best match, the pair is skipped rather than guessed: two rows the user can
    /// see is better than one silently wrong merge they cannot.
    public static func pairs(fileBacked: [Candidate], trackedOnly: [Candidate]) -> [Pair] {
        var claimed = Set<UUID>()
        var result: [Pair] = []

        // ISBN matches first, so a certain match is never lost to a fuzzy one.
        var pending: [Candidate] = []
        for file in fileBacked {
            if let isbn = file.isbn13,
               let hit = trackedOnly.first(where: { $0.isbn13 == isbn && !claimed.contains($0.id) }) {
                claimed.insert(hit.id)
                result.append(Pair(fileBacked: file.id, tracked: hit.id))
            } else {
                pending.append(file)
            }
        }

        for file in pending {
            let scored = trackedOnly
                .filter { !claimed.contains($0.id) }
                .map { (candidate: $0, confidence: file.key.confidence(against: $0.key)) }
                .filter { $0.confidence >= .strong }
            guard let best = scored.map({ $0.confidence }).max() else { continue }

            let top = scored.filter { $0.confidence == best }
            guard top.count == 1 else { continue }

            claimed.insert(top[0].candidate.id)
            result.append(Pair(fileBacked: file.id, tracked: top[0].candidate.id))
        }
        return result
    }
}
