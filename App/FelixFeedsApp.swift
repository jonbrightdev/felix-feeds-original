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
    @State private var activities: FeedActivityController
    @AppStorage("appearance") private var appearance = "system"
    init() {
        let store = FeedingStore()
        let sharing = SharedHistoryController(store: store)
        let activities = FeedActivityController(push: sharing.activityPush)
        sharing.didSyncFeeds = { [weak store, weak activities] in
            guard let store, let activities, !store.loadFailed else { return }
            let enabled = UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true
            activities.refresh(store.ledger, enabled: enabled)
        }
        _store = State(initialValue: store)
        _sharing = State(initialValue: sharing)
        _activities = State(initialValue: activities)
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
        .onChange(of: sharing.enabled) { refreshActivity(preserveRemote: sharing.enabled) }
        .onChange(of: sharing.activityPush.available) { refreshActivity(preserveRemote: true) }
        .onChange(of: scenePhase, initial: true) {
            if scenePhase == .active { sharing.startIfEnabled(); refreshActivity(preserveRemote: true) }
            else if scenePhase == .background { sharing.suspend() }
        }
        .task { sharing.startIfEnabled() }

    }
    private func refreshActivity(force: Bool = false, preserveRemote: Bool = false) {
        guard !store.loadFailed else { return }
        activities.refresh(store.ledger, enabled: liveActivityEnabled, force: force, preserveRemote: preserveRemote)
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
    @State private var editing: Feed?
    @State private var editingPump: PumpSession?
    @State private var confirmDiscard = false
    @State private var finishingFeed: Feed?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    feedHeader
                    if let active = store.ledger.active {
                        activeCard(active)
                        logSessionButton
                    } else {
                        readyCard
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        milkCard(now: context.date)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Recent history").font(.title3.bold())
                        if store.ledger.visibleHistory.isEmpty {
                            VStack(spacing: 10) {
                                BabyIllustration(pose: .resting, width: 78, animated: false)
                                Text("A little rhythm, one feed at a time.").font(.headline).multilineTextAlignment(.center)
                                Text("Log a session to record a bottle, breastfeeding or pumping.")
                                    .font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                            }.frame(maxWidth: .infinity).padding(24).background(Palette.card, in: RoundedRectangle(cornerRadius: 22))
                        } else {
                            VStack(spacing: 0) {
                                ForEach(Array(store.ledger.visibleHistory.prefix(4))) { entry in
                                    Button {
                                        switch entry {
                                        case .feed(let feed): editing = feed
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
            .sheet(item: $editing) { FeedEditor(feed: $0) }
            .sheet(item: $finishingFeed) { FeedEditor(feed: $0, finishingTimer: true) }
            .sheet(item: $editingPump) { PumpingEditor(session: $0) }
            .confirmationDialog("Discard this timer?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard timer", role: .destructive) { store.change { $0.active = nil } }
                Button("Keep timing", role: .cancel) {}
            } message: { Text("This unfinished feed will not be added to history.") }
        }
    }

    private var feedHeader: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 5) {
                Text("Felix").font(.system(size: 38, weight: .bold, design: .rounded))
                Text(context.date, format: .dateTime.weekday(.wide).day().month(.wide))
                    .font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }.accessibilityIdentifier("feed-header")
    }

    private var readyCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 8) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    sinceLastFeed(now: context.date)
                }
                if !typeSize.isAccessibilitySize {
                    Spacer(minLength: 0)
                    BabyIllustration(pose: .hello, width: 104)
                }
            }
            logSessionButton
        }.padding(22).background(Palette.blue, in: RoundedRectangle(cornerRadius: 30))
    }

    private var logSessionButton: some View {
        Button { showEditor = true } label: {
            Label("Log a session", systemImage: "plus")
                .font(.headline).padding(.horizontal, 16).padding(.vertical, 14)
                .frame(maxWidth: .infinity, minHeight: 54)
                .foregroundStyle(.white)
                .background(Palette.button, in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(SoftPressStyle()).disabled(store.loadFailed).accessibilityIdentifier("log-session")
    }

    private func sinceLastFeed(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SINCE LAST FEED").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.secondary)
            if let last = store.ledger.visibleFeeds.first {
                Text(TimeText.duration(now.timeIntervalSince(last.startedAt)))
                    .font(.system(.title, design: .rounded, weight: .medium)).monospacedDigit()
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.65)
            } else {
                Text("Ready when you are.").font(.system(.title2, design: .rounded, weight: .medium))
                Text("Keep track of every little feed.").font(.subheadline).foregroundStyle(Palette.secondary)
            }
        }
    }

    // Totals include parent-entered breast estimates; elapsed time never adds volume.
    // Both days follow the phone's calendar, matching how history groups feeds.
    private func milkCard(now: Date) -> some View {
        let calendar = Calendar.current
        let ledger = store.ledger
        let sameTimeYesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now.addingTimeInterval(-86_400)
        let todayProgress = ledger.milkProgress(on: now, until: now, calendar: calendar)
        // Wall-clock shift keeps yesterday aligned with today across daylight-saving changes.
        let yesterdayProgress = ledger.milkProgress(on: sameTimeYesterday, calendar: calendar).map {
            MilkProgressPoint(time: calendar.date(byAdding: .day, value: 1, to: $0.time) ?? $0.time, totalML: $0.totalML)
        }
        let todayML = todayProgress.last?.totalML ?? 0
        let yesterdayML = yesterdayProgress.last?.totalML ?? 0
        let dayStart = calendar.startOfDay(for: now)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        return VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MILK TODAY").font(.caption.weight(.semibold)).tracking(1).foregroundStyle(Palette.secondary)
                Text("\(todayML) ml")
                    .font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.65)
                Text(L10n.format("Yesterday: %d ml", yesterdayML)).font(.subheadline).foregroundStyle(Palette.secondary)
            }.accessibilityElement(children: .combine).accessibilityIdentifier("volume-summary")
            if todayML > 0 || yesterdayML > 0 {
                MilkTodayChart(today: todayProgress, yesterday: yesterdayProgress, day: dayStart...dayEnd,
                               yesterdayByNow: ledger.milkProgress(on: sameTimeYesterday, until: sameTimeYesterday, calendar: calendar).last?.totalML ?? 0)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 30))
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
}

