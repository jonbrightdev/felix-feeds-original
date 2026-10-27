import SwiftUI
import Observation
import FeedingCore
import UniformTypeIdentifiers

@MainActor @Observable final class FeedingStore {
    private(set) var ledger = Ledger()
    var error: String?
    private(set) var loadFailed = false
    private let repository: LedgerRepository
    @ObservationIgnored weak var sharedHistory: SharedHistoryController?
    var joiningSharedHistory = false
    private let deviceID: String = {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: "feedDeviceID") { return id }
        let id = UUID().uuidString; defaults.set(id, forKey: "feedDeviceID"); return id
    }()

    init() {
        let directory = URL.applicationSupportDirectory.appending(path: "FelixFeeds")
        repository = LedgerRepository(url: directory.appending(path: "feedings.json"))
        do { ledger = try repository.load() }
        catch {
            loadFailed = true
            self.error = L10n.format("Your saved data could not be opened. It has been left untouched. Close the app and try again. Details: %@", error.localizedDescription)
        }
    }
    @discardableResult func change(_ mutation: (inout Ledger) throws -> Void) -> Bool {
        guard !loadFailed else {
            error = "Saving is paused because your existing data could not be read. Your file has not been overwritten."
            return false
        }
        guard !joiningSharedHistory else {
            error = "The invited history is still downloading. Wait for it to finish, or pause syncing in Settings to keep using this phone's existing history."
            return false
        }
        do {
            var next = ledger
            try mutation(&next)
            try next.stampFeedChanges(since: ledger, device: deviceID.lowercased())
            try next.stampHungerCueChanges(since: ledger, device: deviceID.lowercased())
            try next.stampPumpSessionChanges(since: ledger, device: deviceID.lowercased())
            try repository.save(next)
            let recordsChanged = next.feeds != ledger.feeds || next.hungerCues != ledger.hungerCues
                || next.pumpSessions != ledger.pumpSessions
            ledger = next
            if recordsChanged { sharedHistory?.localRecordsChanged() }
            return true
        } catch {
            self.error = L10n.format("Could not save: %@", error.localizedDescription)
            return false
        }
    }
    func backup() throws -> Data {
        guard !loadFailed else { throw FeedingError.invalid("The existing data could not be opened. Backup is unavailable.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(ledger)
    }

    func prepareSharedSeed() throws {
        var next = ledger
        var alreadyStamped = ledger
        alreadyStamped.feeds = ledger.feeds.filter { $0.revision != nil }
        alreadyStamped.hungerCues = ledger.hungerCues.filter { $0.revision != nil }
        alreadyStamped.pumpSessions = ledger.pumpSessions.filter { $0.revision != nil }
        try next.stampFeedChanges(since: alreadyStamped, device: deviceID.lowercased())
        try next.stampHungerCueChanges(since: alreadyStamped, device: deviceID.lowercased())
        try next.stampPumpSessionChanges(since: alreadyStamped, device: deviceID.lowercased())
        try repository.save(next); ledger = next
    }
    func receiveSharedFeeds(_ feeds: [Feed]) throws {
        var next = ledger; try next.mergeSharedFeeds(feeds)
        if next != ledger { try repository.save(next); ledger = next }
    }
    func receiveSharedHungerCues(_ cues: [HungerCue]) throws {
        var next = ledger; try next.mergeSharedHungerCues(cues)
        if next != ledger { try repository.save(next); ledger = next }
    }
    func receiveSharedPumpSessions(_ sessions: [PumpSession]) throws {
        var next = ledger; try next.mergeSharedPumpSessions(sessions)
        if next != ledger { try repository.save(next); ledger = next }
    }
    func attachSharedHistory(id: String, replacingFeeds: [Feed]?) throws {
        var next = ledger
        if let replacingFeeds {
            next.feeds = []
            try next.mergeSharedFeeds(replacingFeeds)
        }
        next.sharedHistoryID = id
        try repository.save(next); ledger = next
    }
    func backupBeforeJoining() throws {
        let directory = URL.applicationSupportDirectory.appending(path: "FelixFeeds/BeforeJoining")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try backup().write(to: directory.appending(path: "History-\(UUID().uuidString).json"), options: .atomic)
    }
    func previousHistoryBackup() throws -> Data? {
        let directory = URL.applicationSupportDirectory.appending(path: "FelixFeeds/BeforeJoining")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let latest = try files.sorted {
            try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast >
                $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast
        }.first
        return try latest.map { try Data(contentsOf: $0) }
    }
}

@main struct FelixFeedsApp: App {
    @State private var store: FeedingStore
    @State private var sharing: SharedHistoryController
    @State private var activities = FeedActivityController()
    @AppStorage("appearance") private var appearance = "system"
    init() {
        let store = FeedingStore()
        let sharing = SharedHistoryController(store: store)
        _store = State(initialValue: store)
        _sharing = State(initialValue: sharing)
    }
    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(activities)
                .environment(sharing)
                .tint(Palette.green)
                .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        }
    }
}

