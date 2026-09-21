import Foundation

/// One downloadable file, as the policy engine sees it.
public struct ManagedFile: Identifiable, Hashable, Sendable {
    public var id: BookCopy.ID { copyID }

    public var copyID: BookCopy.ID
    public var byteCount: Int64
    public var availability: LocalAvailability
    /// Pinned files are never evicted, whatever the budget says.
    public var isPinned: Bool
    public var shelf: Shelf
    /// Position in the Up Next queue, or nil when not queued.
    public var queuePosition: Int?
    public var lastPlayedAt: Date?
    public var finishedAt: Date?
    /// The file currently open in the player. Evicting this would stop playback.
    public var isNowPlaying: Bool

    public init(
        copyID: BookCopy.ID,
        byteCount: Int64,
        availability: LocalAvailability = .cloudOnly,
        isPinned: Bool = false,
        shelf: Shelf = .owned,
        queuePosition: Int? = nil,
        lastPlayedAt: Date? = nil,
        finishedAt: Date? = nil,
        isNowPlaying: Bool = false
    ) {
        self.copyID = copyID
        self.byteCount = byteCount
        self.availability = availability
        self.isPinned = isPinned
        self.shelf = shelf
        self.queuePosition = queuePosition
        self.lastPlayedAt = lastPlayedAt
        self.finishedAt = finishedAt
        self.isNowPlaying = isNowPlaying
    }

    public var occupiesSpace: Bool {
        availability == .downloaded || availability == .partial
    }
}

/// What the device can do right now.
public struct DeviceConditions: Hashable, Sendable {
    public var onWiFi: Bool
    public var isCharging: Bool
    /// Free space reported by the file system, when known.
    public var freeDiskBytes: Int64?

    public init(onWiFi: Bool, isCharging: Bool, freeDiskBytes: Int64? = nil) {
        self.onWiFi = onWiFi
        self.isCharging = isCharging
        self.freeDiskBytes = freeDiskBytes
    }

    public static let unconstrained = DeviceConditions(onWiFi: true, isCharging: true)
}

/// Decides what to keep on the device and what to fetch next.
///
/// The library is ~41 GB after deduplication against a phone that might have 20 GB
/// free, so "download everything" was never available. The job here is to make the
/// right ten books already be there, and to make being wrong cheap — a position is
/// never lost when a file is evicted, only the bytes.
public struct StoragePolicy: Hashable, Sendable {
    /// Hard ceiling the user sets.
    public var budgetBytes: Int64
    /// How far down the queue to pre-fetch.
    public var autoDownloadCount: Int
    /// How long a finished book keeps its bytes before they are reclaimed.
    public var finishedGraceDays: Int
    public var requiresWiFi: Bool
    public var requiresCharging: Bool
    /// Keep this much of the budget free so a download never fills the disk.
    public var headroomBytes: Int64

    public init(
        budgetBytes: Int64,
        autoDownloadCount: Int = 3,
        finishedGraceDays: Int = 7,
        requiresWiFi: Bool = true,
        requiresCharging: Bool = false,
        headroomBytes: Int64 = 500 * 1024 * 1024
    ) {
        self.budgetBytes = budgetBytes
        self.autoDownloadCount = autoDownloadCount
        self.finishedGraceDays = finishedGraceDays
        self.requiresWiFi = requiresWiFi
        self.requiresCharging = requiresCharging
        self.headroomBytes = headroomBytes
    }

    public static let `default` = StoragePolicy(budgetBytes: 15 * 1024 * 1024 * 1024)

    // MARK: - Planning

    public enum EvictionReason: String, Hashable, Sendable {
        /// Finished, and past the grace period.
        case finishedAndAged
        case abandoned
        /// Evicted to get back under the budget.
        case overBudget
    }

    public struct Eviction: Hashable, Sendable {
        public var copyID: BookCopy.ID
        public var reason: EvictionReason
        public var bytesReclaimed: Int64
    }

    public struct Plan: Sendable {
        public var toDownload: [BookCopy.ID]
        public var toEvict: [Eviction]
        public var bytesBefore: Int64
        public var bytesAfter: Int64
        /// Non-zero when pinned files alone exceed the budget. The policy will not
        /// evict a pinned file to fix this; it reports the overage so the UI can
        /// tell the user plainly rather than silently deleting something they
        /// asked to keep.
        public var overBudgetBy: Int64

        public var reclaimedBytes: Int64 { toEvict.reduce(0) { $0 + $1.bytesReclaimed } }
        public var isNoOp: Bool { toDownload.isEmpty && toEvict.isEmpty }
    }

