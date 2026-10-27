import Foundation
import Observation
import FeedingCore

@MainActor @Observable final class SharedHistoryController {
    private weak var store: FeedingStore?
    @ObservationIgnored private var config: PrivateHistoryConfiguration?
    @ObservationIgnored private let transport = PrivateHistoryTransport()
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var requestedAgain = false
    private let defaults = UserDefaults.standard
    private(set) var configured = false
    private(set) var enabled = UserDefaults.standard.bool(forKey: "privateHistoryEnabled")
    private(set) var busy = false
    private(set) var status = "Feeds are saved on this phone. Shared history is not enabled."
    private(set) var lastTransfer: Date?

    init(store: FeedingStore) {
        self.store = store; store.sharedHistory = self
        do {
            // Provisioned by the paired Mac at launch, never bundled or included in a backup export.
            if let encoded = ProcessInfo.processInfo.environment["FELIX_PRIVATE_HISTORY_SETUP"],
               let data = Data(base64Encoded: encoded) {
                let incoming = try JSONDecoder().decode(PrivateHistoryConfiguration.self, from: data)
                try incoming.validate()
                if let existing = try PrivateHistoryKeychain.load(), existing.historyID != incoming.historyID {
                    throw FeedingError.invalid("This phone is paired with a different history. Its keys have been kept.")
                }
                try PrivateHistoryKeychain.save(incoming)
            }
            try loadConfiguration()
        } catch { status = error.localizedDescription }
    }
    private func loadConfiguration() throws {
        config = try PrivateHistoryKeychain.load(); configured = config != nil
        if !enabled {
            status = configured ? "This phone is paired. Enable sharing to merge its feeds with your family history."
                : "Connect this iPhone to the setup Mac to pair it with your family history."
        }
    }
    func startIfEnabled() {
        do { if config == nil { try loadConfiguration() } }
        catch { status = error.localizedDescription; return }
        guard enabled else { return }
        refresh()
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                guard let self else { return }
                self.refresh()
            }
        }
    }
    func suspend() {
        polling?.cancel(); polling = nil
        work?.cancel()
    }
    func localRecordsChanged() { refresh() }
    func refresh() {
        guard enabled else { return }
        guard !busy else { requestedAgain = true; return }
        busy = true
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil }
            repeat {
                self.requestedAgain = false
                do { try await self.sync() }
                catch is CancellationError { return }
                catch {
                    if self.enabled { self.status = L10n.format("Saved on this phone. Sync will retry: %@", error.localizedDescription) }
                    return
                }
            } while self.requestedAgain && self.enabled && !Task.isCancelled
        }
    }
    func beginSharing() async {
        guard let store, !store.loadFailed, !busy else { return }
        do {
            try loadConfiguration()
            guard let config else { throw FeedingError.invalid("Pair this phone with the setup Mac first.") }
            guard store.ledger.sharedHistoryID == nil || store.ledger.sharedHistoryID == config.historyID else {
                throw FeedingError.invalid("This phone's records belong to a different shared history.")
            }
            if store.ledger.sharedHistoryID == nil { try store.backupBeforeJoining() }
            try store.prepareSharedSeed()
            try store.attachSharedHistory(id: config.historyID, replacingFeeds: nil)
            enabled = true; defaults.set(true, forKey: "privateHistoryEnabled")
            startIfEnabled()
        } catch { status = L10n.format("Could not enable sharing: %@. Your records are kept.", error.localizedDescription) }
    }
    func pauseSyncing() {
        enabled = false; defaults.set(false, forKey: "privateHistoryEnabled")
        suspend(); requestedAgain = false
        status = "Syncing is paused on this phone. Your local copy is kept."
    }
    private func checkActive() throws {
        try Task.checkCancellation()
        guard enabled else { throw CancellationError() }
    }
    private func sync() async throws {
        guard let store, !store.loadFailed, let config else {
            throw FeedingError.invalid("Unlock this phone and check its private sync setup.")
        }
        guard store.ledger.sharedHistoryID == config.historyID else {
            throw FeedingError.invalid("The local history and pairing do not match. No feeds were uploaded.")
        }
        // Pull and authenticate the whole remote batch before changing the local ledger.
        var remote: [Feed] = [], revisions: [String: FeedRevision] = [:]
        var cursor: String?, seen = Set<String>()
        repeat {
            try checkActive()
            let page = try await transport.exchange([], cursor: cursor, config: config)
            for packet in page.records {
                let feed = try packet.open(key: config.key)
                remote.append(feed); revisions[packet.id] = packet.revision
            }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw FeedingError.invalid("The service repeated a history page.") }
        } while cursor != nil
        try checkActive()
        try store.receiveSharedFeeds(remote)
        // The JSON ledger is the durable outbox, including deletions. Failed uploads retry safely.
        let pending = store.ledger.feeds.filter { feed in
            guard let local = feed.revision else { return true }
            guard let remote = revisions[feed.id.uuidString.lowercased()] else { return true }
            return local > remote
        }
        for start in stride(from: 0, to: pending.count, by: 10) {
            try checkActive()
            let packets = try pending[start..<min(start + 10, pending.count)].map { try HistoryPacket.seal($0, key: config.key) }
            let result = try await transport.exchange(packets, config: config)
            // Concurrent corrections received in an upload reply are authenticated before merging.
            let incoming = try result.records.map { try $0.open(key: config.key) }
            try checkActive(); try store.receiveSharedFeeds(incoming)
        }
        try await syncHungerCues(config: config, store: store)
        var pumpingShared = true
        do { try await syncPumpSessions(config: config, store: store) }
        catch is PumpingSyncUnavailable { pumpingShared = false }
        lastTransfer = Date()
        status = pumpingShared ? "Shared history is up to date. New feeds save offline and sync while the app is open."
            : "Feeds and observations are up to date. Pumping sessions stay on this phone until the private service is updated."
    }
    private func syncHungerCues(config: PrivateHistoryConfiguration, store: FeedingStore) async throws {
        var remote: [HungerCue] = [], revisions: [String: FeedRevision] = [:]
        var cursor: String?, seen = Set<String>()
        repeat {
            try checkActive()
            let page = try await transport.exchange([], cursor: cursor, config: config, collection: .observations)
            for packet in page.records {
                remote.append(try packet.openHungerCue(key: config.key)); revisions[packet.id] = packet.revision
            }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw FeedingError.invalid("The service repeated a history page.") }
        } while cursor != nil
        try checkActive(); try store.receiveSharedHungerCues(remote)
        let pending = store.ledger.hungerCues.filter { cue in
            guard let local = cue.revision, let remote = revisions[cue.id.uuidString.lowercased()] else { return true }
            return local > remote
        }
        for start in stride(from: 0, to: pending.count, by: 10) {
            try checkActive()
            let packets = try pending[start..<min(start + 10, pending.count)].map { try HistoryPacket.seal($0, key: config.key) }
            let reply = try await transport.exchange(packets, config: config, collection: .observations)
            let incoming = try reply.records.map { try $0.openHungerCue(key: config.key) }
            try checkActive(); try store.receiveSharedHungerCues(incoming)
        }
    }
    private func syncPumpSessions(config: PrivateHistoryConfiguration, store: FeedingStore) async throws {
        var remote: [PumpSession] = [], revisions: [String: FeedRevision] = [:]
        var cursor: String?, seen = Set<String>()
        repeat {
            try checkActive()
            let page = try await transport.exchange([], cursor: cursor, config: config, collection: .pumping)
            for packet in page.records {
                remote.append(try packet.openPumpSession(key: config.key)); revisions[packet.id] = packet.revision
            }
            cursor = page.nextCursor
            if let cursor, !seen.insert(cursor).inserted { throw FeedingError.invalid("The service repeated a history page.") }
        } while cursor != nil
        try checkActive(); try store.receiveSharedPumpSessions(remote)
        let pending = store.ledger.pumpSessions.filter { session in
            guard let local = session.revision, let remote = revisions[session.id.uuidString.lowercased()] else { return true }
            return local > remote
        }
        for start in stride(from: 0, to: pending.count, by: 10) {
            try checkActive()
            let packets = try pending[start..<min(start + 10, pending.count)].map { try HistoryPacket.seal($0, key: config.key) }
            let reply = try await transport.exchange(packets, config: config, collection: .pumping)
            let incoming = try reply.records.map { try $0.openPumpSession(key: config.key) }
            try checkActive(); try store.receiveSharedPumpSessions(incoming)
        }
    }

}
