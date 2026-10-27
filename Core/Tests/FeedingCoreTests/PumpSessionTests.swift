import XCTest
@testable import FeedingCore

final class PumpSessionTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1700000000)
    let caregiverB = "11111111-1111-4111-8111-111111111111"
    let caregiverA = "22222222-2222-4222-8222-222222222222"

    func testPumpingNeverChangesFeedsTimerLastFeedOrBottleTotals() throws {
        var ledger = Ledger()
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .expressed, millilitres: 90))
        try ledger.start(side: .left, now: base.addingTimeInterval(100))
        let active = ledger.active, glance = ledger.latestFeedGlance, feeds = ledger.feeds
        try ledger.upsert(PumpSession(pumpedAt: base.addingTimeInterval(160), millilitres: 140))
        XCTAssertEqual(ledger.active, active); XCTAssertEqual(ledger.latestFeedGlance, glance); XCTAssertEqual(ledger.feeds, feeds)
        XCTAssertEqual(ledger.volumeInLast24Hours(at: base.addingTimeInterval(200)).totalML, 90)
        XCTAssertEqual(ledger.pumpedInLast24Hours(at: base.addingTimeInterval(200)), PumpSummary(sessions: ledger.pumpSessions))
        XCTAssertEqual(ledger.pumpedInLast24Hours(at: base.addingTimeInterval(200)).totalML, 140)
        XCTAssertEqual(ledger.feeds(on: base).count, 1)
        XCTAssertEqual(ledger.visibleHistory.count, 2)
    }

    func testValidationAcceptsZeroAndRejectsFutureOrOutOfRangeAmounts() {
        XCTAssertNoThrow(try PumpSession(pumpedAt: base, millilitres: 0).validate(now: base))
        XCTAssertNoThrow(try PumpSession(pumpedAt: base, millilitres: 2000).validate(now: base))
        XCTAssertThrowsError(try PumpSession(pumpedAt: base, millilitres: -1).validate(now: base))
        XCTAssertThrowsError(try PumpSession(pumpedAt: base, millilitres: 2001).validate(now: base))
        XCTAssertThrowsError(try PumpSession(pumpedAt: base.addingTimeInterval(1), millilitres: 50).validate(now: base))
        XCTAssertThrowsError(try PumpSession(pumpedAt: base, millilitres: 50, notes: String(repeating: "a", count: 4001)).validate(now: base))
    }

    func testDailyAndRollingTotalsExcludeDeletedAndOtherDays() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = calendar.startOfDay(for: base)
        var ledger = Ledger()
        let morning = PumpSession(pumpedAt: day.addingTimeInterval(8 * 3600), millilitres: 120)
        let evening = PumpSession(pumpedAt: day.addingTimeInterval(20 * 3600), millilitres: 95)
        let yesterday = PumpSession(pumpedAt: day.addingTimeInterval(-3600), millilitres: 60)
        for session in [morning, evening, yesterday] { try ledger.upsert(session, now: day.addingTimeInterval(86_000)) }
        XCTAssertEqual(PumpSummary(sessions: ledger.pumpSessions(on: day, calendar: calendar)).totalML, 215)
        XCTAssertEqual(ledger.pumpedInLast24Hours(at: day.addingTimeInterval(21 * 3600)).totalML, 275)
        ledger.setPumpSessionDeleted(evening.id, at: base)
        let summary = PumpSummary(sessions: ledger.pumpSessions(on: day, calendar: calendar))
        XCTAssertEqual(summary.totalML, 120); XCTAssertEqual(summary.sessionCount, 1)
        XCTAssertEqual(PumpSummary(sessions: ledger.pumpSessions).totalML, 180)
        ledger.setPumpSessionDeleted(evening.id, at: nil)
        XCTAssertEqual(PumpSummary(sessions: ledger.pumpSessions(on: day, calendar: calendar)).totalML, 215)
    }

    func testPumpingSyncsOfflineWithoutRestampingFeedsAndDeletionDoesNotResurrect() throws {
        var a = Ledger(); try a.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90))
        try a.stampFeedChanges(since: Ledger(), device: caregiverB)
        var b = a; let oldA = a, oldB = b
        try a.upsert(PumpSession(pumpedAt: base.addingTimeInterval(10), millilitres: 100))
        try a.stampFeedChanges(since: oldA, device: caregiverB); try a.stampPumpSessionChanges(since: oldA, device: caregiverB)
        try b.upsert(PumpSession(pumpedAt: base.addingTimeInterval(20), millilitres: 80))
        try b.stampPumpSessionChanges(since: oldB, device: caregiverA)
        XCTAssertGreaterThan(a.pumpSessions[0].revision!.counter, a.feeds[0].revision!.counter)
        let left = a.pumpSessions
        try a.mergeSharedPumpSessions(b.pumpSessions); try b.mergeSharedPumpSessions(left)
        XCTAssertEqual(a.pumpSessions, b.pumpSessions); XCTAssertEqual(a.feeds, oldA.feeds)
        let beforeDelete = a
        a.setPumpSessionDeleted(a.pumpSessions[0].id, at: base.addingTimeInterval(30))
        try a.stampPumpSessionChanges(since: beforeDelete, device: caregiverB)
        try a.mergeSharedPumpSessions(b.pumpSessions)
        XCTAssertEqual(a.visiblePumpSessions.count, 1)
    }

    func testConcurrentPumpingEditsHaveDeterministicWinner() throws {
        var initial = Ledger(); try initial.upsert(PumpSession(pumpedAt: base, millilitres: 100))
        try initial.stampPumpSessionChanges(since: Ledger(), device: caregiverB)
        var a = initial, b = initial
        a.pumpSessions[0].millilitres = 110; b.pumpSessions[0].millilitres = 120
        try a.stampPumpSessionChanges(since: initial, device: caregiverB); try b.stampPumpSessionChanges(since: initial, device: caregiverA)
        let left = a.pumpSessions, right = b.pumpSessions
        try a.mergeSharedPumpSessions(right); try b.mergeSharedPumpSessions(left)
        XCTAssertEqual(a.pumpSessions, b.pumpSessions); XCTAssertEqual(a.pumpSessions[0].millilitres, 120)
    }

    func testOlderBackupsLoadWithoutPumpingAndNewBackupsImportIdempotently() throws {
        var ledger = Ledger(); try ledger.upsert(PumpSession(pumpedAt: base, millilitres: 130, notes: "Morning"))
        try ledger.start(side: .right, now: base)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(url: directory.appendingPathComponent("history.json"))
        try repository.save(ledger); XCTAssertEqual(try repository.load(), ledger)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as! [String: Any]
        object.removeValue(forKey: "pumpSessions")
        let legacy = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.pumpSessions.isEmpty); XCTAssertEqual(legacy.active, ledger.active)
        var imported = Ledger(); try imported.start(side: .left, now: base.addingTimeInterval(1))
        let active = imported.active
        XCTAssertEqual(try imported.merge(ledger), 1); XCTAssertEqual(try imported.merge(ledger), 0)
        XCTAssertEqual(imported.active, active); XCTAssertEqual(imported.pumpSessions, ledger.pumpSessions)
    }

    func testEncryptionRejectsWrongKeysTamperingAndCrossCollectionSubstitution() throws {
        let key = Data(repeating: 42, count: 32)
        let session = PumpSession(pumpedAt: base, millilitres: 150, notes: "Private pumping", revision: FeedRevision(counter: 1, device: caregiverB))
        let packet = try HistoryPacket.seal(session, key: key)
        XCTAssertEqual(try packet.openPumpSession(key: key), session)
        XCTAssertFalse(packet.ciphertext.contains("Private pumping"))
        XCTAssertThrowsError(try packet.open(key: key))
        XCTAssertThrowsError(try packet.openHungerCue(key: key))
        XCTAssertThrowsError(try packet.openPumpSession(key: Data(repeating: 43, count: 32)))
        var changed = packet; changed.counter = "2"
        XCTAssertThrowsError(try changed.openPumpSession(key: key))
        let cue = HungerCue(recordedAt: base, revision: FeedRevision(counter: 1, device: caregiverB))
        XCTAssertThrowsError(try HistoryPacket.seal(cue, key: key).openPumpSession(key: key))
        let feed = Feed(startedAt: base, endedAt: base, kind: .expressed, millilitres: 60, revision: FeedRevision(counter: 1, device: caregiverB))
        XCTAssertThrowsError(try HistoryPacket.seal(feed, key: key).openPumpSession(key: key))
    }

    func testInvalidBatchIsAtomicAndDuplicateBackupIDsAreRejected() throws {
        var ledger = Ledger(); try ledger.upsert(PumpSession(pumpedAt: base, millilitres: 100))
        let before = ledger
        XCTAssertThrowsError(try ledger.mergeSharedPumpSessions([PumpSession(pumpedAt: base, millilitres: 90),
                                                                 PumpSession(pumpedAt: base, millilitres: 5000)]))
        XCTAssertEqual(ledger, before)
        ledger.pumpSessions.append(ledger.pumpSessions[0]); XCTAssertThrowsError(try ledger.validate())
    }

    func testTimelineAndCSVKeepPumpingSeparateFromFeeds() throws {
        var ledger = Ledger()
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90))
        let session = PumpSession(pumpedAt: base.addingTimeInterval(60), millilitres: 145, notes: "=not a formula")
        try ledger.upsert(session)
        XCTAssertEqual(ledger.visibleHistory.first, .pump(session))
        XCTAssertEqual(ledger.history(on: base).count, 2)
        XCTAssertTrue(ledger.csv().contains("\"Pumping\",\"\",\"\",\"145\",\"'=not a formula\""))
        ledger.setPumpSessionDeleted(session.id, at: base.addingTimeInterval(120))
        XCTAssertEqual(ledger.visibleHistory.count, 1); XCTAssertFalse(ledger.csv().contains("Pumping"))
    }
}
