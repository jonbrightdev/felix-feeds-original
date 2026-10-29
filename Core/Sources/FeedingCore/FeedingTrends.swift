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
