import Foundation
import UIKit
import WidgetKit
import BacklistCore

/// Writes what the widget shows into the shared App Group container.
///
/// WidgetKit rations reloads per day. Position is saved every 15 seconds, so
/// reloading on every save would exhaust the budget by mid-morning; instead the
/// snapshot file is rewritten freely and the widget is told to redraw only when
/// something visible changes — the book, play state — or every ten minutes.
@MainActor
final class WidgetPublisher {

    struct State {
        var title: String
        var author: String?
        var chapterTitle: String?
        var offset: TimeInterval
        var duration: TimeInterval
        var rate: Double
        var isPlaying: Bool
        var coverKey: String?
        var isPrivate: Bool
    }

    private var lastTitle: String?
    private var lastPlaying: Bool?
    private var lastReload = Date.distantPast
    private var writtenCoverKey: String?

    private var folder: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup
        )
    }

    func publish(_ state: State?) {
        // No App Group (unsigned simulator build): nothing to share with.
        guard let folder else { return }
        let snapshotURL = folder.appendingPathComponent(WidgetSnapshot.fileName)

        // A private book leaves the widget blank rather than showing its title
        // on the Home Screen and Lock Screen.
        guard let state, !state.isPrivate else {
            try? FileManager.default.removeItem(at: snapshotURL)
            reloadIfChanged(title: nil, isPlaying: false)
            return
        }

        let snapshot = WidgetSnapshot(
            title: state.title,
            author: state.author,
            chapterTitle: state.chapterTitle,
            offset: state.offset,
            duration: state.duration,
            rate: state.rate,
            isPlaying: state.isPlaying,
            hasCover: state.coverKey != nil
        )
        try? snapshot.encoded().write(to: snapshotURL, options: .atomic)

        if state.coverKey != writtenCoverKey {
            writtenCoverKey = state.coverKey
            Task { await writeCover(key: state.coverKey, to: folder) }
        }
        reloadIfChanged(title: state.title, isPlaying: state.isPlaying)
    }

    private func writeCover(key: String?, to folder: URL) async {
        let url = folder.appendingPathComponent(WidgetSnapshot.coverFileName)
        guard let key, let image = await CoverCache.shared.image(forKey: key) else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        // Widgets run under a tight memory limit; a full-size cover can exceed it.
        let side: CGFloat = 400
        let small = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        try? small.jpegData(compressionQuality: 0.8)?.write(to: url, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reloadIfChanged(title: String?, isPlaying: Bool) {
        let changed = title != lastTitle || isPlaying != lastPlaying
        let stale = Date().timeIntervalSince(lastReload) > 10 * 60
        guard changed || stale else { return }
        lastTitle = title
        lastPlaying = isPlaying
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
