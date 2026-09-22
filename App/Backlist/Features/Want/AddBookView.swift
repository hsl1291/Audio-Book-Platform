import SwiftUI
import SwiftData
import BacklistCore

/// Put a book on the Want list by hand.
///
/// Goodreads is imported as reading history only, so this is the one way a book
/// you do not yet own gets onto the shopping list.
struct AddBookView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var author = ""

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespaces) }
    private var trimmedAuthor: String { author.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                    .textInputAutocapitalization(.words)
                TextField("Author", text: $author)
                    .textInputAutocapitalization(.words)
            }
            .navigationTitle("Want to read")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(trimmedTitle.isEmpty)
                }
            }
        }
    }

    private func add() {
        let key = MatchKey(title: trimmedTitle, author: trimmedAuthor.isEmpty ? nil : trimmedAuthor)
        let store = LibraryStore(context: context)

        // Already in the library -- owned, read, or wanted -- adds nothing new.
        if let existing = try? store.findWork(asin: nil, isbn13: nil, matchKey: key) {
            if existing.shelf != .finished, (existing.copies ?? []).isEmpty {
                existing.shelf = .want
                existing.intent = .needToPurchase
                try? context.save()
            }
            dismiss()
            return
        }

        let work = StoredWork(title: trimmedTitle)
        if !trimmedAuthor.isEmpty { work.authors = [trimmedAuthor] }
        work.shelf = .want
        work.intent = .needToPurchase
        context.insert(work)
        try? context.save()
        dismiss()
    }
}
