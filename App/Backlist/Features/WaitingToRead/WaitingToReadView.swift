import SwiftUI
import SwiftData
import BacklistCore

/// The default landing screen: a cover grid of everything owned and unfinished.
///
/// The rule is the one the user stated directly — a book shows here if you have a
/// copy of it, and it leaves the moment it is marked finished.
struct WaitingToReadView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var session: SessionPreferences

    @Query(sort: \StoredWork.addedAt, order: .reverse)
    private var works: [StoredWork]

    @State private var searchText = ""
    @AppStorage("waitingFormatFilter") private var format: FormatFilter = .all

    enum FormatFilter: String, CaseIterable, Identifiable {
        case all = "All", audio = "Audio", kindle = "Kindle"
        var id: Self { self }
    }

    private var waiting: [StoredWork] {
        works
            .filter(\.isWaitingToRead)
            .filter { !$0.isPrivate || session.showPrivate }
            .filter { matches($0, searchText) }
            .filter { work in
                switch format {
                case .all: return true
                case .audio: return work.hasPlayableCopy
                case .kindle: return work.kindleASIN != nil
                }
            }
    }

    /// Chips appear only once there is something to tell apart.
    private var hasKindleBooks: Bool {
        works.contains { $0.isWaitingToRead && $0.kindleASIN != nil }
    }

    private var continueReading: StoredWork? {
        // Only audiobooks: a Kindle book being read cannot be resumed from here.
        works.first { $0.shelf == .reading && !$0.isPrivate && $0.hasPlayableCopy }
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let continueReading {
                    Button {
                        Task { await playback.play(continueReading) }
                    } label: {
                        ContinueCard(work: continueReading)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if hasKindleBooks {
                    Picker("Format", selection: $format) {
                        ForEach(FormatFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                if waiting.isEmpty {
                    EmptyLibraryView()
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(waiting) { work in
                            NavigationLink(value: work.identifier) {
                                BookTile(work: work)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Waiting to Read")
            .searchable(text: $searchText, prompt: "Title or author")
            .navigationDestination(for: UUID.self) { id in
                if let work = works.first(where: { $0.identifier == id }) {
                    BookDetailView(work: work)
                }
            }
        }
    }

    private func matches(_ work: StoredWork, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        let needle = MatchKey.normalise(query)
        if MatchKey.normalise(work.title).contains(needle) { return true }
        return work.authors.contains { MatchKey.normalise($0).contains(needle) }
    }
}

/// One cover in the grid, with the availability badge that keeps offline state
/// from ever being a surprise.
struct BookTile: View {
    let work: StoredWork

    private var availability: LocalAvailability {
        let copies = work.copies ?? []
        if copies.contains(where: { $0.availability == .downloaded }) { return .downloaded }
        if copies.contains(where: { $0.availability == .partial }) { return .partial }
        if copies.contains(where: \.isPlayable) { return .cloudOnly }
        return .notAFile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CoverView(work: work)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .bottomTrailing) {
                    AvailabilityBadge(availability: availability)
                        .padding(6)
                }
                .overlay(alignment: .topLeading) {
                    if work.kindleASIN != nil {
                        Image(systemName: "book.closed.fill")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.orange, in: RoundedRectangle(cornerRadius: 4))
                            .padding(6)
                            .accessibilityLabel("Kindle")
                    }
                }

            Text(work.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundStyle(.primary)

            if let author = work.authors.first {
                Text(author)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

struct AvailabilityBadge: View {
    let availability: LocalAvailability

    var body: some View {
        switch availability {
        case .downloaded:
            symbol("arrow.down.circle.fill", .green)
        case .partial:
            symbol("arrow.down.circle", .orange)
        case .cloudOnly:
            symbol("icloud", .secondary)
        case .notAFile:
            EmptyView()
        }
    }

    private func symbol(_ name: String, _ tint: some ShapeStyle) -> some View {
        Image(systemName: name)
            .font(.caption)
            .foregroundStyle(tint)
            .padding(3)
            .background(.ultraThinMaterial, in: Circle())
    }
}

/// The one-tap resume card at the top of the grid.
struct ContinueCard: View {
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var playback: PlaybackCoordinator
    let work: StoredWork

    private var copy: StoredCopy? {
        (work.copies ?? []).first(where: \.isPlayable)
    }

    private var progress: Double {
        guard let copy, let duration = copy.duration, duration > 0 else { return 0 }
        return min(1, copy.positionOffset / duration)
    }

    var body: some View {
        HStack(spacing: 14) {
            CoverView(work: work)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(playback.waitingFor == work.title ? "Downloading…" : "Continue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(work.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                ProgressView(value: progress)
                    .tint(.accentColor)
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct EmptyLibraryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Nothing here yet", systemImage: "books.vertical")
        } description: {
            Text("Connect a folder in Settings, or import your Goodreads export to bring in what you have already read.")
        }
    }
}
