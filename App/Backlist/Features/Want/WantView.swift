import SwiftUI
import SwiftData
import BacklistCore

/// The shopping list: works you want and hold no copy of.
///
/// Deliberately store-agnostic. It tells you what to buy, not where — which keeps
/// it useful whichever store you are buying from this month.
struct WantView: View {
    @Environment(\.modelContext) private var context

    @Query(sort: \StoredWork.addedAt, order: .reverse)
    private var works: [StoredWork]

    private var needToBuy: [StoredWork] {
        works.filter { $0.shelf == .want && !$0.hasPlayableCopy && !$0.isPrivate }
    }

    private var owned: [StoredWork] {
        works.filter { $0.shelf == .want && $0.hasPlayableCopy && !$0.isPrivate }
    }

    var body: some View {
        NavigationStack {
            List {
                if !owned.isEmpty {
                    Section {
                        ForEach(owned) { work in
                            NavigationLink(value: work.identifier) {
                                WantRow(work: work, alreadyOwned: true)
                            }
                        }
                    } header: {
                        Text("Already yours")
                    } footer: {
                        Text("Wanted, and a file turned up for it. Nothing to buy.")
                    }
                }

                Section("Need to buy") {
                    if needToBuy.isEmpty {
                        Text("Nothing on the list.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(needToBuy) { work in
                        NavigationLink(value: work.identifier) {
                            WantRow(work: work, alreadyOwned: false)
                        }
                    }
                    .onDelete(perform: remove)
                }
            }
            .navigationTitle("Want")
            .navigationDestination(for: UUID.self) { id in
                if let work = works.first(where: { $0.identifier == id }) {
                    BookDetailView(work: work)
                }
            }
        }
    }

    private func remove(_ offsets: IndexSet) {
        for index in offsets {
            context.delete(needToBuy[index])
        }
        try? context.save()
    }
}

struct WantRow: View {
    let work: StoredWork
    let alreadyOwned: Bool

    var body: some View {
        HStack(spacing: 12) {
            CoverView(work: work)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading, spacing: 2) {
                Text(work.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let author = work.authors.first {
                    Text(author)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            if alreadyOwned {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
    }
}