    public func plan(
        for files: [ManagedFile],
        conditions: DeviceConditions = .unconstrained,
        now: Date = Date()
    ) -> Plan {
        let bytesBefore = files.filter(\.occupiesSpace).reduce(0) { $0 + $1.byteCount }
        var resident = Set(files.filter(\.occupiesSpace).map(\.copyID))
        var used = bytesBefore
        var evictions: [Eviction] = []

        func evict(_ file: ManagedFile, _ reason: EvictionReason) {
            guard resident.contains(file.copyID) else { return }
            resident.remove(file.copyID)
            used -= file.byteCount
            evictions.append(
                Eviction(copyID: file.copyID, reason: reason, bytesReclaimed: file.byteCount)
            )
        }

        // 1. Reclaim finished and abandoned books whose grace period has passed.
        //    This happens regardless of budget pressure — holding 400 MB of a book
        //    you finished last month helps nobody.
        for file in files where resident.contains(file.copyID) && isEvictable(file) {
            if let reason = staleReason(file, now: now) {
                evict(file, reason)
            }
        }

        // 2. If still over the effective budget, evict by rank, least useful first.
        let ceiling = effectiveCeiling(conditions: conditions, alreadyResident: bytesBefore)
        if used > ceiling {
            let candidates = files
                .filter { resident.contains($0.copyID) && isEvictable($0) }
                .sorted { Self.evictionOrder($0, $1) }

            for file in candidates where used > ceiling {
                evict(file, .overBudget)
            }
        }

        // 3. Queue downloads, but only what still fits.
        var toDownload: [BookCopy.ID] = []
        if allowsDownloads(conditions) {
            let wanted = files
                .filter { file in
                    guard let position = file.queuePosition, position < autoDownloadCount else {
                        return false
                    }
                    return !resident.contains(file.copyID) && file.availability != .notAFile
                }
                .sorted { ($0.queuePosition ?? .max) < ($1.queuePosition ?? .max) }

            for file in wanted where used + file.byteCount <= ceiling {
                toDownload.append(file.copyID)
                used += file.byteCount
            }
        }

        // Anything still over budget at this point is unevictable by definition —
        // pinned, or currently playing. Report it rather than breaking the promise
        // that pinned means pinned.
        return Plan(
            toDownload: toDownload,
            toEvict: evictions,
            bytesBefore: bytesBefore,
            bytesAfter: used,
            overBudgetBy: max(0, used - budgetBytes)
        )
    }

    // MARK: - Rules

    /// Pinned files and the one currently playing are never touched.
    func isEvictable(_ file: ManagedFile) -> Bool {
        !file.isPinned && !file.isNowPlaying
    }

    func staleReason(_ file: ManagedFile, now: Date) -> EvictionReason? {
        switch file.shelf {
        case .finished:
            guard let finishedAt = file.finishedAt else { return nil }
            let age = now.timeIntervalSince(finishedAt)
            return age >= TimeInterval(finishedGraceDays) * 86_400 ? .finishedAndAged : nil
        case .abandoned:
            return .abandoned
        default:
            return nil
        }
    }

    func allowsDownloads(_ conditions: DeviceConditions) -> Bool {
        if requiresWiFi && !conditions.onWiFi { return false }
        if requiresCharging && !conditions.isCharging { return false }
        return true
    }

    /// The budget, further limited by what the disk can actually take.
    ///
    /// The true maximum the library may occupy is what it occupies now plus what is
    /// still free, minus headroom so a download can never fill the device. When the
    /// device is nearly full this drops *below* the user's budget, which is correct:
    /// the budget is a ceiling the user chose, not a reservation the disk honours.
    func effectiveCeiling(conditions: DeviceConditions, alreadyResident: Int64) -> Int64 {
        guard let free = conditions.freeDiskBytes else { return budgetBytes }
        let diskLimit = alreadyResident + max(0, free - headroomBytes)
        return min(budgetBytes, diskLimit)
    }

    /// Ordering for budget-pressure eviction. Lower rank goes first.
    ///
    /// A book you finished is less useful than one you abandoned, which is less
    /// useful than one you never queued, which is less useful than one waiting in
    /// the queue. Within a rank, least recently played goes first.
    static func evictionOrder(_ a: ManagedFile, _ b: ManagedFile) -> Bool {
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }

        let da = a.lastPlayedAt ?? .distantPast
        let db = b.lastPlayedAt ?? .distantPast
        if da != db { return da < db }

        return a.copyID.uuidString < b.copyID.uuidString
    }

    static func rank(_ file: ManagedFile) -> Int {
        switch file.shelf {
        case .finished: return 0
        case .abandoned: return 1
        default: break
        }
        guard let position = file.queuePosition else {
            // Never played and never queued: downloaded once and forgotten.
            return file.lastPlayedAt == nil ? 2 : 3
        }
        return position == 0 ? 6 : (position < 3 ? 5 : 4)
    }
}
