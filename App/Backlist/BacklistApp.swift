import SwiftUI
import SwiftData
import BacklistCore

@main
struct BacklistApp: App {

    private let services = AppServices.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services.playback)
                .environmentObject(services.playback.engine)
                .environmentObject(services.downloads)
                .environmentObject(services.session)
        }
        .modelContainer(services.container)
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is when files have most likely changed:
            // new purchases landed, or a download finished in the background.
            if phase == .active {
                services.downloads.refresh()
                services.covers.run()
                // Tells Siri which book titles "Play … in Backlist" can match.
                BacklistShortcuts.updateAppShortcutParameters()
                services.playback.publishWidget()
            }
        }
    }
}

struct RootView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var playback: PlaybackCoordinator
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
        .onOpenURL { url in
            guard url == WidgetSnapshot.continueURL else { return }
            selection = .waiting
            Task { await playback.continueFromWidget() }
        }
        .safeAreaInset(edge: .bottom) {
            if player.currentCopyID != nil {
                MiniPlayerBar()
            }
        }
    }
}
