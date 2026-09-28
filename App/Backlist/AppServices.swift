import Foundation
import SwiftData

/// The app's long-lived objects, created once.
///
/// SwiftUI views reach these through the environment, but Siri intents and the
/// CarPlay scene run outside any view tree. Both must drive the *same* player the
/// phone screen shows — a second `PlaybackCoordinator` would mean two books playing
/// over each other — so there is exactly one instance, owned here.
@MainActor
final class AppServices {

    static let shared = AppServices()

    let container: ModelContainer
    let playback: PlaybackCoordinator
    let downloads: DownloadCoordinator
    let covers: CoverFetcher

    private init() {
        container = Self.makeContainer()
        playback = PlaybackCoordinator(context: container.mainContext)
        downloads = DownloadCoordinator(context: container.mainContext)
        covers = CoverFetcher(context: container.mainContext)
        playback.downloads = downloads
        downloads.playback = playback
    }

    /// CloudKit-backed private store. Only the tracking graph syncs — audio files
    /// stay on each device, which is what keeps a 41 GB library inside a free tier.
    private static func makeContainer() -> ModelContainer {
        let schema = Schema([StoredWork.self, StoredCopy.self])
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            cloudKitDatabase: .automatic
        )
        do {
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            // A container that cannot open is not recoverable at runtime, and
            // failing quietly here would mean losing positions silently.
            fatalError("Could not open the library store: \(error)")
        }
    }
}