struct RootView: View {
    @Environment(FeedingStore.self) private var store
    @Environment(FeedActivityController.self) private var activities
    @Environment(SharedHistoryController.self) private var sharing
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("liveActivityEnabled") private var liveActivityEnabled = true
    var body: some View {
        @Bindable var store = store
        TabView {
            FeedView().tabItem { Label("Feed", systemImage: "heart") }
            HistoryView().tabItem { Label("History", systemImage: "clock") }
            TrendsView().tabItem { Label("Trends", systemImage: "chart.bar.xaxis") }
            SettingsView().tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .fontDesign(.rounded)
        .foregroundStyle(Palette.ink)
        .alert("Your data", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(L10n.text(store.error ?? "")) }
        .onChange(of: store.ledger) { refreshActivity() }
        .onChange(of: liveActivityEnabled) { refreshActivity(force: true) }
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { sharing.startIfEnabled(); refreshActivity() }
            else { sharing.suspend() }
        }
        .task { sharing.startIfEnabled() }

    }
    private func refreshActivity(force: Bool = false) {
        guard !store.loadFailed else { return }
        activities.refresh(store.ledger, enabled: liveActivityEnabled, force: force)
    }
}

enum TimeText {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return L10n.format("%dh %dm", total / 3600, (total % 3600) / 60) }
        return L10n.format("%dm %ds", total / 60, total % 60)
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

