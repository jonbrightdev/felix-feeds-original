import XCTest
@testable import FeedingCore

final class HungerCueTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1700000000)
    let caregiverB = "11111111-1111-4111-8111-111111111111"
    let caregiverA = "22222222-2222-4222-8222-222222222222"
    func testLoggingWhileRunningAndPausedNeverChangesTimerOrLastFeedOrTotals() throws {
        var ledger = Ledger()
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90))
        try ledger.start(side: .left, now: base.addingTimeInterval(100))
        let active = ledger.active, glance = ledger.latestFeedGlance, feeds = ledger.feeds
        try ledger.upsert(HungerCue(recordedAt: base.addingTimeInterval(160)))
        XCTAssertEqual(ledger.active, active); XCTAssertEqual(ledger.latestFeedGlance, glance); XCTAssertEqual(ledger.feeds, feeds)
        XCTAssertEqual(ledger.active?.seconds(for: .left, at: base.addingTimeInterval(190)), 90)
        ledger.active?.pause(at: base.addingTimeInterval(190))
        let paused = ledger.active
        try ledger.upsert(HungerCue(recordedAt: base.addingTimeInterval(200)))
        XCTAssertEqual(ledger.active, paused)
        XCTAssertEqual(ledger.visibleFeeds.count, 1); XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 90)
        ledger.active = nil
        XCTAssertEqual(ledger.latestFeedGlance?.startedAt, base)
        XCTAssertEqual(ledger.visibleHistory.count, 1); XCTAssertEqual(ledger.hungerCues.count, 2)
    }
    func testObservationsSyncOfflineWithoutRestampingFeedsAndDeletionDoesNotResurrect() throws {
        var a = Ledger(); try a.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90))
        try a.stampFeedChanges(since: Ledger(), device: caregiverB)
        var b = a; let oldA = a, oldB = b
        try a.upsert(HungerCue(recordedAt: base.addingTimeInterval(10)))
        try a.stampFeedChanges(since: oldA, device: caregiverB); try a.stampHungerCueChanges(since: oldA, device: caregiverB)
        try b.upsert(HungerCue(recordedAt: base.addingTimeInterval(20)))
        try b.stampHungerCueChanges(since: oldB, device: caregiverA)
        let left = a.hungerCues
        try a.mergeSharedHungerCues(b.hungerCues); try b.mergeSharedHungerCues(left)
        XCTAssertEqual(a.hungerCues, b.hungerCues); XCTAssertEqual(a.feeds, oldA.feeds)
        let beforeDelete = a
        a.setHungerCueDeleted(a.hungerCues[0].id, at: base.addingTimeInterval(30))
        try a.stampHungerCueChanges(since: beforeDelete, device: caregiverB)
        try a.mergeSharedHungerCues(b.hungerCues)
        XCTAssertEqual(a.visibleHungerCues.count, 1)
        let deleted = a
        a.setHungerCueDeleted(a.hungerCues[0].id, at: nil)
        try a.stampHungerCueChanges(since: deleted, device: caregiverA)
        XCTAssertEqual(a.visibleHungerCues.count, 2)
    }
    func testConcurrentObservationEditsHaveDeterministicWinner() throws {
        var initial = Ledger(); try initial.upsert(HungerCue(recordedAt: base))
        try initial.stampHungerCueChanges(since: Ledger(), device: caregiverB)
        var a = initial, b = initial
        a.hungerCues[0].notes = "Hand to mouth"; b.hungerCues[0].notes = "Rooting"
        try a.stampHungerCueChanges(since: initial, device: caregiverB); try b.stampHungerCueChanges(since: initial, device: caregiverA)
        let left = a.hungerCues, right = b.hungerCues
        try a.mergeSharedHungerCues(right); try b.mergeSharedHungerCues(left)
        XCTAssertEqual(a.hungerCues, b.hungerCues); XCTAssertEqual(a.hungerCues[0].notes, "Rooting")
    }
    func testLegacyBackupDefaultsToNoObservationsAndNewBackupImportsIdempotently() throws {
        var ledger = Ledger(); try ledger.upsert(HungerCue(recordedAt: base, notes: "Observation"))
        try ledger.start(side: .right, now: base)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LedgerRepository(url: directory.appendingPathComponent("history.json"))
        try repository.save(ledger); XCTAssertEqual(try repository.load(), ledger)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger)) as! [String: Any]
        object.removeValue(forKey: "hungerCues")
        let legacy = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.hungerCues.isEmpty); XCTAssertEqual(legacy.active, ledger.active)
        var imported = Ledger(); try imported.start(side: .left, now: base.addingTimeInterval(1))
        let active = imported.active
        // Legacy observations are kept on import but are not counted as visible entries.
        XCTAssertEqual(try imported.merge(ledger), 0); XCTAssertEqual(try imported.merge(ledger), 0)
        XCTAssertEqual(imported.active, active); XCTAssertEqual(imported.hungerCues, ledger.hungerCues)
    }
    func testEncryptionRejectsWrongKeysTamperingAndCrossCollectionSubstitution() throws {
        let key = Data(repeating: 42, count: 32)
        let cue = HungerCue(recordedAt: base, notes: "Private observation", revision: FeedRevision(counter: 1, device: caregiverB))
        let packet = try HistoryPacket.seal(cue, key: key)
        XCTAssertEqual(try packet.openHungerCue(key: key), cue)
        XCTAssertFalse(packet.ciphertext.contains("Private observation"))
        XCTAssertThrowsError(try packet.open(key: key))
        XCTAssertThrowsError(try packet.openHungerCue(key: Data(repeating: 43, count: 32)))
        var changed = packet; changed.counter = "2"
        XCTAssertThrowsError(try changed.openHungerCue(key: key))
        let feed = Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 60, revision: FeedRevision(counter: 1, device: caregiverB))
        XCTAssertThrowsError(try HistoryPacket.seal(feed, key: key).openHungerCue(key: key))
    }
    func testInvalidBatchIsAtomicAndDuplicateBackupIDsAreRejected() throws {
        var ledger = Ledger(); try ledger.upsert(HungerCue(recordedAt: base))
        let before = ledger
        XCTAssertThrowsError(try ledger.mergeSharedHungerCues([HungerCue(recordedAt: base), HungerCue(recordedAt: .distantFuture)]))
        XCTAssertEqual(ledger, before)
        ledger.hungerCues.append(ledger.hungerCues[0]); XCTAssertThrowsError(try ledger.validate())
    }
    func testStoredObservationsStayOutOfHistoryCSVAndTotals() throws {
        var ledger = Ledger()
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90))
        try ledger.upsert(HungerCue(recordedAt: base.addingTimeInterval(60), notes: "=not a formula"))
        XCTAssertEqual(ledger.visibleHistory.count, 1)
        XCTAssertEqual(ledger.history(on: base).count, 1)
        XCTAssertFalse(ledger.csv().contains("Hunger signs")); XCTAssertFalse(ledger.csv().contains("not a formula"))
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(ledger.feedingDays(count: 1, endingAt: base.addingTimeInterval(100), calendar: utc)[0].feedCount, 1)
        XCTAssertEqual(ledger.volumeInLast24Hours(at: base.addingTimeInterval(100)).totalML, 90)
        XCTAssertEqual(ledger.hungerCues.count, 1)
    }
}
