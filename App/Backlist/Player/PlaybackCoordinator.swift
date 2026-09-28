import Foundation
import SwiftData
import Combine
import UIKit
import BacklistCore

/// Connects the player to everything outside it: the saved position, the shelf
/// transitions, and the lock screen / Control Centre / car.
///
/// `PlayerEngine` deliberately knows none of that, which kept it simple -- and
/// also meant that without this type, nothing ever saved a position or published
/// Now Playing state. Positions were computed every second and thrown away.
@MainActor
final class PlaybackCoordinator: ObservableObject {

    let engine = PlayerEngine()
    @Published private(set) var lastError: String?
    /// Title of a book the user asked to play whose file is still downloading.
    @Published private(set) var waitingFor: String?
    @Published private(set) var sleepTimer = SleepTimer()

    weak var downloads: DownloadCoordinator?

    /// The copy open in the player, which storage management must never evict.
    var currentCopyID: UUID? { currentCopy?.identifier }

    private let bridge = NowPlayingBridge()
    private let shake = ShakeDetector()
    private let context: ModelContext
    private var cancellables: Set<AnyCancellable> = []

    private var currentWork: StoredWork?
    private var currentCopy: StoredCopy?
    private var artwork: UIImage?
    private var pausedAt: Date?
    private var pending: (work: StoredWork, requestedAt: Date)?
    /// Security scope of the books folder, held open for as long as a file from it
    /// is playing. Closing it mid-book would cut playback off.
    private var openRoot: URL?

    init(context: ModelContext) {
        self.context = context

        engine.onPositionChange = { [weak self] copyID, offset, chapter, rate in
            self?.persist(copyID: copyID, offset: offset, chapter: chapter, rate: rate)
        }
        engine.onFinished = { [weak self] _ in
            self?.bookEnded()
        }

        bridge.activate(with: .init(
            play: { [weak self] in self?.resume() },
            pause: { [weak self] in self?.pause() },
            skipForward: { [weak self] seconds in
                Task { await self?.engine.skip(by: seconds) }
            },
            skipBackward: { [weak self] seconds in
                Task { await self?.engine.skip(by: -seconds) }
            },
            nextChapter: { [weak self] in Task { await self?.engine.nextChapter() } },
            previousChapter: { [weak self] in Task { await self?.engine.previousChapter() } },
            seek: { [weak self] position in Task { await self?.engine.seek(to: position) } },
            changeRate: { [weak self] rate in self?.engine.rate = rate }
        ))

        // `objectWillChange` fires before the change lands; hopping to the next
        // run-loop turn publishes the new state rather than the old one.
        engine.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.publishNowPlaying() }
            .store(in: &cancellables)

