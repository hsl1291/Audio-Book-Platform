import SwiftUI
import SwiftData
import BacklistCore

@main
struct BacklistApp: App {

    /// CloudKit-backed private store. Only the tracking graph syncs — audio files
    /// stay on each device, which is what keeps a 41 GB library inside a free tier.
    private let container: ModelContainer = {
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
    }()

    @StateObject private var player = PlayerEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(player)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlayerEngine
    @State private var selection: Tab = .waiting

    enum Tab: Hashable {
        case waiting, want, read, settings
    }

    var body: some View {
        TabView(selection: $selection) {
            WaitingToReadView()
                .tabItem { Label("Waiting", systemImage: "books.vertical") }
                .tag(Tab.waiting)

            WantView()
                .tabItem { Label("Want", systemImage: "cart") }
                .tag(Tab.want)

            ReadView()
                .tabItem { Label("Read", systemImage: "checkmark.circle") }
                .tag(Tab.read)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(Tab.settings)
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentCopyID != nil {
                MiniPlayerBar()
            }
        }
    }
}