struct FeedRow: View {
    let feed: Feed
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: feed.kind == .breast ? "heart" : "drop")
                .foregroundStyle(Palette.green).frame(width: 40, height: 44)
                .background(Palette.sage, in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(feed.title).font(.headline)
                Text(feed.kind == .breast ? TimeText.duration(feed.duration) : "\(feed.millilitres ?? 0) ml")
                    .font(.subheadline).foregroundStyle(Palette.secondary)
                if feed.isMixedBottle {
                    Text(L10n.format("%d ml expressed + %d ml formula", feed.expressedML, feed.formulaML))
                        .font(.subheadline).foregroundStyle(Palette.secondary)
                }
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

struct HistoryEntryRow: View {
    let entry: HistoryEntry
    var body: some View {
        switch entry {
        case .feed(let feed): FeedRow(feed: feed)
        case .pump(let session): PumpingRow(session: session)
        }
    }
}

struct HistoryView: View {
    @Environment(FeedingStore.self) private var store
    @State private var editing: Feed?
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
                        Text("Feeds and pumping will appear here.")
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
                                        case .pump(let session): editingPump = session
                                        }
                                    } label: { HistoryEntryRow(entry: entry) }.buttonStyle(.plain)
                                        .swipeActions {
                                            Button("Delete", role: .destructive) {
                                                store.change {
                                                    switch entry {
                                                    case .feed(let feed): $0.setDeleted(feed.id, at: .now)
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
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(L10n.format(count == 1 ? "%d feed · %d ml intake · Includes estimates · Grouped by start date" : "%d feeds · %d ml intake · Includes estimates · Grouped by start date", count, volume.totalML))
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
            .toolbar { Button("Log a session", systemImage: "plus") { adding = true } }
            .sheet(isPresented: $adding) { FeedEditor() }
            .sheet(item: $editing) { FeedEditor(feed: $0) }
            .sheet(item: $editingPump) { PumpingEditor(session: $0) }
        }
    }
}

struct FeedEditor: View {
    private enum SessionKind: Hashable {
        case bottle, breast, pump
    }
    private enum BreastTiming: Hashable {
        case earlier, now
    }
    private enum NumericField: String, Hashable {
        case volume, expressedVolume, formulaVolume, nursingMinutes, estimate
    }
    private enum Kind: String, CaseIterable, Identifiable {
        case breast, expressed, formula, mixed
        var id: String { rawValue }
        var feedKind: FeedKind { self == .mixed ? .expressed : FeedKind(rawValue: rawValue)! }
        var title: String { self == .mixed ? L10n.text("Mixed bottle") : feedKind.title }
    }
    @Environment(FeedingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let feed: Feed?
    let finishingTimer: Bool
    @State private var sessionKind: SessionKind
    @State private var milkKind: Kind
    @State private var breastTiming = BreastTiming.earlier
    @State private var started: Date
    @State private var startTimeShortcut: (minutesAgo: Int, date: Date)?
    @State private var ended: Date
    @State private var breastStarted: Date
    @State private var breastTimeShortcut: (minutesAgo: Int, date: Date)?
    @State private var nursingMinutes: String
    @State private var estimate: String
    @State private var amount: String
    @State private var expressedAmount: String
    @State private var formulaAmount: String
    @State private var notes: String
    @State private var pumpedAt: Date
    @State private var pumpedAmount = ""
    @State private var pumpingNotes = ""
    @State private var validation: String?
    @FocusState private var focusedField: NumericField?

    private var kind: Kind { sessionKind == .breast ? .breast : milkKind }
    private var startingTimer: Bool { sessionKind == .breast && breastTiming == .now && feed == nil && !finishingTimer }

    init(feed: Feed? = nil, defaultKind: FeedKind = .expressed, finishingTimer: Bool = false) {
        self.feed = feed
        self.finishingTimer = finishingTimer
        let now = Date.now
        let initialKind = feed?.kind ?? defaultKind
        _sessionKind = State(initialValue: initialKind == .breast ? .breast : .bottle)
        _milkKind = State(initialValue: feed?.isMixedBottle == true ? .mixed : initialKind == .formula ? .formula : .expressed)
        _started = State(initialValue: feed?.startedAt ?? (defaultKind == .breast ? now.addingTimeInterval(-15 * 60) : now))
        _ended = State(initialValue: feed?.endedAt ?? now)
        _breastStarted = State(initialValue: feed?.startedAt ?? now.addingTimeInterval(-15 * 60))
        _nursingMinutes = State(initialValue: feed.map { Self.formattedMinutes($0.duration) } ?? "")
        _estimate = State(initialValue: feed?.estimatedMillilitres.map(String.init) ?? "")
        _amount = State(initialValue: feed?.millilitres.map(String.init) ?? "")
        _expressedAmount = State(initialValue: feed?.isMixedBottle == true ? String(feed!.expressedML) : "")
        _formulaAmount = State(initialValue: feed?.isMixedBottle == true ? String(feed!.formulaML) : "")
        _notes = State(initialValue: feed?.notes ?? "")
        _pumpedAt = State(initialValue: now)
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { scrollProxy in
                VStack(spacing: 0) {
                    sessionPicker
                    Form {
                        if sessionKind == .pump {
                            PumpingFields(pumpedAt: $pumpedAt, amount: $pumpedAmount, notes: $pumpingNotes) { validation = nil }
                        } else {
                            feedFields
                        }
                        if let validation {
                            Section { Text(validation).foregroundStyle(.red) }
                                .id("session-validation").accessibilityIdentifier("session-validation")
                        }
                        if let feed, !finishingTimer {
                            Section {
                                Button("Delete feed", role: .destructive) {
                                    if store.change({ $0.setDeleted(feed.id, at: .now) }) { dismiss() }
                                }
                            } footer: { Text("Deleted feeds can be restored in Settings.") }
                        }
                    }.id(sessionKind)
                }
                .felixFormStyle()
                .navigationTitle(L10n.text(finishingTimer ? "Finish feed" : feed == nil ? "Log a session" : "Edit feed"))
                .navigationBarTitleDisplayMode(.inline)
                .onChange(of: sessionKind) { resetFocus() }
                .onChange(of: milkKind) { resetFocus() }
                .onChange(of: breastTiming) { resetFocus() }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        if !startingTimer {
                            Button("Save", action: save).bold()
                                .accessibilityIdentifier(sessionKind == .pump ? "save-pumping" : "save-feed")
                        }
                    }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            focusedField = nil
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                    }
                }
                .interactiveDismissDisabled()
                .onChange(of: focusedField) {
                    if let focusedField { scrollProxy.scrollTo(focusedField, anchor: .center) }
                }
                .onChange(of: validation) {
                    if validation != nil {
                        focusedField = nil
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        scrollProxy.scrollTo("session-validation", anchor: .center)
                    }
                }
            }
        }
    }
    @ViewBuilder private var sessionPicker: some View {
        if !finishingTimer {
            EditorChoicePicker(title: "Session type", selection: $sessionKind,
                options: feed == nil ? [(.bottle, "Bottle"), (.breast, "Breastfeeding"), (.pump, "Pumping")]
                    : [(.bottle, "Bottle"), (.breast, "Breastfeeding")])
                .accessibilityIdentifier("session-type")
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(Palette.background)
        }
    }

    @ViewBuilder private var feedFields: some View {
        if sessionKind == .bottle {
            Section("Milk type") {
                EditorChoicePicker(title: "Milk type", selection: $milkKind,
                    options: [(.expressed, "Expressed"), (.formula, "Formula"), (.mixed, "Mixed")])
                    .accessibilityIdentifier("bottle-milk-type")
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        } else if feed == nil && !finishingTimer {
            Section {
                EditorChoicePicker(title: "Breastfeeding time", selection: $breastTiming,
                    options: [(.earlier, "Earlier feed"), (.now, "Feed now")])
                    .accessibilityIdentifier("breastfeeding-time")
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets())
        }
        if startingTimer {
            timerSection
        } else {
            feedDetails
            Section("Notes") {
                TextField("Anything to remember?", text: $notes, axis: .vertical).lineLimit(3...7)
                    .accessibilityIdentifier("feed-notes")
            }
        }
    }

    @ViewBuilder private var feedDetails: some View {
        Section {
            DatePicker("Started", selection: sessionKind == .breast ? $breastStarted : $started, in: ...Date.now)
                .accessibilityIdentifier("feed-started")
            if sessionKind == .breast {
                timeShortcuts(start: $breastStarted, shortcut: $breastTimeShortcut,
                    options: [5, 10, 15, 20], prefix: "breast")
            } else if feed != nil {
                DatePicker("Ended", selection: $ended, in: ...Date.now)
                    .accessibilityIdentifier("feed-ended")
            }
        } header: { Text(L10n.text(sessionKind == .breast ? "Feed details" : "Bottle details")) }
        if kind == .breast {
            Section {
                numericField("Time at breast (minutes)", text: $nursingMinutes, placeholder: "0", field: .nursingMinutes)
            } footer: { Text("Enter total active breastfeeding time. Pauses are excluded. Decimals are supported.") }
            Section {
                numericField("Estimated milk (ml)", text: $estimate, placeholder: "Optional", field: .estimate)
            } header: { Text("Milk estimate") } footer: {
                Text("Your estimate counts toward daily milk intake. Leave blank if unknown; time is not converted into ml.")
            }
        } else {
            bottleVolumeSection
            Section {
                timeShortcuts(start: $started, shortcut: $startTimeShortcut,
                    options: [0, 5, 15, 30, 60], prefix: "bottle") { time in
                        if ended < time { ended = time }
                    }
            }
        }
    }

    private var bottleVolumeSection: some View {
        Section {
            if kind == .mixed {
                numericField("Expressed milk (ml)", text: $expressedAmount, placeholder: "e.g. 60", field: .expressedVolume)
                numericField("Formula (ml)", text: $formulaAmount, placeholder: "e.g. 60", field: .formulaVolume)
                LabeledContent("Total drunk", value: mixedTotal.map { L10n.format("%d ml", $0) } ?? "—")
                    .accessibilityIdentifier("mixed-bottle-total")
            } else {
                numericField("Volume drunk (ml)", text: $amount, placeholder: "e.g. 60", field: .volume)
                bottleVolumeShortcuts
            }
        } header: { Text("Bottle volume") } footer: {
            if kind == .mixed {
                Text("Enter the expressed milk and formula in the amount Felix drank. This is saved as one bottle.")
            } else {
                Text("Enter how much Felix actually drank, rather than the amount prepared.")
            }
        }
    }

    private func resetFocus() {
        focusedField = nil
        validation = nil
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private var timerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 16) {
                Label("Feeding now?", systemImage: "timer").font(.headline)
                Text("Time a feed as it happens.").font(.subheadline).foregroundStyle(Palette.secondary)
                if store.ledger.active == nil {
                    Button {
                        if store.change({ try $0.start(side: .left, now: .now) }) { dismiss() }
                    } label: {
                        Text("Start timer").font(.headline).padding(.vertical, 14)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .foregroundStyle(.white)
                            .background(Palette.button, in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(SoftPressStyle()).disabled(store.loadFailed)
                        .accessibilityIdentifier("start-breastfeeding")
                } else {
                    Text("Finish the current feed first.").font(.subheadline)
                    Button("Return to timer") { dismiss() }.frame(minHeight: 44)
                }
                Text("Your timer continues when the phone is locked.")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }.padding(.vertical, 8)
        }.listRowBackground(Palette.sage)
    }
    private func timeShortcuts(start: Binding<Date>, shortcut: Binding<(minutesAgo: Int, date: Date)?>,
                               options: [Int], prefix: String, onSelect: @escaping (Date) -> Void = { _ in }) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Set start time").font(.subheadline).foregroundStyle(Palette.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                ForEach(options, id: \.self) { minutesAgo in
                    // Keep the chosen shortcut highlighted as time passes; a manual
                    // start-time change stops matching the shortcut's exact timestamp.
                    let selected = shortcut.wrappedValue?.minutesAgo == minutesAgo && shortcut.wrappedValue?.date == start.wrappedValue
                    Button {
                        let time = Date.now.addingTimeInterval(-Double(minutesAgo) * 60)
                        start.wrappedValue = time
                        shortcut.wrappedValue = (minutesAgo, time)
                        onSelect(time)
                        validation = nil
                    } label: {
                        Text(minutesAgo == 0 ? L10n.text("Now") :
                            minutesAgo == 60 ? L10n.text("1 hour ago") : L10n.format("%d min ago", minutesAgo))
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(Palette.sage, in: RoundedRectangle(cornerRadius: 12))
                            .overlay {
                                RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selected ? Palette.green : .clear, lineWidth: 2)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(minutesAgo == 0 ? L10n.text("Set start time to now") :
                        L10n.format("Set start time to %d minutes ago", minutesAgo))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("\(prefix)-time-\(minutesAgo)")
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
    private func numericField(_ title: String, text: Binding<String>, placeholder: String, field: NumericField) -> some View {
        HStack {
            Text(L10n.text(title))
            Spacer()
            TextField(L10n.text(placeholder), text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .focused($focusedField, equals: field)
                .frame(minWidth: 65, maxWidth: 120).accessibilityLabel(L10n.text(title))
                .accessibilityIdentifier("feed-\(field.rawValue)")
        }
        .id(field)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
        // Include the label and empty space without replacing native text-field gestures.
        .simultaneousGesture(TapGesture().onEnded { focusedField = field })
    }
    private var mixedTotal: Int? {
        guard let expressed = Int(expressedAmount.trimmingCharacters(in: .whitespacesAndNewlines)),
              let formula = Int(formulaAmount.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...2000).contains(expressed), (1...2000).contains(formula), expressed + formula <= 2000 else { return nil }
        return expressed + formula
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
            if sessionKind == .pump {
                guard let millilitres = Int(pumpedAmount.trimmingCharacters(in: .whitespaces)) else {
                    throw FeedingError.invalid("Enter a combined pumped amount between 0 and 2,000 ml.")
                }
                let entry = PumpSession(pumpedAt: pumpedAt, millilitres: millilitres, notes: pumpingNotes)
                try entry.validate()
                if store.change({ try $0.upsert(entry) }) { dismiss() }
                return
            }
            let trimmedEstimate = estimate.trimmingCharacters(in: .whitespacesAndNewlines)
            let estimatedML: Int?
            if kind == .breast && !trimmedEstimate.isEmpty {
                guard let value = Int(trimmedEstimate), (0...2000).contains(value) else {
                    throw FeedingError.invalid("Enter an estimated amount between 0 and 2,000 ml, or leave it blank.")
                }
                estimatedML = value
            } else { estimatedML = nil }
            let bottleML: Int?
            let formulaML: Int?
            if kind == .mixed {
                guard let total = mixedTotal else {
                    throw FeedingError.invalid("Enter both milk amounts above 0 ml, with a total no more than 2,000 ml.")
                }
                bottleML = total
                formulaML = Int(formulaAmount.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                bottleML = kind == .breast ? nil : Int(amount.trimmingCharacters(in: .whitespaces))
                formulaML = nil
            }
            // Preserve exact seconds (including legacy side history) when only editing an amount or note.
            let unchangedTime = feed.map { nursingMinutes == Self.formattedMinutes($0.duration) } ?? false
            let totalSeconds = kind == .breast ? (unchangedTime ? feed!.duration : try minutes(nursingMinutes)) : 0
            // Keep historical pauses and exact timestamps when timing is untouched.
            // New or retimed breastfeeds need only a start and active duration.
            let breastEnd = feed.flatMap { existing in
                existing.kind == .breast && unchangedTime && breastStarted == existing.startedAt ? existing.endedAt : nil
            } ?? breastStarted.addingTimeInterval(totalSeconds)
            if kind == .breast && breastEnd > .now {
                throw FeedingError.invalid("Choose an earlier start or a shorter duration so the feed finishes in the past.")
            }
            let entry = Feed(id: feed?.id ?? UUID(),
                startedAt: kind == .breast ? breastStarted : started,
                endedAt: kind == .breast ? breastEnd : feed == nil ? started : ended, kind: kind.feedKind,
                leftSeconds: kind == .breast ? (unchangedTime ? feed!.leftSeconds : totalSeconds) : 0,
                rightSeconds: kind == .breast && unchangedTime ? feed!.rightSeconds : 0,
                millilitres: bottleML, formulaMillilitres: formulaML,
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
                    Text("Shows time since the last feed started, its type and bottle volume on the Lock Screen and Dynamic Island. iOS limits an activity to eight hours; reopen the app or tap Show to restore it. You can swipe it away without deleting a feed.")
                }
                Section {
                    Button("Export backup", systemImage: "square.and.arrow.up") { export(json: true) }
                    Button("Export spreadsheet (CSV)", systemImage: "tablecells") { export(json: false) }
                    Button("Import backup", systemImage: "square.and.arrow.down") { importing = true }
                } header: { Text("Your records") } footer: {
                    Text("Backups include saved feeds, pumping sessions and the timer. Import adds missing entries and keeps existing records and your current timer. Export regularly before changing phones or removing the app.")
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
