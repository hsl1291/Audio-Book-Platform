import Foundation

/// Stops playback after a while, or at the end of the chapter.
///
/// Pure state and arithmetic; the app ticks it once a second while playing and
/// applies the returned action. The countdown runs only while audio plays — a
/// book paused for a phone call should not lose its remaining sleep time.
public struct SleepTimer: Equatable, Sendable {

    public enum Mode: Equatable, Sendable {
        /// Stop after this much listening.
        case after(TimeInterval)
        /// Stop when the chapter playing when the timer was set ends.
        case endOfChapter
    }

    public enum Action: Equatable, Sendable {
        /// Keep going at this volume, from 1 (normal) down to 0 as the fade ends.
        case play(volume: Float)
        case stop
    }

    /// Volume ramps down over the final stretch rather than cutting off, so
    /// falling asleep is not interrupted by a sudden silence.
    public static let fadeLength: TimeInterval = 10
    public static let presets: [TimeInterval] = [5, 15, 30, 45, 60].map { $0 * 60 }

    public private(set) var mode: Mode?
    /// Listening time left for `.after`.
    private var remainingListening: TimeInterval = 0
    /// Book position to stop at for `.endOfChapter`.
    private var stopAtOffset: TimeInterval?
    private var lastTick: Date?

    public init() {}

    public var isActive: Bool { mode != nil }

    // MARK: - Control

    /// - Parameter chapterEnd: end of the current chapter, or of the book when it
    ///   has no chapters.
    public mutating func start(_ mode: Mode, now: Date, chapterEnd: TimeInterval?) {
        self.mode = mode
        lastTick = now
        switch mode {
        case .after(let length):
            remainingListening = length
            stopAtOffset = nil
        case .endOfChapter:
            stopAtOffset = chapterEnd
        }
    }

    public mutating func cancel() {
        self = SleepTimer()
    }

    /// Shake to extend: a full new countdown, or one more chapter.
    public mutating func extend(now: Date, nextChapterEnd: TimeInterval?) {
        guard let mode else { return }
        switch mode {
        case .after(let length): remainingListening = length
        case .endOfChapter: stopAtOffset = nextChapterEnd ?? stopAtOffset
        }
        lastTick = now
    }

    /// Stop counting while paused; the next `tick` after resuming picks up again
    /// without charging the paused interval.
    public mutating func suspend() {
        lastTick = nil
    }

    // MARK: - Ticking

    /// Advance the countdown and say what the player should do.
    ///
    /// - Parameters:
    ///   - offset: current position in the book, in book seconds.
    ///   - rate: playback rate; at 1.5×, ten book seconds pass in under seven.
    public mutating func tick(now: Date, offset: TimeInterval, rate: Float) -> Action {
        guard let mode else { return .play(volume: 1) }
        defer { lastTick = now }

        let remaining: TimeInterval
        switch mode {
        case .after:
            if let lastTick { remainingListening -= max(0, now.timeIntervalSince(lastTick)) }
            remaining = remainingListening
        case .endOfChapter:
            guard let stopAtOffset else { return .play(volume: 1) }
            remaining = (stopAtOffset - offset) / Double(max(rate, 0.1))
        }

        if remaining <= 0 {
            cancel()
            return .stop
        }
        if remaining < Self.fadeLength {
            return .play(volume: Float(remaining / Self.fadeLength))
        }
        return .play(volume: 1)
    }

    /// Wall-clock seconds left, for display.
    public func remaining(offset: TimeInterval, rate: Float) -> TimeInterval? {
        switch mode {
        case .after?: return max(0, remainingListening)
        case .endOfChapter?:
            guard let stopAtOffset else { return nil }
            return max(0, (stopAtOffset - offset) / Double(max(rate, 0.1)))
        case nil: return nil
        }
    }
}
