import Foundation

public enum Side: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, right
    public var id: String { rawValue }
    public var title: String { L10n.text(self == .left ? "Left" : "Right") }
    public var sideLabel: String { L10n.text(self == .left ? "Left side" : "Right side") }
}

public enum FeedKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case breast, expressed, formula
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .breast: L10n.text("Breast")
        case .expressed: L10n.text("Expressed milk")
        case .formula: L10n.text("Formula")
        }
    }
}

public enum FeedingError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): L10n.text(reason) }
    }
}

public struct Feed: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date
    public var kind: FeedKind
    public var leftSeconds: TimeInterval
    public var rightSeconds: TimeInterval
    public var millilitres: Int?
    public var estimatedMillilitres: Int?
    public var notes: String
    public var deletedAt: Date?
    public var revision: FeedRevision?

    public init(id: UUID = UUID(), startedAt: Date, endedAt: Date, kind: FeedKind,
                leftSeconds: TimeInterval = 0, rightSeconds: TimeInterval = 0,
                millilitres: Int? = nil, estimatedMillilitres: Int? = nil, notes: String = "", deletedAt: Date? = nil,
                revision: FeedRevision? = nil) {
        self.id = id; self.startedAt = startedAt; self.endedAt = endedAt
        self.kind = kind; self.leftSeconds = leftSeconds; self.rightSeconds = rightSeconds
        self.millilitres = millilitres; self.estimatedMillilitres = estimatedMillilitres; self.notes = notes; self.deletedAt = deletedAt
        self.revision = revision
    }
    public var duration: TimeInterval { leftSeconds + rightSeconds }
    public var sideLabel: String {
        if leftSeconds > 0 && rightSeconds > 0 { return L10n.text("Both sides") }
        return L10n.text(leftSeconds > 0 ? "Left side" : "Right side")
    }
    public func validate(now: Date = Date()) throws {
        guard startedAt <= now, endedAt <= now, endedAt >= startedAt else {
            throw FeedingError.invalid("Choose a start and end in the past, with the end after the start.")
        }
        guard leftSeconds.isFinite, rightSeconds.isFinite, leftSeconds >= 0, rightSeconds >= 0,
              duration <= endedAt.timeIntervalSince(startedAt) + 1 else {
            throw FeedingError.invalid("Feeding time cannot exceed the time between the start and end.")
        }
        if kind == .breast {
            guard duration > 0, millilitres == nil else {
                throw FeedingError.invalid("Enter some time spent breastfeeding.")
            }
            if let estimatedMillilitres, !(0...2000).contains(estimatedMillilitres) {
                throw FeedingError.invalid("Enter an estimated amount between 0 and 2,000 ml, or leave it blank.")
            }
        } else {
            guard let millilitres, (1...2000).contains(millilitres), duration == 0, estimatedMillilitres == nil else {
                throw FeedingError.invalid("Enter a bottle amount between 1 and 2,000 ml.")
            }
        }
        guard notes.count <= 4000 else { throw FeedingError.invalid("Please keep notes under 4,000 characters.") }
    }
}

// The timer is computed from timestamps, so no background execution is needed.
public struct ActiveFeed: Codable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var startedAt: Date
    public var side: Side
    public var leftSeconds: TimeInterval = 0
    public var rightSeconds: TimeInterval = 0
    public var runningSince: Date?

    public init(side: Side, now: Date) {
        self.side = side; startedAt = now; runningSince = now
    }
    public func seconds(for side: Side, at now: Date) -> TimeInterval {
        let stored = side == .left ? leftSeconds : rightSeconds
        return stored + (self.side == side ? runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0 : 0)
    }
    public mutating func pause(at now: Date) {
        leftSeconds = seconds(for: .left, at: now)
        rightSeconds = seconds(for: .right, at: now)
        runningSince = nil
    }
    public mutating func resume(at now: Date) {
        if runningSince == nil { runningSince = now }
    }
    public mutating func switchSide(to side: Side, at now: Date) {
        guard side != self.side else { return }
        let wasRunning = runningSince != nil
        pause(at: now); self.side = side
        if wasRunning { resume(at: now) }
    }
    public func completed(at now: Date) -> Feed {
        Feed(id: id, startedAt: startedAt, endedAt: now, kind: .breast,
             leftSeconds: seconds(for: .left, at: now), rightSeconds: seconds(for: .right, at: now))
    }
}

