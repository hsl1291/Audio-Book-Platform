import SwiftUI
import SwiftData
import BacklistCore

/// Everything known about one work, and every action available on it.
struct BookDetailView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var player: PlayerEngine
    @EnvironmentObject private var playback: PlaybackCoordinator
    @EnvironmentObject private var downloads: DownloadCoordinator

    @Bindable var work: StoredWork
    @State private var isEditingReview = false

    private var playableCopy: StoredCopy? {
        (work.copies ?? []).first(where: \.isPlayable)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header

                if let copy = playableCopy {
                    playControls
                    downloadRow(copy)
                    if let message = playback.lastError ?? downloads.status.lastError {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

    /// Where the file is, and the one action that makes sense for that state.
    @ViewBuilder
    private func downloadRow(_ copy: StoredCopy) -> some View {
        HStack(spacing: 10) {
            AvailabilityBadge(availability: copy.availability)
            switch copy.availability {
            case .downloaded:
                Text(copy.isPinned ? "On this iPhone, kept" : "On this iPhone")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if copy.identifier != playback.currentCopyID {
                    Button("Remove from iPhone", role: .destructive) {
                        downloads.removeDownload(work)
                    }
                    .font(.footnote)
                }
            case .partial:
                Text(playback.waitingFor == work.title
                     ? "Downloading — will play when ready"
                     : "Downloading…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if playback.waitingFor == work.title {
                    Button("Don't auto-play") { playback.cancelWaiting() }
                        .font(.footnote)
                }
            case .cloudOnly:
                Text("In the cloud")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Download") { downloads.download(work) }
                    .font(.footnote)
            case .notAFile:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                                .foregroundStyle((work.rating ?? 0) >= star ? Color.yellow : Color.secondary.opacity(0.4))
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
            set: { keep in
                copy.isPinned = keep
                try? context.save()
                // Keeping a book is a request to have it here, not just a promise
                // not to remove it.
                if keep && copy.availability == .cloudOnly { downloads.download(work) }
            }
        )
    }

    private func markFinished() throws {
        try LibraryStore(context: context).markFinished(work)
        downloads.refresh()
    }

    private func startPlayback() async {
        await playback.play(work)
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
