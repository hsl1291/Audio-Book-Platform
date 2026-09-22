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

    private let bridge = NowPlayingBridge()
    private let context: ModelContext
    private var cancellables: Set<AnyCancellable> = []

    private var currentWork: StoredWork?
    private var currentCopy: StoredCopy?
    private var artwork: UIImage?
    private var pausedAt: Date?
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
    }

    // MARK: - Transport

    /// Start or resume a book from its saved position.
    func play(_ work: StoredWork) async {
        lastError = nil
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

            openRoot?.stopAccessingSecurityScopedResource()
            openRoot = root
            currentWork = work
            currentCopy = copy
            artwork = await work.coverCacheKey.asyncFlatMap { await CoverCache.shared.image(forKey: $0) }

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
        } catch {
            lastError = error.localizedDescription
        }
    }

    func pause() {
        engine.pause()
        pausedAt = Date()
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

private extension Optional {
    func asyncFlatMap<T>(_ transform: (Wrapped) async -> T?) async -> T? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
