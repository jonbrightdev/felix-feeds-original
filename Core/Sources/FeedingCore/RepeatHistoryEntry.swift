import Foundation

public extension HistoryEntry {
    /// Creates an unsaved entry ending now, with its own identity and no sync metadata.
    func repeated(at now: Date = Date()) -> HistoryEntry {
        switch self {
        case .feed(let feed):
            return .feed(Feed(
                startedAt: feed.kind == .breast ? now.addingTimeInterval(-feed.duration) : now,
                endedAt: now, kind: feed.kind,
                leftSeconds: feed.leftSeconds, rightSeconds: feed.rightSeconds,
                millilitres: feed.millilitres, formulaMillilitres: feed.formulaMillilitres,
                estimatedMillilitres: feed.estimatedMillilitres, notes: feed.notes,
                isTopUp: feed.isTopUp == true))
        case .pump(let session):
            return .pump(PumpSession(pumpedAt: now, millilitres: session.millilitres, notes: session.notes))
        }
    }
}