        // The engine reports position once a second while playing, which is the
        // sleep timer's clock.
        engine.$offset
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tickSleepTimer() }
            .store(in: &cancellables)
        shake.onShake = { [weak self] in self?.extendSleepTimer() }
    }

    // MARK: - Transport

    /// Start or resume a book from its saved position.
    func play(_ work: StoredWork) async {
        lastError = nil
        pending = nil
        waitingFor = nil
        guard let copy = (work.copies ?? []).first(where: \.isPlayable) else {
            lastError = "There is no audio file for this book."
            return
        }
        guard let path = copy.localRelativePath else {
            lastError = "This book is in Google Drive and hasn't been downloaded to this device."
            return
        }

        do {
            let root = try LibraryFolder.openRoot()
            let url = try LibraryFolder.fileURL(relativePath: path, in: root)

            // Same book already loaded: just resume, keeping the live position.
            if currentCopy?.identifier == copy.identifier {
                root.stopAccessingSecurityScopedResource()
                resume()
                return
            }

            // Save where the outgoing book got to before anything points at the
            // incoming one; otherwise up to 15 seconds of listening is lost.
            persistNow()
            openRoot?.stopAccessingSecurityScopedResource()
            openRoot = root
            currentWork = work
            currentCopy = copy
            if let key = work.coverCacheKey {
                artwork = await CoverCache.shared.image(forKey: key)
            } else {
                artwork = nil
            }

            await engine.load(
                copyID: copy.identifier,
                url: url,
                startingAt: copy.positionOffset,
                rate: Float(copy.playbackRate)
            )
            engine.play()
            pausedAt = nil
            try? LibraryStore(context: context).markReading(work)
            publishNowPlaying()
        } catch LibraryFolder.Failure.fileMissing {
            // Requested by `fileURL`; start as soon as it lands.
            pending = (work, Date())
            waitingFor = work.title
            downloads?.watchDownloads()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Forget a book waiting to download, so it will not start on its own.
    func cancelWaiting() {
        pending = nil
        waitingFor = nil
    }

    /// Called by `DownloadCoordinator` whenever file availability is re-read.
    ///
    /// Starts a book the user asked for once its file arrives — but only within a
    /// few minutes of asking. A download that finishes long after the user gave up
    /// waiting must not start talking out of a pocket.
    func availabilityChanged() {
        guard let pending else { return }
        guard Date().timeIntervalSince(pending.requestedAt) < 15 * 60 else {
            cancelWaiting()
            return
        }
        let arrived = (pending.work.copies ?? []).contains {
            $0.isPlayable && $0.availability == .downloaded
        }
        if arrived {
            Task { await play(pending.work) }
        }
    }

    func pause() {
        engine.pause()
        pausedAt = Date()
        sleepTimer.suspend()
        shake.stop()
    }

    /// Resume, stepping back in proportion to how long playback was paused.
    func resume() {
        Task {
            if let pausedAt {
                await engine.smartRewind(pausedFor: Date().timeIntervalSince(pausedAt))
            }
            pausedAt = nil
            engine.play()
        }
    }

    func togglePlayPause() {
        engine.isPlaying ? pause() : resume()
    }

    // MARK: - Sleep timer

    func startSleepTimer(_ mode: SleepTimer.Mode) {
        sleepTimer.start(mode, now: Date(), chapterEnd: engine.currentChapterEnd)
        if !engine.isPlaying { sleepTimer.suspend() }
        engine.volume = 1
    }

    func cancelSleepTimer() {
        sleepTimer.cancel()
        engine.volume = 1
        shake.stop()
    }

    /// Shake: another full countdown, or one more chapter.
    func extendSleepTimer() {
        guard sleepTimer.isActive else { return }
        sleepTimer.extend(now: Date(), nextChapterEnd: engine.nextChapterEnd)
        engine.volume = 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func tickSleepTimer() {
        guard sleepTimer.isActive, engine.isPlaying else { return }
        switch sleepTimer.tick(now: Date(), offset: engine.offset, rate: engine.rate) {
        case .play(let volume):
            engine.volume = volume
            // Listen for a shake only near the end, when it can matter.
            let left = sleepTimer.remaining(offset: engine.offset, rate: engine.rate) ?? .infinity
            if left < 60 { shake.start() } else { shake.stop() }
        case .stop:
            pause()
            engine.volume = 1
        }
    }

    // MARK: - Persistence

    /// Called every 15 seconds, on every chapter boundary, on pause and on seek.
    private func persist(copyID: UUID, offset: TimeInterval, chapter: Int?, rate: Float) {
        guard let copy = currentCopy, copy.identifier == copyID else { return }
        copy.positionOffset = offset
        copy.positionChapter = chapter
        copy.playbackRate = Double(rate)
        copy.lastPlayedAt = Date()
        try? context.save()
    }

    private func bookEnded() {
        guard let work = currentWork else { return }
        try? LibraryStore(context: context).markFinished(work)
        publishNowPlaying()
        // A finished book starts its storage grace period, and the queue has moved.
        downloads?.refresh()
    }

    /// Save the live position of the current book immediately.
    private func persistNow() {
        guard let copy = currentCopy else { return }
        persist(
            copyID: copy.identifier, offset: engine.offset,
            chapter: engine.currentChapterIndex, rate: engine.rate
        )
    }

    // MARK: - Now Playing

    private func publishNowPlaying() {
        guard let work = currentWork else {
            bridge.clear()
            return
        }
        bridge.update(.init(
            title: work.title,
            author: work.authors.first ?? "",
            chapterTitle: engine.currentChapterTitle,
            offset: engine.offset,
            duration: engine.duration,
            rate: engine.rate,
            isPlaying: engine.isPlaying,
            artwork: artwork,
            isPrivate: work.isPrivate
        ))
    }
}
