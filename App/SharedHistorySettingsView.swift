import SwiftUI
import FeedingCore
import UniformTypeIdentifiers

struct SharedHistorySettingsView: View {
    @Environment(SharedHistoryController.self) private var sharing
    @Environment(FeedingStore.self) private var store
    @State private var confirmStart = false
    @State private var confirmPause = false
    @State private var exportFile: ExportFile?
    @State private var exporting = false
    @State private var backupMessage: String?
    var body: some View {
        Form {
            Section {
                Label("One history for both parents", systemImage: "person.2")
                    .font(.headline)
                Text("Either of you can log feeds, correct volumes and restore deleted entries. Both phones keep a local copy for offline use.")
            }
            Section {
                Text(L10n.text(sharing.status)).font(.subheadline)
                if let date = sharing.lastTransfer {
                    LabeledContent("Last successful sync", value: date.formatted(date: .omitted, time: .shortened))
                }
                if sharing.busy { ProgressView("Syncing…") }
                if sharing.enabled {
                    Button("Refresh shared history", systemImage: "arrow.clockwise") { sharing.refresh() }
                    Button("Pause syncing on this phone", role: .destructive) { confirmPause = true }
                } else {
                    Button("Start or resume shared history", systemImage: "arrow.triangle.2.circlepath") { confirmStart = true }
                        .disabled(sharing.busy || store.loadFailed || !sharing.configured)
                }
            } header: { Text("Private family sync") } footer: {
                Text("Pair each iPhone with the setup Mac once. Each phone has its own access key. Enabling sharing merges the saved feeds from both phones; no entries are replaced wholesale.")
            }
            Section("What syncs") {
                Text("Saved feeds, pumping sessions, start and end times, breast durations, bottle and pumped volumes, notes, and deleted/restored entries.")
                Text("An active feeding timer stays on the phone where it was started. It joins the shared history when finished.")
                if ActivityPushController.supportedBuild {
                    Text("Feeds save offline and retry when the app is open. With remote timer updates configured, a saved feed can update the other phone's existing Lock Screen timer while its app is closed. The full history downloads when the app opens. Delivery needs an internet connection and may be delayed by iOS.")
                } else {
                    Text("Feeds save offline and sync while the app is open. Open this app to refresh shared history and the Lock Screen timer after another phone logs a feed.")
                }
            }.font(.subheadline)
            if sharing.enabled && ActivityPushController.supportedBuild {
                Section("Lock Screen updates") {
                    Text(L10n.text(sharing.activityPush.status))
                    Text(L10n.text(sharing.activityPush.deliveryStatus)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Backup before enabling sharing") {
                Button("Export previous phone history", systemImage: "square.and.arrow.up") {
                    do {
                        guard let data = try store.previousHistoryBackup() else {
                            backupMessage = "No previous history backup has been needed on this phone."; return
                        }
                        exportFile = ExportFile(data: data); exporting = true
                    } catch { backupMessage = error.localizedDescription }
                }
                Text("Enabling sharing for the first time keeps a local backup of this phone's previous feeds. You can export it here and use Import backup in Settings to restore records when appropriate.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Shared history")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Enable encrypted family sharing?", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("Enable shared history") { Task { await sharing.beginSharing() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your saved feeds, volumes, notes and deleted entries will merge with the paired family history. Feeds are encrypted on the phone before storage in your private ChatGPT Sites service, hosted on Cloudflare. The service sees record IDs, revisions and connection metadata; paired phones hold the key to read feed contents. A local backup is kept first.")
        }
        .confirmationDialog("Pause syncing on this phone?", isPresented: $confirmPause, titleVisibility: .visible) {
            Button("Pause syncing") { sharing.pauseSyncing() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your local copy is kept. This does not revoke the other phone or delete the shared history. A transfer already in progress may finish.") }
        .fileExporter(isPresented: $exporting, document: exportFile, contentType: .json, defaultFilename: "Feeding-history-before-joining") { result in
            if case .failure(let error) = result { backupMessage = error.localizedDescription }
        }
        .alert("Previous history", isPresented: Binding(get: { backupMessage != nil }, set: { if !$0 { backupMessage = nil } })) {
            Button("OK") { backupMessage = nil }
        } message: { Text(L10n.text(backupMessage ?? "")) }
    }
}
