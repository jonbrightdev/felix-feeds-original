import Foundation

// A logical clock makes offline edits deterministic without relying on phone clocks.
public struct FeedRevision: Codable, Equatable, Comparable, Sendable {
    public var counter: Int64
    public var device: String
    public init(counter: Int64, device: String) { self.counter = counter; self.device = device }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.counter == rhs.counter ? lhs.device < rhs.device : lhs.counter < rhs.counter
    }
}

public extension Feed {
    static func preferred(_ first: Feed, _ second: Feed) throws -> Feed {
        guard first.id == second.id else { throw FeedingError.invalid("Cannot merge different feed IDs.") }
        let zero = FeedRevision(counter: 0, device: "")
        let left = first.revision ?? zero
        let right = second.revision ?? zero
        if left != right { return left > right ? first : second }
        if first == second { return first }
        // Stable fallback for legacy imports or duplicate objects with the same revision.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(first).lexicographicallyPrecedes(encoder.encode(second)) ? second : first
    }
}

public extension Ledger {
    mutating func stampFeedChanges(since previous: Ledger, device: String) throws {
        let old = Dictionary(uniqueKeysWithValues: previous.feeds.map { ($0.id, $0) })
        var counter = max(highestRevisionCounter, previous.highestRevisionCounter)
        for index in feeds.indices {
            var candidate = feeds[index]; candidate.revision = nil
            var prior = old[candidate.id]; prior?.revision = nil
            guard candidate != prior else { continue }
            guard counter < Int64.max else { throw FeedingError.invalid("The shared history revision limit was reached.") }
            counter += 1
            feeds[index].revision = FeedRevision(counter: counter, device: device)
        }
    }

    mutating func mergeSharedFeeds(_ incoming: [Feed], now: Date = Date()) throws {
        var records = Dictionary(uniqueKeysWithValues: feeds.map { ($0.id, $0) })
        for feed in incoming {
            try feed.validate(now: now)
            if let revision = feed.revision {
                guard revision.counter > 0, !revision.device.isEmpty, revision.device.count <= 128 else {
                    throw FeedingError.invalid("A shared feed has an invalid revision.")
                }
            }
            records[feed.id] = try records[feed.id].map { try Feed.preferred($0, feed) } ?? feed
        }
        // Commit only after the entire incoming batch has passed validation.
        feeds = records.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }
}