struct FeedView: View {
    @Environment(FeedingStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showEditor = false
    @State private var showBottle = false
    @State private var editing: Feed?
    @State private var editingCue: HungerCue?
    @State private var editingPump: PumpSession?
    @State private var confirmDiscard = false
    @State private var finishingFeed: Feed?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Felix").font(.system(size: 38, weight: .bold, design: .rounded))
                            Text(Date.now, format: .dateTime.weekday(.wide).day().month(.wide))
                                .font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                        Spacer()
                        if !typeSize.isAccessibilitySize {
                            Image(systemName: "heart.fill").font(.title3)
                                .foregroundStyle(Palette.button)
                                .frame(width: 46, height: 46).background(Palette.sage, in: Circle())
                                .accessibilityHidden(true)
                        }
                    }
                    if let active = store.ledger.active { activeCard(active) }
                    else { readyCard }
                    HungerCueLogButton()
                    Button { showBottle = true } label: {
                        HStack(spacing: 14) {
                            BabyIllustration(pose: .bottle, width: 62, animated: false)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Log a bottle").font(.headline)
                                Text("Record volume drunk in ml").font(.subheadline).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            Image(systemName: "plus.circle.fill").font(.title2).foregroundStyle(Palette.green)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Palette.blue, in: RoundedRectangle(cornerRadius: 26))
                    }.buttonStyle(SoftPressStyle()).accessibilityIdentifier("log-bottle")
                    PumpingLogButton()
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Today").font(.title3.bold())
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            let today = store.ledger.feeds(on: context.date)
                            VStack(spacing: 12) {
                                volumeCard(today, now: context.date)
                                PumpingSummaryCard(now: context.date)
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 10) { stats(today) }
                                    VStack(spacing: 10) { stats(today) }
                                }
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Recent history").font(.title3.bold())
                            Spacer()
                            Button("Log a feed", systemImage: "plus") { showEditor = true }
                                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                        }
                        if store.ledger.visibleHistory.isEmpty {
                            VStack(spacing: 10) {
                                BabyIllustration(pose: .resting, width: 78, animated: false)
                                Text("A little rhythm, one feed at a time.").font(.headline).multilineTextAlignment(.center)
                                Text("Start a timer above, or log an earlier feed.")
                                    .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(24).background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(store.ledger.visibleHistory.prefix(4))) { entry in
                                    Button {
                                        switch entry {
                                        case .feed(let feed): editing = feed
                                        case .hunger(let cue): editingCue = cue
                                        case .pump(let session): editingPump = session
                                        }
                                    } label: { HistoryEntryRow(entry: entry) }
                                        .buttonStyle(.plain)
                                    if entry.id != store.ledger.visibleHistory.prefix(4).last?.id { Divider().padding(.leading, 58) }
                                }
                            }.padding(.horizontal, 16).background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
                        }
                    }
                }.padding(20).frame(maxWidth: 600)
                    .frame(maxWidth: .infinity)
            }
            .background(Palette.background)
            .navigationTitle("Feeding")
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showEditor) { FeedEditor() }
            .sheet(isPresented: $showBottle) { FeedEditor(defaultKind: .expressed) }
            .sheet(item: $editing) { FeedEditor(feed: $0) }
            .sheet(item: $finishingFeed) { FeedEditor(feed: $0, finishingTimer: true) }
            .sheet(item: $editingCue) { HungerCueEditor(cue: $0) }
            .sheet(item: $editingPump) { PumpingEditor(session: $0) }
            .confirmationDialog("Discard this timer?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard timer", role: .destructive) { store.change { $0.active = nil } }
                Button("Keep timing", role: .cancel) {}
            } message: { Text("This unfinished feed will not be added to history.") }
        }
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text("SINCE LAST FEED STARTED").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.secondary)
                    if let last = store.ledger.visibleFeeds.first {
                        Text(TimeText.duration(context.date.timeIntervalSince(last.startedAt)))
                            .font(.system(.largeTitle, design: .rounded, weight: .medium)).monospacedDigit()
                            .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                            .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.65)
                        Text("\(last.kind.title) · \(last.startedAt.formatted(date: .omitted, time: .shortened))")
                            .font(.subheadline).foregroundStyle(Palette.secondary)
                    } else {
                        Text("Ready when you are.").font(.system(.title, design: .rounded, weight: .medium))
                        Text("Keep track of every little feed.").font(.subheadline).foregroundStyle(Palette.secondary)
                    }
                }
            }
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    BabyIllustration(pose: .hello, width: 104)
                }
            }
            Button {
                store.change { try $0.start(side: .left, now: .now) }
            } label: {
                Label("Start breastfeeding", systemImage: "heart.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 70)
                    .foregroundStyle(.white)
                    .background(Palette.button, in: RoundedRectangle(cornerRadius: 20))
            }.buttonStyle(SoftPressStyle()).accessibilityIdentifier("start-breastfeeding")
            Button { showEditor = true } label: {
                Label("Log an earlier breastfeed", systemImage: "plus.circle")
                    .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
            }
        }.padding(22).background(Palette.sage, in: RoundedRectangle(cornerRadius: 30))
    }

    private func activeCard(_ active: ActiveFeed) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(LocalizedStringKey(active.runningSince == nil ? "PAUSED" : "FEEDING NOW"), systemImage: active.runningSince == nil ? "pause.circle" : "circle.fill")
                    .font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.green)
                Spacer()
                Menu {
                    Button("Discard timer", role: .destructive) { confirmDiscard = true }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("Timer options")
            }
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.text(active.runningSince == nil ? "A little pause." : "One little feed at a time."))
                    .font(.title3.bold())
                Spacer(minLength: 0)
                if !typeSize.isAccessibilitySize {
                    BabyIllustration(pose: active.runningSince == nil ? .resting : .feeding, width: 78)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = active.seconds(for: .left, at: context.date)
                let right = active.seconds(for: .right, at: context.date)
                VStack(alignment: .leading, spacing: 16) {
                    Text(TimeText.clock(left + right))
                        .font(.system(size: 54, weight: .medium, design: .rounded)).monospacedDigit()
                        .minimumScaleFactor(0.5).lineLimit(1).accessibilityLabel(L10n.format("Feeding time %@", TimeText.duration(left + right)))
                }
            }
            Text(L10n.format("Started %@", active.startedAt.formatted(date: .omitted, time: .shortened)))
                .font(.caption).foregroundStyle(Palette.secondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { timerButtons(active) }
                VStack(spacing: 12) { timerButtons(active) }
            }
            Text("Your timer continues when the phone is locked.")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.padding(22).background(Palette.sage, in: RoundedRectangle(cornerRadius: 30))
    }

    @ViewBuilder private func timerButtons(_ active: ActiveFeed) -> some View {
        Button {
            store.change {
                if active.runningSince == nil { $0.active?.resume(at: .now) }
                else { $0.active?.pause(at: .now) }
            }
        } label: {
            Label(LocalizedStringKey(active.runningSince == nil ? "Resume" : "Pause"), systemImage: active.runningSince == nil ? "play.fill" : "pause.fill")
                .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered)
        Button {
            let now = Date.now
            if store.change({ $0.active?.pause(at: now) }), let paused = store.ledger.active {
                finishingFeed = paused.completed(at: now)
            }
        } label: {
            Label("Finish feed", systemImage: "checkmark").font(.headline).fixedSize().frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent).tint(Palette.button).foregroundStyle(.white).accessibilityIdentifier("finish-feed")
    }

    private func volumeCard(_ feeds: [Feed], now: Date) -> some View {
        let volume = VolumeSummary(feeds: feeds)
        let last24 = store.ledger.volumeInLast24Hours(at: now)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Milk intake today", systemImage: "drop").font(.headline).foregroundStyle(Palette.green)
            Text("\(volume.totalML) ml")
                .font(.system(.largeTitle, design: .rounded, weight: .semibold)).monospacedDigit()
            Text(L10n.format("%d ml expressed milk · %d ml formula", volume.expressedML, volume.formulaML))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Text(L10n.format("Last 24 hours: %d ml", last24.totalML))
                .font(.subheadline.weight(.medium))
            Text(L10n.format("%d ml estimated at breast", volume.estimatedBreastML))
                .font(.subheadline).foregroundStyle(Palette.secondary)
            Text("Includes parent-entered breastfeeding estimates. Time alone does not add milk volume.")
                .font(.caption).foregroundStyle(Palette.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            .background(Palette.yellow, in: RoundedRectangle(cornerRadius: 26))
            .accessibilityElement(children: .combine).accessibilityIdentifier("volume-summary")
    }

    @ViewBuilder private func stats(_ feeds: [Feed]) -> some View {
        StatTile(value: "\(feeds.count)", title: "feeds", symbol: "heart")
        StatTile(value: L10n.format("%d min", Int(feeds.reduce(0) { $0 + $1.duration }) / 60), title: "at breast", symbol: "timer")
    }
}

