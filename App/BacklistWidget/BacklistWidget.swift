import WidgetKit
import SwiftUI
import BacklistCore

// The current book on the Home Screen and Lock Screen.
//
// Reads a small snapshot the app writes to the shared App Group container; the
// widget never touches the library itself. Tapping it opens the app and resumes.

struct BookEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    /// Raw bytes rather than an image, so the entry stays a plain value.
    let cover: Data?
}

struct BookProvider: TimelineProvider {

    func placeholder(in context: Context) -> BookEntry {
        BookEntry(
            date: Date(),
            snapshot: WidgetSnapshot(
                title: "Your book", author: "Author", chapterTitle: "Chapter 1",
                offset: 3_600, duration: 36_000, isPlaying: false, hasCover: false
            ),
            cover: nil
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BookEntry) -> Void) {
        completion(Self.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BookEntry>) -> Void) {
        // The app asks for a reload whenever the book or play state changes; this
        // is only a backstop.
        let next = Date().addingTimeInterval(60 * 60)
        completion(Timeline(entries: [Self.current()], policy: .after(next)))
    }

    static func current() -> BookEntry {
        guard let folder = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup
        ) else {
            return BookEntry(date: Date(), snapshot: nil, cover: nil)
        }
        let snapshot = (try? Data(contentsOf: folder.appendingPathComponent(WidgetSnapshot.fileName)))
            .flatMap(WidgetSnapshot.decode)
        let cover = snapshot?.hasCover == true
            ? try? Data(contentsOf: folder.appendingPathComponent(WidgetSnapshot.coverFileName))
            : nil
        return BookEntry(date: Date(), snapshot: snapshot, cover: cover)
    }
}

struct BookWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: BookEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                switch family {
                case .accessoryCircular: circular(snapshot)
                case .accessoryRectangular: rectangular(snapshot)
                case .systemSmall: small(snapshot)
                default: medium(snapshot)
                }
            } else {
                empty
            }
        }
        .widgetURL(WidgetSnapshot.continueURL)
    }

    // MARK: - Families

    private func small(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(snapshot)
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Spacer(minLength: 0)
            Text(snapshot.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            ProgressView(value: snapshot.progress)
            Text(snapshot.remainingText)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func medium(_ snapshot: WidgetSnapshot) -> some View {
        HStack(spacing: 14) {
            cover(snapshot)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.isPlaying ? "Listening" : "Continue")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                if let author = snapshot.author {
                    Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let chapter = snapshot.chapterTitle {
                    Text(chapter).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView(value: snapshot.progress)
                Text(snapshot.remainingText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rectangular(_ snapshot: WidgetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(snapshot.title).font(.headline).lineLimit(1)
            Text(snapshot.remainingText).font(.caption)
            ProgressView(value: snapshot.progress)
        }
    }

    private func circular(_ snapshot: WidgetSnapshot) -> some View {
        Gauge(value: snapshot.progress) {
            Image(systemName: "headphones")
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical")
                .font(.title2)
            Text("Nothing playing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func cover(_ snapshot: WidgetSnapshot) -> some View {
        if let data = entry.cover, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Color.accentColor.opacity(0.3)
                Image(systemName: "headphones").foregroundStyle(.white)
            }
        }
    }
}

struct BacklistWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CurrentBook", provider: BookProvider()) { entry in
            BookWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Current Book")
        .description("The book you're listening to. Tap to resume.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular,
        ])
    }
}

@main
struct BacklistWidgetBundle: WidgetBundle {
    var body: some Widget {
        BacklistWidget()
    }
}
