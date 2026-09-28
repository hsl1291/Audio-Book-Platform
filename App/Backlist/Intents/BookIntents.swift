import AppIntents
import SwiftData
import BacklistCore

// Siri, Shortcuts, the Action button and CarPlay voice control.
//
// The playback intents adopt `AudioPlaybackIntent`, which lets them run without
// bringing the app to the screen — essential while driving. Every one of them
// goes through `AppServices.shared`, so Siri drives the same player the phone
// shows rather than starting a second one.

// MARK: - Resume

struct ResumeBookIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Resume Book" }
    static var description: IntentDescription {
        IntentDescription("Continue the audiobook you were last listening to.")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let playback = AppServices.shared.playback
        guard let work = playback.mostRecentBook() else {
            return .result(dialog: "You're not in the middle of a book.")
        }
        try await BookIntentSupport.start(work)
        return .result(dialog: BookIntentSupport.dialog(resuming: work))
    }
}

// MARK: - Pause

struct PauseBookIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Pause Book" }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppServices.shared.playback.pause()
        return .result()
    }
}

// MARK: - Play a named book

struct PlayBookIntent: AudioPlaybackIntent {
    static var title: LocalizedStringResource { "Play Book" }
    static var description: IntentDescription {
        IntentDescription("Start or continue a specific audiobook from your library.")
    }

    @Parameter(title: "Book")
    var book: BookEntity

    init() {}

    init(book: BookEntity) {
        self.book = book
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let work = BookIntentSupport.work(id: book.id) else {
            throw BookIntentSupport.Failure.notFound
        }
        try await BookIntentSupport.start(work)
        return .result(dialog: BookIntentSupport.dialog(resuming: work))
    }
}

// MARK: - Entity

/// A book Siri can name. Only playable books still being read or waiting to be
/// read are offered, and private books never are — their titles must not be
/// spoken aloud or appear in Shortcuts.
struct BookEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Book" }
    static var defaultQuery: BookQuery { BookQuery() }

    let id: UUID
    let title: String
    let author: String?

    var displayRepresentation: DisplayRepresentation {
        if let author {
            return DisplayRepresentation(title: "\(title)", subtitle: "\(author)")
        }
        return DisplayRepresentation(title: "\(title)")
    }
}

struct BookQuery: EntityStringQuery {

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [BookEntity] {
        BookIntentSupport.offered().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [BookEntity] {
        let needle = MatchKey.normalise(string)
        guard !needle.isEmpty else { return [] }
        return BookIntentSupport.offered().filter {
            MatchKey.normalise($0.title).contains(needle)
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [BookEntity] {
        BookIntentSupport.offered()
    }
}

// MARK: - Shortcuts

struct BacklistShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ResumeBookIntent(),
            phrases: [
                "Resume my book in \(.applicationName)",
                "Continue my book in \(.applicationName)",
                "Keep listening in \(.applicationName)",
            ],
            shortTitle: "Resume Book",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayBookIntent(),
            phrases: [
                "Play \(\.$book) in \(.applicationName)",
                "Listen to \(\.$book) in \(.applicationName)",
            ],
            shortTitle: "Play Book",
            systemImageName: "book"
        )
        AppShortcut(
            intent: PauseBookIntent(),
            phrases: ["Pause my book in \(.applicationName)"],
            shortTitle: "Pause Book",
            systemImageName: "pause.fill"
        )
    }
}

// MARK: - Shared

@MainActor
enum BookIntentSupport {

    enum Failure: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        case cannotPlay(String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notFound: return "That book isn't in your library."
            case .cannotPlay(let reason): return "\(reason)"
            }
        }
    }

    static func offered() -> [BookEntity] {
        let context = AppServices.shared.container.mainContext
        let works = (try? LibraryStore(context: context).allWorks()) ?? []
        return works
            .filter { $0.isWaitingToRead && $0.hasPlayableCopy && !$0.isPrivate }
            .map { BookEntity(id: $0.identifier, title: $0.title, author: $0.authors.first) }
    }

    static func work(id: UUID) -> StoredWork? {
        let context = AppServices.shared.container.mainContext
        return ((try? LibraryStore(context: context).allWorks()) ?? [])
            .first { $0.identifier == id }
    }

    static func start(_ work: StoredWork) async throws {
        let playback = AppServices.shared.playback
        await playback.play(work)
        if let error = playback.lastError {
            throw Failure.cannotPlay(error)
        }
    }

    /// Siri speaks this aloud, possibly through car speakers with passengers.
    static func dialog(resuming work: StoredWork) -> IntentDialog {
        if AppServices.shared.playback.waitingFor != nil {
            return IntentDialog("Downloading it now. It will start when it's ready.")
        }
        if work.isPrivate {
            return IntentDialog("Resuming your book.")
        }
        return IntentDialog("Resuming \(work.title).")
    }
}
