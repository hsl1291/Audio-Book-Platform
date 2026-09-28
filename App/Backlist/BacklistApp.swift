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
        }
        .modelContainer(services.container)
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is when files have most likely changed:
            // new purchases landed, or a download finished in the background.
            if phase == .active {
                services.downloads.refresh()
                services.covers.run()
            }
        }
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
