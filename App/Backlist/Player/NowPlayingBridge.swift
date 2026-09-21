import Foundation
import MediaPlayer
import UIKit

/// Mirrors playback state to the lock screen, Control Centre, AirPods, the Apple
/// Watch, and the car.
///
/// ## Why this matters more than it looks
///
/// The CarPlay *list* entitlement must be requested from Apple and is normally
/// granted to App Store apps, so a personal build may never get one. None of this
/// file needs it. `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` deliver the
/// cover, title, chapter, scrub position, play/pause, skip and steering-wheel
/// controls on the CarPlay Now Playing screen with no entitlement at all.
///
/// What the entitlement buys is browsing the library on the car screen. Everything
/// else about listening while driving is here.
@MainActor
final class NowPlayingBridge {

    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()

    /// Skip intervals. 30 forward and 15 back is the audiobook convention: you
    /// overshoot forward deliberately and step back precisely.
    static let skipForward: TimeInterval = 30
    static let skipBackward: TimeInterval = 15

    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var skipForward: (TimeInterval) -> Void
        var skipBackward: (TimeInterval) -> Void
        var nextChapter: () -> Void
        var previousChapter: () -> Void
        var seek: (TimeInterval) -> Void
        var changeRate: (Float) -> Void
    }

    func activate(with handlers: Handlers) {
        let center = commandCenter

        center.playCommand.isEnabled = true
        center.playCommand.addTarget { _ in handlers.play(); return .success }

        center.pauseCommand.isEnabled = true
        center.pauseCommand.addTarget { _ in handlers.pause(); return .success }

        center.togglePlayPauseCommand.isEnabled = true

        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipForward)]
        center.skipForwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipForward
            handlers.skipForward(interval)
            return .success
        }

        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipBackward)]
        center.skipBackwardCommand.addTarget { event in
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? Self.skipBackward
            handlers.skipBackward(interval)
            return .success
        }

        // Steering-wheel next/previous map to chapters, not to "next book" —
        // skipping to another book by accident while driving is a bad surprise.
        center.nextTrackCommand.isEnabled = true
        center.nextTrackCommand.addTarget { _ in handlers.nextChapter(); return .success }

        center.previousTrackCommand.isEnabled = true
        center.previousTrackCommand.addTarget { _ in handlers.previousChapter(); return .success }

        center.changePlaybackPositionCommand.isEnabled = true
        center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            handlers.seek(event.positionTime)
            return .success
        }

        center.changePlaybackRateCommand.isEnabled = true
        center.changePlaybackRateCommand.supportedPlaybackRates =
            [0.75, 1.0, 1.25, 1.5, 1.75, 2.0].map(NSNumber.init(value:))
        center.changePlaybackRateCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackRateCommandEvent else {
                return .commandFailed
            }
            handlers.changeRate(event.playbackRate)
            return .success
        }
    }

    struct State {
        var title: String
        var author: String
        var chapterTitle: String?
        var offset: TimeInterval
        var duration: TimeInterval
        var rate: Float
        var isPlaying: Bool
        var artwork: UIImage?
        /// Books on a private shelf show a neutral placeholder on shared screens.
        var isPrivate: Bool
    }

    /// Push current state out to every external surface.
    func update(_ state: State) {
        var info: [String: Any] = [:]

        // On a private book, the car's screen, the lock screen and any connected
        // display all show the same neutral text. Nothing about it is secret from
        // the owner, but it is not announced to a passenger either.
        let title = state.isPrivate ? "Audiobook" : state.title
        let author = state.isPrivate ? "" : state.author

        info[MPMediaItemPropertyTitle] = state.chapterTitle.map { chapter in
            state.isPrivate ? title : chapter
        } ?? title
        info[MPMediaItemPropertyAlbumTitle] = title
        info[MPMediaItemPropertyArtist] = author
        info[MPMediaItemPropertyPlaybackDuration] = state.duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.offset
        info[MPNowPlayingInfoPropertyPlaybackRate] = state.isPlaying ? state.rate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = state.rate
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        info[MPNowPlayingInfoPropertyIsLiveStream] = false

        if !state.isPrivate, let artwork = state.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: artwork.size
            ) { _ in artwork }
        }

        infoCenter.nowPlayingInfo = info
        infoCenter.playbackState = state.isPlaying ? .playing : .paused
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
        infoCenter.playbackState = .stopped
    }
}
