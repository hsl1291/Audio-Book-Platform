import Foundation
import SwiftData
import Network
import UIKit
import BacklistCore

/// Keeps the right books on the phone.
///
/// Applies `StoragePolicy` — the tested decision about what to fetch and what to
/// let go — to the books folder. For iCloud Drive and for providers such as Google
/// Drive that appear in Files, fetching and releasing are system calls: the
/// provider downloads the bytes, and releasing drops only the local copy. Nothing
/// here ever deletes a file.
@MainActor
final class DownloadCoordinator: ObservableObject {

    struct Status: Equatable {
        var onDeviceBytes: Int64 = 0
        var downloading = 0
        var overBudgetBy: Int64 = 0
        var lastError: String?
    }

    @Published private(set) var status = Status()

    private let context: ModelContext
    weak var playback: PlaybackCoordinator?

    private let monitor = NWPathMonitor()
    private var onUnmeteredNetwork = true
    private var pollTask: Task<Void, Never>?
    private var enrichTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
        UIDevice.current.isBatteryMonitoringEnabled = true

        // "Wi-Fi only" really means "not on a metered connection": a phone
        // tethered to another phone is on Wi-Fi and still costs data.
        monitor.pathUpdateHandler = { [weak self] path in
            let unmetered = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor in
                guard let self, self.onUnmeteredNetwork != unmetered else { return }
                self.onUnmeteredNetwork = unmetered
                if unmetered { self.refresh() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.backlist.network"))
    }

    // MARK: - Policy and conditions

    /// Settings are read at the moment of use, so a change takes effect on the
    /// next refresh without any wiring between screens.
    private var policy: StoragePolicy {
        let defaults = UserDefaults.standard
        let gigabytes = defaults.object(forKey: "storageBudgetGB") as? Double ?? 15
        return StoragePolicy(
            budgetBytes: Int64(gigabytes * 1_073_741_824),
            autoDownloadCount: defaults.object(forKey: "autoDownloadCount") as? Int ?? 3,
            finishedGraceDays: defaults.object(forKey: "finishedGraceDays") as? Int ?? 7,
            requiresWiFi: defaults.object(forKey: "requiresWiFi") as? Bool ?? true,
            requiresCharging: defaults.object(forKey: "requiresCharging") as? Bool ?? false
        )
    }

    private var conditions: DeviceConditions {
        let battery = UIDevice.current.batteryState
        let free = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return DeviceConditions(
            onWiFi: onUnmeteredNetwork,
            isCharging: battery == .charging || battery == .full,
            freeDiskBytes: free
        )
    }

    // MARK: - Refresh

    /// Re-read where every file is, then fetch and release according to policy.
    /// Cheap to call often: on launch, on returning to the app, after a scan,
    /// after a book finishes, and after pinning.
    func refresh() {
        guard let root = try? LibraryFolder.openRoot() else { return }
        defer { root.stopAccessingSecurityScopedResource() }

        let store = LibraryStore(context: context)
        let located = updateAvailability(in: root)

        try? store.refreshQueue()
        // A file stored only on this device has no cloud copy to fall back to, so
        // it can be neither fetched nor released. Leaving it out of the plan keeps
        // the policy from scheduling evictions that would only fail.
        let files = ((try? store.managedFiles(nowPlaying: playback?.currentCopyID)) ?? [])
            .filter { file in
                guard let entry = located[file.copyID] else { return false }
                return FileAvailability.isUbiquitous(entry.url)
            }
        let plan = policy.plan(for: files, conditions: conditions)

        var errors: [String] = []
        for eviction in plan.toEvict {
            guard let entry = located[eviction.copyID] else { continue }
            do {
                try FileAvailability.removeLocalCopy(entry.url)
                entry.copy.availability = .cloudOnly
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        for copyID in plan.toDownload {
            guard let entry = located[copyID] else { continue }
            do {
                try FileAvailability.requestDownload(entry.url)
                entry.copy.availability = .partial
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        try? context.save()

        publish(located: located, overBudgetBy: plan.overBudgetBy, error: errors.first)
        enrichArrivals(located)
        watchDownloads()
    }

    // MARK: - Per-book actions

    /// Fetch one book now, regardless of queue position or network preference —
    /// the user asked for it explicitly.
    func download(_ work: StoredWork) {
        withLocatedCopy(of: work) { copy, url in
            try FileAvailability.requestDownload(url)
            copy.availability = .partial
        }
        watchDownloads()
    }

    /// Release one book's local bytes. Unpins it, since keeping and removing are
    /// contradictory; the saved position is untouched.
    func removeDownload(_ work: StoredWork) {
        withLocatedCopy(of: work) { copy, url in
            guard copy.identifier != playback?.currentCopyID else {
                throw Failure.nowPlaying
            }
            copy.isPinned = false
            try FileAvailability.removeLocalCopy(url)
            copy.availability = .cloudOnly
        }
    }

    /// True when a book's bytes are on the device right now.
    func isOnDevice(_ work: StoredWork) -> Bool {
        (work.copies ?? []).contains { $0.isPlayable && $0.availability == .downloaded }
    }

    enum Failure: LocalizedError {
        case nowPlaying
        var errorDescription: String? {
            "This book is playing. Stop it before removing the download."
        }
    }

    // MARK: - Internals

    private struct Located {
        let copy: StoredCopy
        let url: URL
    }

    /// Refresh every copy's availability; return each located copy and its URL.
    @discardableResult
    private func updateAvailability(in root: URL) -> [UUID: Located] {
        var located: [UUID: Located] = [:]
        let works = (try? LibraryStore(context: context).allWorks()) ?? []
        for work in works {
            for copy in work.copies ?? [] {
                guard let path = copy.localRelativePath else { continue }
                let url = root.appendingPathComponent(path)
                let now = FileAvailability.status(of: url)
                if copy.availability != now { copy.availability = now }
                located[copy.identifier] = Located(copy: copy, url: url)
            }
        }
        return located
    }

    /// Read tags and cover art from files that have arrived since the last scan.
    ///
    /// A book downloaded after the folder was scanned knows only its file name.
    /// Until its tags are read it has no author, so it cannot be matched to its
    /// Goodreads entry, and has no cover.
    private func enrichArrivals(_ located: [UUID: Located]) {
        guard enrichTask == nil else { return }
        let arrived = located.values.contains {
            $0.copy.availability == .downloaded && $0.copy.duration == nil
        }
        guard arrived else { return }
        enrichTask = Task { [weak self] in
            guard let self else { return }
            if let root = try? LibraryFolder.openRoot() {
                let report = await MetadataEnricher.run(context: self.context, root: root)
                root.stopAccessingSecurityScopedResource()
                if report.enriched > 0 {
                    _ = try? LibraryStore(context: self.context).reconcile()
                }
            }
            self.enrichTask = nil
        }
    }

    private func withLocatedCopy(
        of work: StoredWork,
        _ action: (StoredCopy, URL) throws -> Void
    ) {
        guard let copy = (work.copies ?? []).first(where: { $0.localRelativePath != nil }),
              let path = copy.localRelativePath
        else { return }
        do {
            let root = try LibraryFolder.openRoot()
            defer { root.stopAccessingSecurityScopedResource() }
            try action(copy, root.appendingPathComponent(path))
            try? context.save()
            status.lastError = nil
        } catch {
            status.lastError = error.localizedDescription
        }
    }

    private func publish(located: [UUID: Located], overBudgetBy: Int64, error: String?) {
        let copies = located.values.map(\.copy)
        status = Status(
            onDeviceBytes: copies
                .filter { $0.availability == .downloaded }
                .reduce(0) { $0 + ($1.byteCount ?? 0) },
            downloading: copies.filter { $0.availability == .partial }.count,
            overBudgetBy: overBudgetBy,
            lastError: error
        )
    }

    /// While anything is arriving, re-check every ten seconds so badges update and
    /// a book the user tried to play starts as soon as it lands.
    func watchDownloads() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self else { return }
                guard let root = try? LibraryFolder.openRoot() else { break }
                let located = self.updateAvailability(in: root)
                root.stopAccessingSecurityScopedResource()
                try? self.context.save()
                self.publish(located: located, overBudgetBy: self.status.overBudgetBy,
                             error: self.status.lastError)
                self.playback?.availabilityChanged()
                self.enrichArrivals(located)
                // A provider can take a moment to report a requested download as
                // under way; keep looking while someone is waiting to listen.
                if self.status.downloading == 0 && self.playback?.waitingFor == nil { break }
            }
            self?.pollTask = nil
        }
    }
}