struct StatTile: View {
    let value: String
    let title: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(Palette.green)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold)).fixedSize()
            Text(L10n.text(title)).font(.caption).foregroundStyle(Palette.secondary).fixedSize()
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
    }
}

struct FeedRow: View {
    let feed: Feed
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feed.kind == .breast ? "heart" : "drop")
                .foregroundStyle(Palette.green).frame(width: 40, height: 44)
                .background(Palette.sage, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(feed.kind.title).font(.headline)
                Text(feed.kind == .breast ? TimeText.duration(feed.duration) : "\(feed.millilitres ?? 0) ml")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
                if feed.kind == .breast, let estimate = feed.estimatedMillilitres {
                    Text(L10n.format("Estimated milk: %d ml", estimate))
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
                if !feed.notes.isEmpty { Text(feed.notes).font(.caption).foregroundStyle(Palette.secondary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            Text(feed.startedAt, format: .dateTime.hour().minute()).font(.subheadline).foregroundStyle(Palette.secondary)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 16).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct HistoryView: View {
    @Environment(FeedingStore.self) private var store
    @State private var editing: Feed?
    @State private var editingCue: HungerCue?
    @State private var editingPump: PumpSession?
    @State private var adding = false
    private var days: [Date] {
        Set(store.ledger.visibleHistory.map { Calendar.current.startOfDay(for: $0.date) }).sorted(by: >)
    }
    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty {
                    VStack(spacing: 16) {
                        BabyIllustration(pose: .resting, width: 140, animated: false)
                        Text("No history yet").font(.title2.bold())
                        Text("Feeds, hunger observations and pumping will appear here.")
                            .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                    }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(days, id: \.self) { day in
                            Section {
                                ForEach(store.ledger.history(on: day)) { entry in
                                    Button {
                                        switch entry {
                                        case .feed(let feed): editing = feed
                                        case .hunger(let cue): editingCue = cue
                                        case .pump(let session): editingPump = session
                                        }
                                    } label: { HistoryEntryRow(entry: entry) }.buttonStyle(.plain)
                                        .swipeActions {
                                            Button("Delete", role: .destructive) {
                                                store.change {
                                                    switch entry {
                                                    case .feed(let feed): $0.setDeleted(feed.id, at: .now)
                                                    case .hunger(let cue): $0.setHungerCueDeleted(cue.id, at: .now)
                                                    case .pump(let session): $0.setPumpSessionDeleted(session.id, at: .now)
                                                    }
                                                }
                                            }
                                        }
                                }
                            } header: {
                                Text(day.formatted(date: .complete, time: .omitted))
                            } footer: {
                                let feeds = store.ledger.feeds(on: day)
                                let count = feeds.count
                                let volume = VolumeSummary(feeds: feeds)
                                let cues = store.ledger.history(on: day).filter { if case .hunger = $0 { return true }; return false }.count
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.format(count == 1 ? "%d feed · %d ml intake · Includes estimates · Grouped by start date" : "%d feeds · %d ml intake · Includes estimates · Grouped by start date", count, volume.totalML))
                                    if cues > 0 { Text(L10n.format(cues == 1 ? "%d hunger observation" : "%d hunger observations", cues)) }
                                    let pumped = PumpSummary(sessions: store.ledger.pumpSessions(on: day))
                                    if pumped.sessionCount > 0 {
                                        Text(L10n.format(pumped.sessionCount == 1 ? "%d pumping session · %d ml pumped" : "%d pumping sessions · %d ml pumped",
                                                         pumped.sessionCount, pumped.totalML))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .felixFormStyle()
            .navigationTitle("History")
            .toolbar { Button("Log a feed", systemImage: "plus") { adding = true } }
            .sheet(isPresented: $adding) { FeedEditor() }
            .sheet(item: $editing) { FeedEditor(feed: $0) }
            .sheet(item: $editingCue) { HungerCueEditor(cue: $0) }
            .sheet(item: $editingPump) { PumpingEditor(session: $0) }
        }
    }
}

struct FeedEditor: View {
    @Environment(FeedingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let feed: Feed?
    let finishingTimer: Bool
    @State private var kind: FeedKind
    @State private var started: Date
    @State private var ended: Date
    @State private var nursingMinutes: String
    @State private var estimate: String
    @State private var amount: String
    @State private var notes: String
    @State private var validation: String?

    init(feed: Feed? = nil, defaultKind: FeedKind = .breast, finishingTimer: Bool = false) {
        self.feed = feed
        self.finishingTimer = finishingTimer
        let now = Date.now
        _kind = State(initialValue: feed?.kind ?? defaultKind)
        _started = State(initialValue: feed?.startedAt ?? (defaultKind == .breast ? now.addingTimeInterval(-15 * 60) : now))
        _ended = State(initialValue: feed?.endedAt ?? now)
        _nursingMinutes = State(initialValue: feed.map { Self.formattedMinutes($0.duration) } ?? "")
        _estimate = State(initialValue: feed?.estimatedMillilitres.map(String.init) ?? "")
        _amount = State(initialValue: feed?.millilitres.map(String.init) ?? "")
        _notes = State(initialValue: feed?.notes ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Feeding") {
                    if !finishingTimer {
                        Picker("Type", selection: $kind) {
                            ForEach(FeedKind.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    if kind != .breast { bottleTimeShortcuts }
                    DatePicker("Started", selection: $started, in: ...Date.now)
                        .accessibilityIdentifier("feed-started")
                    DatePicker("Ended", selection: $ended, in: ...Date.now)
                        .accessibilityIdentifier("feed-ended")
                }
                if kind == .breast {
                    Section {
                        numericField("Time at breast (minutes)", text: $nursingMinutes, placeholder: "0")
                    } footer: { Text("Enter total active breastfeeding time. Pauses are excluded. Decimals are supported.") }
                    Section {
                        numericField("Estimated milk (ml)", text: $estimate, placeholder: "Optional")
                    } header: { Text("Milk estimate") } footer: {
                        Text("Your estimate counts toward daily milk intake. Leave blank if unknown; time is not converted into ml.")
                    }
                } else {
                    Section {
                        numericField("Volume drunk (ml)", text: $amount, placeholder: "e.g. 60")
                        bottleVolumeShortcuts
                    } header: { Text("Bottle volume") } footer: {
                        Text("Enter how much Felix actually drank, rather than the amount prepared.")
                    }
                }
                Section("Notes") {
                    TextField("Anything to remember?", text: $notes, axis: .vertical).lineLimit(3...7)
                        .accessibilityIdentifier("feed-notes")
                }
                if let validation { Section { Text(validation).foregroundStyle(.red) } }
                if let feed, !finishingTimer {
                    Section {
                        Button("Delete feed", role: .destructive) {
                            if store.change({ $0.setDeleted(feed.id, at: .now) }) { dismiss() }
                        }
                    } footer: { Text("Deleted feeds can be restored in Settings.") }
                }
            }
            .felixFormStyle()
            .navigationTitle(L10n.text(finishingTimer ? "Finish feed" : feed == nil ? (kind == .breast ? "Log a feed" : "Log a bottle") : "Edit feed"))
            .navigationBarTitleDisplayMode(.inline)
            .onChange(of: kind) { validation = nil }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).bold().accessibilityIdentifier("save-feed") }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
            .interactiveDismissDisabled()
        }
    }
    private var bottleTimeShortcuts: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set start time").font(.subheadline).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach([0, 5, 15, 30, 60], id: \.self) { minutesAgo in
                    Button {
                        let time = Date.now.addingTimeInterval(-Double(minutesAgo) * 60)
                        started = time
                        if ended < time { ended = time }
                        validation = nil
                    } label: {
                        Text(minutesAgo == 0 ? L10n.text("Now") :
                            minutesAgo == 60 ? L10n.text("1 hour ago") : L10n.format("%d min ago", minutesAgo))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Palette.sage, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(minutesAgo == 0 ? L10n.text("Set start time to now") :
                        L10n.format("Set start time to %d minutes ago", minutesAgo))
                    .accessibilityIdentifier("bottle-time-\(minutesAgo)")
                }
            }
        }.padding(.vertical, 4)
    }
    private var bottleVolumeShortcuts: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
            ForEach(store.ledger.bottleVolumePresets(), id: \.self) { millilitres in
                let selected = Int(amount.trimmingCharacters(in: .whitespaces)) == millilitres
                Button {
                    amount = String(millilitres)
                    validation = nil
                } label: {
                    Text(L10n.format("%d ml", millilitres))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(Palette.sage, in: RoundedRectangle(cornerRadius: 12))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? Palette.green : .clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("Set volume to %d ml", millilitres))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("bottle-volume-\(millilitres)")
            }
        }.padding(.vertical, 4)
    }
    private func numericField(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(L10n.text(title))
            Spacer()
            TextField(L10n.text(placeholder), text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .frame(minWidth: 65, maxWidth: 120).accessibilityLabel(L10n.text(title))
        }
    }
    private func minutes(_ text: String) throws -> Double {
        if text.trimmingCharacters(in: .whitespaces).isEmpty { return 0 }
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value >= 0 else {
            throw FeedingError.invalid("Enter a valid, positive number of minutes.")
        }
        return value * 60
    }
    private static func formattedMinutes(_ seconds: TimeInterval) -> String {
        String(format: "%.2f", locale: Locale.current, seconds / 60)
    }
    private func save() {
        do {
            let trimmedEstimate = estimate.trimmingCharacters(in: .whitespacesAndNewlines)
            let estimatedML: Int?
            if kind == .breast && !trimmedEstimate.isEmpty {
                guard let value = Int(trimmedEstimate), (0...2000).contains(value) else {
                    throw FeedingError.invalid("Enter an estimated amount between 0 and 2,000 ml, or leave it blank.")
                }
                estimatedML = value
            } else { estimatedML = nil }
            // Preserve exact seconds (including legacy side history) when only editing an amount or note.
            let unchangedTime = feed.map { nursingMinutes == Self.formattedMinutes($0.duration) } ?? false
            let totalSeconds = kind == .breast ? try minutes(nursingMinutes) : 0
            let entry = Feed(id: feed?.id ?? UUID(), startedAt: started, endedAt: ended, kind: kind,
                leftSeconds: kind == .breast ? (unchangedTime ? feed!.leftSeconds : totalSeconds) : 0,
                rightSeconds: kind == .breast && unchangedTime ? feed!.rightSeconds : 0,
                millilitres: kind == .breast ? nil : Int(amount.trimmingCharacters(in: .whitespaces)),
                estimatedMillilitres: estimatedML, notes: notes)
            try entry.validate()
            if store.change({ ledger in
                if finishingTimer {
                    guard ledger.active?.id == entry.id else {
                        throw FeedingError.invalid("The timer has changed. Close this screen and try again.")
                    }
                    ledger.active = nil
                }
                try ledger.upsert(entry)
            }) { dismiss() }
        } catch { validation = error.localizedDescription }
    }
}

