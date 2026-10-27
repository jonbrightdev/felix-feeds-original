import Foundation

/// Milk expressed with a pump, recorded as the combined output from both sides.
/// Pumped milk is never counted as milk drunk; bottles record intake separately.
public struct PumpSession: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var pumpedAt: Date
    public var millilitres: Int
    public var notes: String
    public var deletedAt: Date?
    public var revision: FeedRevision?
    public init(id: UUID = UUID(), pumpedAt: Date = Date(), millilitres: Int, notes: String = "",
                deletedAt: Date? = nil, revision: FeedRevision? = nil) {
        self.id = id; self.pumpedAt = pumpedAt; self.millilitres = millilitres; self.notes = notes
        self.deletedAt = deletedAt; self.revision = revision
    }
    public func validate(now: Date = Date()) throws {
        guard pumpedAt.timeIntervalSinceReferenceDate.isFinite, pumpedAt <= now else {
            throw FeedingError.invalid("Choose a pumping time in the past.")
        }
        guard (0...2000).contains(millilitres) else {
            throw FeedingError.invalid("Enter a combined pumped amount between 0 and 2,000 ml.")
        }
        guard notes.count <= 4000 else { throw FeedingError.invalid("Please keep notes under 4,000 characters.") }
        if let revision {
            guard revision.counter > 0, UUID(uuidString: revision.device) != nil else {
                throw FeedingError.invalid("A pumping session has an invalid revision.")
            }
        }
    }
    public static func preferred(_ first: Self, _ second: Self) throws -> Self {
        guard first.id == second.id else { throw FeedingError.invalid("Cannot merge different pumping session IDs.") }
        let zero = FeedRevision(counter: 0, device: "")
        if first.revision != second.revision { return (first.revision ?? zero) > (second.revision ?? zero) ? first : second }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(first).lexicographicallyPrecedes(encoder.encode(second)) ? second : first
    }
}

public struct PumpSummary: Equatable, Sendable {
    public let sessionCount: Int
    public let totalML: Int
    public init(sessions: [PumpSession]) {
        let visible = sessions.filter { $0.deletedAt == nil }
        sessionCount = visible.count
        totalML = visible.reduce(0) { $0 + $1.millilitres }
    }
}

public extension Ledger {
    var visiblePumpSessions: [PumpSession] { pumpSessions.filter { $0.deletedAt == nil }.sorted { $0.pumpedAt > $1.pumpedAt } }
    func pumpSessions(on day: Date, calendar: Calendar = .current) -> [PumpSession] {
        visiblePumpSessions.filter { calendar.isDate($0.pumpedAt, inSameDayAs: day) }
    }
    func pumpedInLast24Hours(at now: Date = Date()) -> PumpSummary {
        PumpSummary(sessions: visiblePumpSessions.filter {
            $0.pumpedAt >= now.addingTimeInterval(-86_400) && $0.pumpedAt <= now
        })
    }
    mutating func upsert(_ session: PumpSession, now: Date = Date()) throws {
        try session.validate(now: now)
        if let index = pumpSessions.firstIndex(where: { $0.id == session.id }) { pumpSessions[index] = session }
        else { pumpSessions.append(session) }
    }
    mutating func setPumpSessionDeleted(_ id: UUID, at date: Date?) {
        guard let index = pumpSessions.firstIndex(where: { $0.id == id }) else { return }
        pumpSessions[index].deletedAt = date
    }
    mutating func stampPumpSessionChanges(since previous: Ledger, device: String) throws {
        let old = Dictionary(uniqueKeysWithValues: previous.pumpSessions.map { ($0.id, $0) })
        var counter = Swift.max(highestRevisionCounter, previous.highestRevisionCounter)
        for index in pumpSessions.indices {
            var candidate = pumpSessions[index]; candidate.revision = nil
            var prior = old[candidate.id]; prior?.revision = nil
            guard candidate != prior else { continue }
            guard counter < Int64.max else { throw FeedingError.invalid("The shared history revision limit was reached.") }
            counter += 1; pumpSessions[index].revision = FeedRevision(counter: counter, device: device)
        }
    }
    mutating func mergeSharedPumpSessions(_ incoming: [PumpSession], now: Date = Date()) throws {
        var records = Dictionary(uniqueKeysWithValues: pumpSessions.map { ($0.id, $0) })
        for session in incoming {
            try session.validate(now: now)
            records[session.id] = try records[session.id].map { try PumpSession.preferred($0, session) } ?? session
        }
        // Commit only after the entire incoming batch has passed validation.
        pumpSessions = records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    /// One logical clock across feeds, observations and pumping keeps revisions monotonic.
    var highestRevisionCounter: Int64 {
        (feeds.compactMap(\.revision?.counter) + hungerCues.compactMap(\.revision?.counter) +
         pumpSessions.compactMap(\.revision?.counter)).max() ?? 0
    }
}
