import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import BacklistCore

struct SettingsView: View {
    @Environment(\.modelContext) private var context

    @AppStorage("storageBudgetGB") private var budgetGB: Double = 15
    @AppStorage("autoDownloadCount") private var autoDownloadCount: Int = 3
    @AppStorage("finishedGraceDays") private var finishedGraceDays: Int = 7
    @AppStorage("requiresWiFi") private var requiresWiFi = true
    @AppStorage("requiresCharging") private var requiresCharging = false

    @State private var importingCSV = false
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
            VStack(alignment: .leading) {
                LabeledContent("Keep at most", value: "\(Int(budgetGB)) GB")
                Slider(value: $budgetGB, in: 2...200, step: 1)
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
            Text("These apply to books streamed from Google Drive, which is not connected yet. For a Files or iCloud Drive folder, iOS decides what stays on the device. Evicting a download never loses your place.")
        }
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
        } header: {
            Text("Import")
        } footer: {
            Text("Goodreads → My Books → Import and export → Export Library. Use the CSV, not a saved copy of the page — only the CSV carries your ratings and reviews.")
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
            status = """
                Imported \(summary.books.count) books \
                (\(summary.finished) read, \(summary.wanted) wanted, \
                \(summary.rated) rated, \(summary.reviewed) with reviews). \
                Matched \(merged) to files already in your library.
                """
        } catch {
            status = "Import failed: \(error.localizedDescription)"
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
                    ? " \(enriched.notYetLocal) are still in iCloud and will fill in once downloaded."
                    : ""
                status = """
                    Scanned \(report.discovered) files into \
                    \(report.newWorks + report.attachedToExisting) books; \
                    read details from \(enriched.enriched), matched \(merged) to your \
                    Goodreads history.\(pending)
                    """
            } catch {
                status = "Scan failed: \(error.localizedDescription)"
            }
        }
    }
}
