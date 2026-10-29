import Foundation

/// Completed records grouped by their local start date, like History.
/// Zero totals mean no records were logged, not that no feeding took place.
public struct FeedingDay: Identifiable, Equatable, Sendable {
    public var id: Date { date }
    public let date: Date
    public let feedCount: Int
    public let volume: VolumeSummary
    public let leftSeconds: TimeInterval
    public let rightSeconds: TimeInterval
    public var breastSeconds: TimeInterval { leftSeconds + rightSeconds }
    public var hasRecords: Bool { feedCount > 0 }
}

public extension Ledger {
    /// Calendar arithmetic preserves local midnight across 23/25-hour DST days.
    /// Active timers, deleted records and future records never enter chart totals.
    func feedingDays(count: Int, endingAt now: Date = Date(), calendar: Calendar = .current) -> [FeedingDay] {
        guard count > 0 else { return [] }
        let today = calendar.startOfDay(for: now)
        guard let first = calendar.date(byAdding: .day, value: 1 - count, to: today) else { return [] }
        let feedsByDay = Dictionary(grouping: feeds.filter {
            $0.deletedAt == nil && $0.startedAt >= first && $0.startedAt <= now && $0.endedAt <= now
        }) { calendar.startOfDay(for: $0.startedAt) }
        return (0..<count).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: first) else { return nil }
            let records = feedsByDay[date] ?? []
            let breast = records.filter { $0.kind == .breast }
            return FeedingDay(date: date, feedCount: records.count,
                              volume: VolumeSummary(feeds: records),
                              leftSeconds: breast.reduce(0) { $0 + $1.leftSeconds },
                              rightSeconds: breast.reduce(0) { $0 + $1.rightSeconds })
        }
    }
}

/// One step in the running milk total for a calendar day.
public struct MilkProgressPoint: Equatable, Sendable {
    public let time: Date
    public let totalML: Int
    public init(time: Date, totalML: Int) { self.time = time; self.totalML = totalML }
}

extension Ledger {
    /// Starts at 0 ml at local midnight and steps up at each feed's start, so the
    /// final value matches that day's total. Stops at `end`, or at the next midnight.
    public func milkProgress(on day: Date, until end: Date? = nil, calendar: Calendar = .current) -> [MilkProgressPoint] {
        let start = calendar.startOfDay(for: day)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let last = max(start, min(end ?? dayEnd, dayEnd))
        var total = 0
        var points = [MilkProgressPoint(time: start, totalML: 0)]
        for feed in feeds(on: day, calendar: calendar).reversed() where feed.startedAt <= last {
            let millilitres = VolumeSummary(feeds: [feed]).totalML
            guard millilitres > 0 else { continue }
            total += millilitres
            points.append(MilkProgressPoint(time: feed.startedAt, totalML: total))
        }
        points.append(MilkProgressPoint(time: last, totalML: total))
        return points
    }
}
