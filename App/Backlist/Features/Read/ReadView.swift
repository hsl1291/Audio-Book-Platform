import SwiftUI
import SwiftData
import BacklistCore

/// Reading history, with ratings and reviews.
///
/// Includes works with no file at all — a book you finished before you started
/// keeping the audio is still a book you read, and the Goodreads import brings in
/// roughly fifty of those.
struct ReadView: View {
    @Query private var works: [StoredWork]
    @EnvironmentObject private var session: SessionPreferences
    @State private var sort: SortOrder = .finishedDescending
    @State private var searchText = ""

    enum SortOrder: String, CaseIterable, Identifiable {
        case finishedDescending = "Recently finished"
        case titleAscending = "Title"
        case ratingDescending = "Rating"
        var id: String { rawValue }
    }

    private var finished: [StoredWork] {
        let needle = MatchKey.normalise(searchText)
        let base = works.filter { work in
            guard work.shelf == .finished, !work.isPrivate || session.showPrivate else {
                return false
            }
            guard !needle.isEmpty else { return true }
            return MatchKey.normalise(work.title).contains(needle)
                || work.authors.contains { MatchKey.normalise($0).contains(needle) }
                || MatchKey.normalise(work.review ?? "").contains(needle)
        }
        switch sort {
        case .finishedDescending:
            // Books with no recorded finish date sort last rather than first —
            // most of the imported history has no date, and letting them lead
            // would bury everything actually finished recently.
            return base.sorted {
                ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast)
            }
        case .titleAscending:
            return base.sorted { MatchKey.normalise($0.title) < MatchKey.normalise($1.title) }
        case .ratingDescending:
            return base.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(finished) { work in
                        NavigationLink(value: work.identifier) {
                            ReadRow(work: work)
                        }
                    }
                } header: {
                    Text("\(finished.count) books")
                }
            }
            .navigationTitle("Read")
            .searchable(text: $searchText, prompt: "Title, author or review")
            .toolbar {
                Menu {
                    Picker("Sort", selection: $sort) {
                        ForEach(SortOrder.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let work = works.first(where: { $0.identifier == id }) {
                    BookDetailView(work: work)
                }
            }
        }
    }
}

struct ReadRow: View {
    let work: StoredWork

    var body: some View {
        HStack(spacing: 12) {
            CoverView(work: work)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(work.title).font(.subheadline).lineLimit(2)
                HStack(spacing: 6) {
                    if let author = work.authors.first {
                        Text(author).font(.caption).foregroundStyle(.secondary)
                    }
                    if work.review?.isEmpty == false {
                        Image(systemName: "text.quote")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            if let rating = work.rating {
                StarsView(rating: rating)
            }
        }
    }
}

struct StarsView: View {
    let rating: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .font(.caption2)
                    .foregroundStyle(index <= rating ? Color.yellow : Color.secondary.opacity(0.4))
            }
        }
    }
}
