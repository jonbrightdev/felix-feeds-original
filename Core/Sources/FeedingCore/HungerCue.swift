import Foundation

/// An observation, independent of feeds and the active breast timer.
/// The app no longer logs or shows these. Saved, backed-up and shared records are
/// still decoded, merged and synced so older backups and paired phones stay compatible.
public struct HungerCue: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var recordedAt: Date
    public var notes: String
    public var deletedAt: Date?
    public var revision: FeedRevision?
    public init(id: UUID = UUID(), recordedAt: Date = Date(), notes: String = "", deletedAt: Date? = nil, revision: FeedRevision? = nil) {
        self.id = id; self.recordedAt = recordedAt; self.notes = notes
        self.deletedAt = deletedAt; self.revision = revision
    }
    public func validate(now: Date = Date()) throws {
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite, recordedAt <= now, notes.count <= 4000 else {
            throw FeedingError.invalid("Choose an observation time in the past and keep notes under 4,000 characters.")
        }
        if let revision {
            guard revision.counter > 0, UUID(uuidString: revision.device) != nil else {
                throw FeedingError.invalid("A hunger observation has an invalid revision.")
            }
        }
    }
    public static func preferred(_ first: Self, _ second: Self) throws -> Self {
        guard first.id == second.id else { throw FeedingError.invalid("Cannot merge different observation IDs.") }
        let zero = FeedRevision(counter: 0, device: "")
        if first.revision != second.revision { return (first.revision ?? zero) > (second.revision ?? zero) ? first : second }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(first).lexicographicallyPrecedes(encoder.encode(second)) ? second : first
    }
}

public enum HistoryEntry: Identifiable, Equatable, Sendable {
    case feed(Feed), pump(PumpSession)
    public var id: String {
        switch self {
        case .feed(let feed): "feed/\(feed.id)"
        case .pump(let session): "pump/\(session.id)"
        }
    }
    public var date: Date {
        switch self {
        case .feed(let feed): feed.startedAt
        case .pump(let session): session.pumpedAt
        }
    }
}

public extension Ledger {
    var visibleHungerCues: [HungerCue] { hungerCues.filter { $0.deletedAt == nil }.sorted { $0.recordedAt > $1.recordedAt } }
    var visibleHistory: [HistoryEntry] {
        (visibleFeeds.map(HistoryEntry.feed) + visiblePumpSessions.map(HistoryEntry.pump)).sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
    }
    func history(on day: Date, calendar: Calendar = .current) -> [HistoryEntry] {
        visibleHistory.filter { calendar.isDate($0.date, inSameDayAs: day) }
    }
    mutating func upsert(_ cue: HungerCue, now: Date = Date()) throws {
        try cue.validate(now: now)
        if let index = hungerCues.firstIndex(where: { $0.id == cue.id }) { hungerCues[index] = cue }
        else { hungerCues.append(cue) }
    }
    mutating func setHungerCueDeleted(_ id: UUID, at date: Date?) {
        guard let index = hungerCues.firstIndex(where: { $0.id == id }) else { return }
        hungerCues[index].deletedAt = date
    }
    mutating func stampHungerCueChanges(since previous: Ledger, device: String) throws {
        let old = Dictionary(uniqueKeysWithValues: previous.hungerCues.map { ($0.id, $0) })
        var counter = Swift.max(highestRevisionCounter, previous.highestRevisionCounter)
        for index in hungerCues.indices {
            var candidate = hungerCues[index]; candidate.revision = nil
            var prior = old[candidate.id]; prior?.revision = nil
            guard candidate != prior else { continue }
            guard counter < Int64.max else { throw FeedingError.invalid("The shared history revision limit was reached.") }
            counter += 1; hungerCues[index].revision = FeedRevision(counter: counter, device: device)
        }
    }
    mutating func mergeSharedHungerCues(_ incoming: [HungerCue], now: Date = Date()) throws {
        var records = Dictionary(uniqueKeysWithValues: hungerCues.map { ($0.id, $0) })
        for cue in incoming {
            try cue.validate(now: now)
            records[cue.id] = try records[cue.id].map { try HungerCue.preferred($0, cue) } ?? cue
        }
        hungerCues = records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
