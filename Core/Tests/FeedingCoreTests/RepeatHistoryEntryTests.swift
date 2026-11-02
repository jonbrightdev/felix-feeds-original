import XCTest
@testable import FeedingCore

final class RepeatHistoryEntryTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRepeatBottlePreservesAmountsAndCreatesIndependentRecord() throws {
        let original = Feed(startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-3600),
                            kind: .expressed, millilitres: 120, formulaMillilitres: 40, notes: "Sample note",
                            deletedAt: now, revision: FeedRevision(counter: 3, device: UUID().uuidString), isTopUp: true)
        guard case .feed(let copy) = HistoryEntry.feed(original).repeated(at: now) else { return XCTFail() }
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.startedAt, now)
        XCTAssertEqual(copy.endedAt, now)
        XCTAssertEqual(copy.millilitres, 120)
        XCTAssertEqual(copy.formulaMillilitres, 40)
        XCTAssertEqual(copy.notes, original.notes)
        XCTAssertEqual(copy.isTopUp, true)
        XCTAssertNil(copy.revision)
        XCTAssertNil(copy.deletedAt)
        var ledger = Ledger()
        try ledger.upsert(original, now: now)
        try ledger.upsert(copy, now: now)
        XCTAssertEqual(ledger.feeds.count, 2)
        XCTAssertEqual(ledger.feeds.first { $0.id == original.id }, original)
    }

    func testRepeatBreastfeedingRetainsExactSideTimesAndUnknownVolume() throws {
        let original = Feed(startedAt: now.addingTimeInterval(-3600), endedAt: now.addingTimeInterval(-1800),
                            kind: .breast, leftSeconds: 300.25, rightSeconds: 240.5)
        guard case .feed(let copy) = HistoryEntry.feed(original).repeated(at: now) else { return XCTFail() }
        XCTAssertEqual(copy.leftSeconds, original.leftSeconds)
        XCTAssertEqual(copy.rightSeconds, original.rightSeconds)
        XCTAssertEqual(copy.startedAt, now.addingTimeInterval(-original.duration))
        XCTAssertEqual(copy.endedAt, now)
        XCTAssertNil(copy.millilitres)
        XCTAssertNil(copy.estimatedMillilitres)
        try copy.validate(now: now)
    }

    func testRepeatPumpingStaysSeparateFromIntake() throws {
        let original = PumpSession(pumpedAt: now.addingTimeInterval(-3600), millilitres: 90, notes: "Sample",
                                   deletedAt: now, revision: FeedRevision(counter: 2, device: UUID().uuidString))
        guard case .pump(let copy) = HistoryEntry.pump(original).repeated(at: now) else { return XCTFail() }
        XCTAssertNotEqual(copy.id, original.id)
        XCTAssertEqual(copy.pumpedAt, now)
        XCTAssertEqual(copy.millilitres, original.millilitres)
        XCTAssertEqual(copy.notes, original.notes)
        XCTAssertNil(copy.deletedAt)
        XCTAssertNil(copy.revision)
        var ledger = Ledger()
        try ledger.upsert(copy, now: now)
        XCTAssertTrue(ledger.feeds.isEmpty)
        XCTAssertEqual(ledger.pumpSessions, [copy])
    }
}