public struct FeedGlance: Equatable, Sendable {
    public let id: UUID
    public let startedAt: Date
    public let kind: FeedKind
    public let millilitres: Int?
    public let isFeeding: Bool
    public let isPaused: Bool
    public let side: Side?
}

public struct VolumeSummary: Equatable, Sendable {
    public let expressedML: Int
    public let formulaML: Int
    public let bottleCount: Int
    public let estimatedBreastML: Int
    public var bottleML: Int { expressedML + formulaML }
    public var totalML: Int { bottleML + estimatedBreastML }

    public init(feeds: [Feed]) {
        let bottles = feeds.filter { $0.deletedAt == nil && $0.kind != .breast }
        expressedML = bottles.filter { $0.kind == .expressed }.reduce(0) { $0 + ($1.millilitres ?? 0) }
        formulaML = bottles.filter { $0.kind == .formula }.reduce(0) { $0 + ($1.millilitres ?? 0) }
        bottleCount = bottles.count
        estimatedBreastML = feeds.filter { $0.deletedAt == nil && $0.kind == .breast }
            .reduce(0) { $0 + ($1.estimatedMillilitres ?? 0) }
    }
}

public struct Ledger: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var feeds: [Feed] = []
    public var hungerCues: [HungerCue] = []
    public var pumpSessions: [PumpSession] = []
    public var active: ActiveFeed?
    public var sharedHistoryID: String?
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, feeds, hungerCues, pumpSessions, active, sharedHistoryID }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        feeds = try values.decode([Feed].self, forKey: .feeds)
        hungerCues = try values.decodeIfPresent([HungerCue].self, forKey: .hungerCues) ?? []
        pumpSessions = try values.decodeIfPresent([PumpSession].self, forKey: .pumpSessions) ?? []
        active = try values.decodeIfPresent(ActiveFeed.self, forKey: .active)
        sharedHistoryID = try values.decodeIfPresent(String.self, forKey: .sharedHistoryID)
    }
    public var visibleFeeds: [Feed] {
        feeds.filter { $0.deletedAt == nil }.sorted { $0.startedAt > $1.startedAt }
    }
    public var latestFeedGlance: FeedGlance? {
        let last = visibleFeeds.first
        if let active, last.map({ active.startedAt >= $0.startedAt }) ?? true {
            return FeedGlance(id: active.id, startedAt: active.startedAt, kind: .breast,
                              millilitres: nil, isFeeding: true, isPaused: active.runningSince == nil,
                              side: active.side)
        }
        guard let last else { return nil }
        return FeedGlance(id: last.id, startedAt: last.startedAt, kind: last.kind,
                          millilitres: last.millilitres, isFeeding: false, isPaused: false, side: nil)
    }
    public func validate(now: Date = Date()) throws {
        guard version == 1 else { throw FeedingError.invalid("This backup uses an unsupported data version.") }
        guard Set(feeds.map(\.id)).count == feeds.count else {
            throw FeedingError.invalid("This file contains duplicate feeding records.")
        }
        for feed in feeds { try feed.validate(now: now) }
        guard Set(hungerCues.map(\.id)).count == hungerCues.count else {
            throw FeedingError.invalid("This file contains duplicate hunger observations.")
        }
        for cue in hungerCues { try cue.validate(now: now) }
        guard Set(pumpSessions.map(\.id)).count == pumpSessions.count else {
            throw FeedingError.invalid("This file contains duplicate pumping sessions.")
        }
        for session in pumpSessions { try session.validate(now: now) }
        if let active {
            guard active.startedAt <= now, active.leftSeconds.isFinite, active.rightSeconds.isFinite,
                  active.leftSeconds >= 0, active.rightSeconds >= 0,
                  active.leftSeconds + active.rightSeconds <= now.timeIntervalSince(active.startedAt) + 1,
                  active.runningSince.map({ $0 >= active.startedAt && $0 <= now }) ?? true else {
                throw FeedingError.invalid("The saved timer has invalid timestamps.")
            }
        }
    }
    public mutating func upsert(_ feed: Feed, now: Date = Date()) throws {
        try feed.validate(now: now)
        if let index = feeds.firstIndex(where: { $0.id == feed.id }) { feeds[index] = feed }
        else { feeds.append(feed) }
    }
    public mutating func start(side: Side, now: Date) throws {
        guard active == nil else { throw FeedingError.invalid("Finish the current feed first.") }
        active = ActiveFeed(side: side, now: now)
    }
    public mutating func finish(now: Date) throws {
        guard let active else { return }
        try upsert(active.completed(at: now), now: now)
        self.active = nil
    }
    public mutating func setDeleted(_ id: UUID, at date: Date?) {
        guard let index = feeds.firstIndex(where: { $0.id == id }) else { return }
        feeds[index].deletedAt = date
    }
    // Restoring a backup never replaces local records or a running timer.
    public mutating func merge(_ other: Ledger, now: Date = Date()) throws -> Int {
        try other.validate(now: now)
        let ids = Set(feeds.map(\.id))
        let additions = other.feeds.filter { !ids.contains($0.id) }
        feeds.append(contentsOf: additions)
        let cueIDs = Set(hungerCues.map(\.id))
        let cueAdditions = other.hungerCues.filter { !cueIDs.contains($0.id) }
        hungerCues.append(contentsOf: cueAdditions)
        let pumpIDs = Set(pumpSessions.map(\.id))
        let pumpAdditions = other.pumpSessions.filter { !pumpIDs.contains($0.id) }
        pumpSessions.append(contentsOf: pumpAdditions)
        return additions.count + cueAdditions.count + pumpAdditions.count
    }
    public func feeds(on day: Date, calendar: Calendar = .current) -> [Feed] {
        visibleFeeds.filter { calendar.isDate($0.startedAt, inSameDayAs: day) }
    }
    public func volumeInLast24Hours(at now: Date = Date()) -> VolumeSummary {
        VolumeSummary(feeds: visibleFeeds.filter {
            $0.startedAt >= now.addingTimeInterval(-86_400) && $0.startedAt <= now
        })
    }
    public func csv() -> String {
        let iso = ISO8601DateFormatter()
        func quote(_ text: String) -> String {
            // Prevent spreadsheet formula execution from free-form notes.
            let safe = text.first.map { "=+-@\t\r\n".contains($0) } == true ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        let rows = visibleHistory.reversed().map { entry -> String in
            let cells: [String]
            switch entry {
            case .feed(let feed):
                cells = [iso.string(from: feed.startedAt), iso.string(from: feed.endedAt), (feed.kind == .breast ? "Breast" : feed.kind == .expressed ? "Expressed milk" : "Formula"),
                         String(Int(feed.leftSeconds)), String(Int(feed.rightSeconds)), feed.millilitres.map(String.init) ?? "", feed.notes, feed.estimatedMillilitres.map(String.init) ?? ""]
            case .hunger(let cue):
                cells = [iso.string(from: cue.recordedAt), "", "Hunger signs", "", "", "", cue.notes, ""]
            case .pump(let session):
                // Pumped output shares the millilitres column; the type keeps it apart from bottle intake.
                cells = [iso.string(from: session.pumpedAt), "", "Pumping", "", "", String(session.millilitres), session.notes, ""]
            }
            return cells.map(quote).joined(separator: ",")
        }
        return (["start_utc,end_utc,type,left_seconds,right_seconds,millilitres,notes,estimated_millilitres"] + rows).joined(separator: "\r\n")
    }
}

public struct LedgerRepository: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> Ledger {
        guard FileManager.default.fileExists(atPath: url.path) else { return Ledger() }
        let ledger = try JSONDecoder().decode(Ledger.self, from: Data(contentsOf: url))
        try ledger.validate()
        return ledger
    }
    public func save(_ ledger: Ledger) throws {
        try ledger.validate()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Atomic replacement keeps the last committed file intact if a write fails.
        try encoder.encode(ledger).write(to: url, options: .atomic)
    }
}
