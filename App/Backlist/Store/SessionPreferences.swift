import Foundation

/// Settings that deliberately last only until the app quits.
@MainActor
final class SessionPreferences: ObservableObject {
    /// Reveals private books in the lists. Never persisted: it should not be a
    /// state you can forget you left on, for someone else to find later. Widgets,
    /// CarPlay, Siri and Now Playing ignore it and never show private books.
    @Published var showPrivate = false
}
