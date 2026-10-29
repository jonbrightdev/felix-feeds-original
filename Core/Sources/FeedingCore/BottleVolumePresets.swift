import Foundation

public extension Ledger {
    /// Entry shortcuts based on completed bottles started in the last 168 hours.
    /// Pure and mixed bottles contribute their total; breastfeeding never implies a volume.
    func bottleVolumePresets(at now: Date = Date()) -> [Int] {
        let cutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let amounts = feeds.compactMap { feed -> Int? in
            guard feed.deletedAt == nil, feed.kind != .breast,
                  feed.startedAt >= cutoff, feed.startedAt <= now,
                  feed.endedAt >= feed.startedAt, feed.endedAt <= now,
                  let amount = feed.millilitres, (1...2000).contains(amount) else { return nil }
            return amount
        }
        guard !amounts.isEmpty else { return [70, 80, 90, 100, 110] }

        let average = amounts.reduce(0.0) { $0 + Double($1) } / Double(amounts.count)
        let roundedAverage = Int((average / 10).rounded(.up)) * 10
        // Shift the range near either limit, keeping five distinct, valid amounts
        // and retaining the rounded average among the choices.
        let first = min(1960, max(10, roundedAverage - 20))
        return (0..<5).map { first + $0 * 10 }
    }
}
