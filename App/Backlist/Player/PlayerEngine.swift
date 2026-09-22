import Foundation
import AVFoundation
import Combine
import BacklistCore

/// Audiobook playback.
///
/// Separate from `NowPlayingBridge`, which mirrors this state to the lock screen
/// and the car. This type knows nothing about either.
@MainActor
final class PlayerEngine: ObservableObject {

    @Published private(set) var currentCopyID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var offset: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var currentChapterIndex: Int?
    @Published var rate: Float = 1.0 {
        didSet { if isPlaying { player.rate = rate } }
    }

    struct Chapter: Identifiable, Hashable {
        let id: Int
        let title: String
        let start: TimeInterval
        let duration: TimeInterval
        var end: TimeInterval { start + duration }
    }

    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: AnyCancellable?

    /// Called whenever the position should be persisted. Wired to the store by the
    /// app so this type stays free of persistence concerns.
    var onPositionChange: ((UUID, TimeInterval, Int?, Float) -> Void)?
    var onFinished: ((UUID) -> Void)?

    // MARK: - Session

    init() {
        configureAudioSession()
        observeTime()
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
    }

    /// `.spokenAudio` is the correct mode for books: it ducks appropriately, and on
    /// CarPlay it tells the system this is speech rather than music, which affects
    /// how the car handles interruptions.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, policy: .longFormAudio)
        try? session.setActive(true)
    }

    // MARK: - Loading

    func load(
        copyID: UUID,
        url: URL,
        startingAt start: TimeInterval,
        rate startRate: Float
    ) async {
        currentCopyID = copyID
        rate = startRate

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)

        duration = (try? await asset.load(.duration).seconds) ?? 0
        chapters = await Self.loadChapters(from: asset)

        await seek(to: start)
        observeEnd(of: item, copyID: copyID)
    }

    /// Chapters come from the file's own chapter track. Parsing these by hand from
    /// the container would mean walking sample tables; `AVAsset` does it correctly
    /// and for free once the file is local, which is why the remote metadata reader
    /// deliberately skips them.
    private static func loadChapters(from asset: AVAsset) async -> [Chapter] {
        guard let locales = try? await asset.load(.availableChapterLocales),
              let locale = locales.first
                ?? Locale.preferredLanguages.first.map(Locale.init(identifier:))
        else { return [] }

        guard let groups = try? await asset.loadChapterMetadataGroups(
            withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle]
        ) else { return [] }

        var result: [Chapter] = []
        for (index, group) in groups.enumerated() {
            let titleItem = group.items.first { $0.commonKey == .commonKeyTitle }
            let title = try? await titleItem?.load(.stringValue)

            result.append(
                Chapter(
                    id: index,
                    title: title ?? "Chapter \(index + 1)",
                    start: group.timeRange.start.seconds,
                    duration: group.timeRange.duration.seconds
                )
            )
        }
        return result
    }

    // MARK: - Transport

    func play() {
        player.rate = rate
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        persistPosition()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    func seek(to seconds: TimeInterval) async {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        await player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        offset = clamped
        updateChapterIndex()
        persistPosition()
    }

    func skip(by delta: TimeInterval) async {
        await seek(to: offset + delta)
    }

    func seekToChapter(_ index: Int) async {
        guard chapters.indices.contains(index) else { return }
        await seek(to: chapters[index].start)
    }

    func nextChapter() async {
        guard let current = currentChapterIndex else { return }
        await seekToChapter(current + 1)
    }

    func previousChapter() async {
        guard let current = currentChapterIndex else { return }
        // Within the first few seconds, go to the previous chapter; otherwise
        // restart the current one. This is what a physical transport control does
        // and what people expect in a car.
        let chapterStart = chapters[current].start
        if offset - chapterStart < 3 {
            await seekToChapter(current - 1)
        } else {
            await seekToChapter(current)
        }
    }

    /// Rewind proportionally to how long playback was paused.
    ///
    /// Coming back after a night's sleep needs more context than coming back from
    /// a thirty-second interruption. Capped so it never feels like losing progress.
    func smartRewind(pausedFor interval: TimeInterval) async {
        let rewind: TimeInterval
        switch interval {
        case ..<60: rewind = 0
        case ..<600: rewind = 5
        case ..<3600: rewind = 15
        default: rewind = 30
        }
        guard rewind > 0 else { return }
        await seek(to: max(0, offset - rewind))
    }

    // MARK: - Observation

    /// Persist every 15 seconds and on every chapter boundary, so a crash costs
    /// seconds rather than a listening session.
    private func observeTime() {
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.offset = time.seconds
                let previousChapter = self.currentChapterIndex
                self.updateChapterIndex()

                let crossedChapter = previousChapter != self.currentChapterIndex
                let onInterval = Int(time.seconds) % 15 == 0
                if crossedChapter || onInterval { self.persistPosition() }
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem, copyID: UUID) {
        endObserver = NotificationCenter.default
            .publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: item)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.isPlaying = false
                    self?.onFinished?(copyID)
                }
            }
    }

    private func updateChapterIndex() {
        currentChapterIndex = chapters.firstIndex { offset >= $0.start && offset < $0.end }
            ?? (chapters.isEmpty ? nil : chapters.count - 1)
    }

    private func persistPosition() {
        guard let currentCopyID else { return }
        onPositionChange?(currentCopyID, offset, currentChapterIndex, rate)
    }

    var currentChapterTitle: String? {
        currentChapterIndex.flatMap { chapters.indices.contains($0) ? chapters[$0].title : nil }
    }
}
