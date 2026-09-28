import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import BacklistCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @EnvironmentObject private var downloads: DownloadCoordinator

    @AppStorage("storageBudgetGB") private var budgetGB: Double = 15
    @AppStorage("autoDownloadCount") private var autoDownloadCount: Int = 3
    @AppStorage("finishedGraceDays") private var finishedGraceDays: Int = 7
    @AppStorage("requiresWiFi") private var requiresWiFi = true
    @AppStorage("requiresCharging") private var requiresCharging = false

    @State private var importingCSV = false
    @State private var importingKindle = false
    @State private var choosingFolder = false
    @State private var status: String?
    @State private var scanReport: LibraryStore.ScanReport?

    var body: some View {
        NavigationStack {
            Form {
                librarySection
                storageSection
                importSection

                if let status {
                    Section {
                        Text(status).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    // MARK: - Sections

    private var librarySection: some View {
        Section {
            Button {
                choosingFolder = true
            } label: {
                Label("Choose books folder", systemImage: "folder")
            }
            // One importer per button: SwiftUI honours only the last
            // `.fileImporter` on a given view, which silently disabled the other.
            .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) {
                handleFolder($0)
            }

            if let scanReport {
                LabeledContent("Files found", value: "\(scanReport.discovered)")
                LabeledContent("Books", value: "\(scanReport.newWorks + scanReport.attachedToExisting)")
                if scanReport.duplicateGroups > 0 {
                    LabeledContent("Duplicates") {
                        Text(
                            ByteCountFormatter.string(
                                fromByteCount: scanReport.reclaimableBytes, countStyle: .file
                            ) + " reclaimable"
                        )
                        .foregroundStyle(.orange)
                    }
                }
            }
        } header: {
            Text("Library")
        } footer: {
            Text("Any folder of audio files works. Backlist reads what is there and does not care which store the files came from.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("On this iPhone") {
                Text(ByteCountFormatter.string(
                    fromByteCount: downloads.status.onDeviceBytes, countStyle: .file
                ))
            }
            if downloads.status.downloading > 0 {
                LabeledContent("Downloading", value: "\(downloads.status.downloading)")
            }
            if downloads.status.overBudgetBy > 0 {
                Text("Books you chose to keep use \(ByteCountFormatter.string(fromByteCount: downloads.status.overBudgetBy, countStyle: .file)) more than the limit. Backlist won't remove them — un-keep some, or raise the limit.")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading) {
                LabeledContent("Keep at most", value: "\(Int(budgetGB)) GB")
                // Re-plan when the drag ends, not on every step of it.
                Slider(value: $budgetGB, in: 2...200, step: 1) { editing in
                    if !editing { downloads.refresh() }
                }
            }

            Stepper("Pre-download \(autoDownloadCount) ahead", value: $autoDownloadCount, in: 0...10)
            Stepper(
                "Keep finished for \(finishedGraceDays) days",
                value: $finishedGraceDays, in: 0...90
            )

            Toggle("Wi-Fi only", isOn: $requiresWiFi)
            Toggle("Only while charging", isOn: $requiresCharging)
        } header: {
            Text("Storage")
        } footer: {
            Text("Backlist keeps your next books downloaded and releases finished ones, asking the folder's cloud service (iCloud Drive, Google Drive and others in Files) to fetch or free them. Removing a download never deletes the book or loses your place. Files stored only on this iPhone are never touched.")
        }
        .onChange(of: autoDownloadCount) { _, _ in downloads.refresh() }
        .onChange(of: finishedGraceDays) { _, _ in downloads.refresh() }
        .onChange(of: requiresWiFi) { _, _ in downloads.refresh() }
        .onChange(of: requiresCharging) { _, _ in downloads.refresh() }
    }

    private var importSection: some View {
        Section {
            Button {
                importingCSV = true
            } label: {
                Label("Import Goodreads export", systemImage: "square.and.arrow.down")
            }
            .fileImporter(
                isPresented: $importingCSV,
                allowedContentTypes: [.commaSeparatedText, .plainText]
            ) {
                handleCSV($0)
            }

            Button {
                importingKindle = true
            } label: {
                Label("Import Kindle books", systemImage: "book.closed")
            }
            .fileImporter(
                isPresented: $importingKindle,
                allowedContentTypes: [.commaSeparatedText, .json, .plainText],
                allowsMultipleSelection: true
            ) {
                handleKindle($0)
            }
        } header: {
            Text("Import")
        } footer: {
            Text("Goodreads fills the Read tab with everything you've finished, including your ratings and reviews; only your Read shelf is imported (My Books → Import and export → Export Library). Kindle books come from Amazon's data export (Account → Request Your Data → Kindle); choose any of its CSV or JSON files and Backlist keeps the ones that list books. Run either again any time — nothing is duplicated.")
        }
    }

    // MARK: - Actions

    private func handleCSV(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let text = try String(contentsOf: url, encoding: .utf8)
            let store = LibraryStore(context: context)
            let summary = try store.importGoodreads(csv: text)
            let merged = try store.reconcile()
            AppServices.shared.covers.run()
            let history = summary.readHistory
            status = """
                Added \(history.count) books you've read, \
                \(history.filter { $0.journal.isRated }.count) with ratings and \
                \(history.filter { $0.journal.hasReview }.count) with reviews. \
                \(merged) matched audiobooks already in your library. \
                \(summary.notRead) to-read or current rows were left out.
                """
        } catch {
            status = "Import failed: \(error.localizedDescription)"
        }
    }

    private func handleKindle(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var summaries: [KindleImporter.Summary] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                summaries.append(KindleImporter.import(try Data(contentsOf: url)))
            }
            let merged = KindleImporter.merge(summaries)
            guard !merged.books.isEmpty else {
                status = "No Kindle books found in \(urls.count == 1 ? "that file" : "those files"). Try the files in the Kindle or Digital Orders folders of the export."
                return
            }
            let store = LibraryStore(context: context)
            let report = try store.importKindle(merged.books)
            try store.reconcile()
            AppServices.shared.covers.run()
            status = """
                Found \(merged.books.count) Kindle books: \(report.added) new, \
                \(report.attachedToExisting) matched to books already here, \
                \(report.alreadyKnown) already imported.
                """
        } catch {
            status = "Kindle import failed: \(error.localizedDescription)"
        }
    }

    private func handleFolder(_ result: Result<URL, Error>) {
        Task {
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }

                // The bookmark is what survives relaunch; without it the folder
                // must be re-picked every cold start, and nothing in it can play.
                try LibraryFolder.remember(url)

                let store = LibraryStore(context: context)
                let report = try await store.scan(source: LocalFilesSource(root: url))
                scanReport = report
                status = "Scanned \(report.discovered) files. Reading covers and authors…"

                // Authors come from the files' own tags, and reconciliation with
                // Goodreads needs them, so enrichment has to run first.
                let enriched = await MetadataEnricher.run(context: context, root: url)
                let merged = try store.reconcile()
                let pending = enriched.notYetLocal > 0
                    ? " \(enriched.notYetLocal) are still in the cloud and will fill in once downloaded."
                    : ""
                status = """
                    Scanned \(report.discovered) files into \
                    \(report.newWorks + report.attachedToExisting) books; \
                    read details from \(enriched.enriched), matched \(merged) to your \
                    Goodreads history.\(pending)
                    """
                downloads.refresh()
            } catch {
                status = "Scan failed: \(error.localizedDescription)"
            }
        }
    }
}