struct ExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct SettingsView: View {
    @Environment(FeedingStore.self) private var store
    @Environment(FeedActivityController.self) private var activities
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("liveActivityEnabled") private var liveActivityEnabled = true
    @State private var exportFile: ExportFile?
    @State private var exportType = UTType.json
    @State private var exporting = false
    @State private var importing = false
    @State private var importResult: String?
    private var deleted: [HistoryEntry] {
        (store.ledger.feeds.filter { $0.deletedAt != nil }.map(HistoryEntry.feed) +
         store.ledger.hungerCues.filter { $0.deletedAt != nil }.map(HistoryEntry.hunger) +
         store.ledger.pumpSessions.filter { $0.deletedAt != nil }.map(HistoryEntry.pump)).sorted { $0.date > $1.date }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        BabyIllustration(pose: .hello, width: 80, animated: false)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Made for Felix").font(.title2.bold())
                            Text("Every little feed, together.").font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Palette.sage)

                Section {
                    NavigationLink("Shared feeding history") { SharedHistorySettingsView() }
                }
                Section {
                    LabeledContent("Baby", value: "Felix")
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section {
                    Toggle("Lock Screen feeding timer", isOn: $liveActivityEnabled)
                    if liveActivityEnabled {
                        Button("Show on Lock Screen", systemImage: "lock.rectangle") {
                            guard !store.loadFailed else { return }
                            activities.refresh(store.ledger, enabled: true, force: true)
                        }.disabled(store.ledger.latestFeedGlance == nil || store.loadFailed)
                        if !activities.systemEnabled {
                            Link("Open iPhone Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                        }
                    }
                    Text(L10n.text(activities.status)).font(.footnote).foregroundStyle(Palette.secondary)
                } header: { Text("At a glance") } footer: {
                    Text("Shows time since the last feed started, its type and bottle volume on the Lock Screen and Dynamic Island. Each new feed renews the activity. iOS limits an activity to eight hours; reopen the app or tap Show to restore it. You can swipe it away without deleting a feed.")
                }
                Section {
                    Button("Export backup", systemImage: "square.and.arrow.up") { export(json: true) }
                    Button("Export spreadsheet (CSV)", systemImage: "tablecells") { export(json: false) }
                    Button("Import backup", systemImage: "square.and.arrow.down") { importing = true }
                } header: { Text("Your records") } footer: {
                    Text("Backups include saved feeds, hunger observations, pumping sessions and the timer. Import adds missing entries and keeps existing records and your current timer. Export regularly before changing phones or removing the app.")
                }
                Section {
                    NavigationLink(L10n.format("Recently deleted (%d)", deleted.count)) {
                        List {
                            if deleted.isEmpty { Text("No deleted entries.").foregroundStyle(Palette.secondary) }
                            ForEach(deleted) { entry in
                                VStack(alignment: .leading) {
                                    HistoryEntryRow(entry: entry)
                                    Text(entry.date, format: .dateTime.day().month().year()).font(.caption).foregroundStyle(Palette.secondary)
                                    Button("Restore entry") {
                                        store.change {
                                            switch entry {
                                            case .feed(let feed): $0.setDeleted(feed.id, at: nil)
                                            case .hunger(let cue): $0.setHungerCueDeleted(cue.id, at: nil)
                                            case .pump(let session): $0.setPumpSessionDeleted(session.id, at: nil)
                                            }
                                        }
                                    }.frame(minHeight: 44)
                                }
                            }
                        }.navigationTitle("Recently deleted")
                    }
                } footer: { Text("Deleted entries stay here until you restore them. They are included in backups and excluded from totals.") }
                Section("Private by default") {
                    Label("Saved on this iPhone", systemImage: "iphone")
                    Label("Works without internet", systemImage: "wifi.slash")
                    Label("No advertising or tracking", systemImage: "hand.raised")
                    Text("Records are saved on this phone. If you enable shared history, encrypted feeds sync through your private family service. Paired phones hold the decryption key. iOS may include local records in your device backup.").font(.footnote).foregroundStyle(Palette.secondary)
                }
                Section {
                    Text("Time since last feed is measured from the start of the most recent feed. Daily totals use this phone’s local calendar and group feeds by their start date.")
                    Text("Felix Feeds records what happened. It does not set feeding targets or give medical advice.")
                }.font(.footnote).foregroundStyle(Palette.secondary)
            }
            .felixFormStyle()
            .navigationTitle("Settings")
            .fileExporter(isPresented: $exporting, document: exportFile, contentType: exportType,
                          defaultFilename: "Felix-Feeds-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
                if case .failure(let error) = result { store.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                do {
                    let url = try result.get()
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 20_000_000 else { throw FeedingError.invalid("This backup is too large to import.") }
                    let backup = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
                    var count = 0
                    if store.change({ count = try $0.merge(backup) }) { importResult = L10n.format(count == 1 ? "Added %d entry. Existing records and your timer were kept." : "Added %d entries. Existing records and your timer were kept.", count) }
                } catch { store.error = error.localizedDescription }
            }
            .alert("Backup imported", isPresented: Binding(get: { importResult != nil }, set: { if !$0 { importResult = nil } })) {
                Button("OK") { importResult = nil }
            } message: { Text(L10n.text(importResult ?? "")) }
        }
    }
    private func export(json: Bool) {
        do {
            guard !store.loadFailed else { throw FeedingError.invalid("Your saved data could not be opened.") }
            exportType = json ? .json : .commaSeparatedText
            exportFile = ExportFile(data: try json ? store.backup() : Data(store.ledger.csv().utf8))
            exporting = true
        } catch { store.error = error.localizedDescription }
    }
}
