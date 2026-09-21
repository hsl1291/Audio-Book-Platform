import SwiftUI
import SwiftData
import BacklistCore

/// Everything known about one work, and every action available on it.
struct BookDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlayerEngine

    @Bindable var work: StoredWork
    @State private var isEditingReview = false

    private var playableCopy: StoredCopy? {
        (work.copies ?? []).first(where: \.isPlayable)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                if playableCopy != nil {
                    playControls
                }

                shelfPicker
                ratingSection

                if !(work.copies ?? []).isEmpty {
                    copiesSection
                }

                if let summary = work.summary, !summary.isEmpty {
                    section("Description") {
                        Text(summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(work.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                Toggle("Private", isOn: $work.isPrivate)
                if let copy = playableCopy {
                    Toggle("Keep downloaded", isOn: bindingForPin(copy))
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 12) {
            CoverView(work: work)
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(radius: 8, y: 4)

            Text(work.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            if !work.authors.isEmpty {
                Text(work.authors.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let narrator = work.narrators.first {
                Text("Narrated by \(narrator)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var playControls: some View {
        HStack(spacing: 12) {
            Button {
                Task { await startPlayback() }
            } label: {
                Label(
                    playableCopy?.positionOffset ?? 0 > 0 ? "Resume" : "Play",
                    systemImage: "play.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)

            Button {
                try? markFinished()
            } label: {
                Label("Finished", systemImage: "checkmark")
            }
            .buttonStyle(.bordered)
        }
    }

    private var shelfPicker: some View {
        Picker("Shelf", selection: shelfBinding) {
            Text("Want").tag(Shelf.want)
            Text("Owned").tag(Shelf.owned)
            Text("Reading").tag(Shelf.reading)
            Text("Read").tag(Shelf.finished)
            Text("Gave up").tag(Shelf.abandoned)
        }
        .pickerStyle(.segmented)
    }

    private var ratingSection: some View {
        section("Your review") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            // Tapping the current rating clears it, since "unrated"
                            // is a real state and most imported books are in it.
                            work.rating = (work.rating == star) ? nil : star
                            try? context.save()
                        } label: {
                            Image(systemName: (work.rating ?? 0) >= star ? "star.fill" : "star")
                                .font(.title3)
                                .foregroundStyle((work.rating ?? 0) >= star ? .yellow : .quaternary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                TextEditor(text: Binding(
                    get: { work.review ?? "" },
                    set: { work.review = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 90)
                .overlay(alignment: .topLeading) {
                    if (work.review ?? "").isEmpty {
                        Text("What did you think?")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .onChange(of: work.review) { _, _ in try? context.save() }
            }
        }
    }

    private var copiesSection: some View {
        section("Copies") {
            ForEach(work.copies ?? []) { copy in
                HStack {
                    Image(systemName: icon(for: copy))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label(for: copy)).font(.subheadline)
                        if let bytes = copy.byteCount {
                            Text(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    AvailabilityBadge(availability: copy.isPlayable ? copy.availability : .notAFile)
                }
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private var shelfBinding: Binding<Shelf> {
        Binding(
            get: { work.shelf },
            set: { newValue in
                if newValue == .finished {
                    try? markFinished()
                } else {
                    work.shelf = newValue
                    try? context.save()
                }
            }
        )
    }

    private func bindingForPin(_ copy: StoredCopy) -> Binding<Bool> {
        Binding(
            get: { copy.isPinned },
            set: { copy.isPinned = $0; try? context.save() }
        )
    }

    private func markFinished() throws {
        try LibraryStore(context: context).markFinished(work)
    }

    private func startPlayback() async {
        guard let copy = playableCopy, case .localFile(let path)? = copy.sourceRef else {
            return
        }
        let url = URL(fileURLWithPath: path)
        await player.load(
            copyID: copy.identifier,
            url: url,
            startingAt: copy.positionOffset,
            rate: Float(copy.playbackRate)
        )
        player.play()
        try? LibraryStore(context: context).markReading(work)
    }

    private func icon(for copy: StoredCopy) -> String {
        switch copy.format {
        case .audiobook: return "headphones"
        case .ebook: return "book"
        case .physical: return "books.vertical"
        }
    }

    private func label(for copy: StoredCopy) -> String {
        switch copy.provenance {
        case .audioFile: return "Audiobook"
        case .kindle: return "Kindle"
        case .physicalOwned: return "Physical"
        case .library: return "Library"
        case .none: return "Tracked"
        }
    }
}
