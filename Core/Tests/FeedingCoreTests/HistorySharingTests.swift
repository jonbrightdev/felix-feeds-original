import XCTest
@testable import FeedingCore

final class HistorySharingTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testOfflineAddsFromTwoParentsConvergeWithoutDuplicates() throws {
        var caregiverB = Ledger(), caregiverA = Ledger()
        try caregiverB.upsert(bottle(60))
        try caregiverB.stampFeedChanges(since: Ledger(), device: "CaregiverB")
        try caregiverA.upsert(bottle(90))
        try caregiverA.stampFeedChanges(since: Ledger(), device: "CaregiverA")
        let originalCaregiverB = caregiverB
        try caregiverB.mergeSharedFeeds(caregiverA.feeds)
        try caregiverA.mergeSharedFeeds(originalCaregiverB.feeds)
        XCTAssertEqual(caregiverB.feeds, caregiverA.feeds)
        XCTAssertEqual(caregiverB.feeds.count, 2)
        XCTAssertEqual(VolumeSummary(feeds: caregiverB.feeds).totalML, 150)
        let merged = caregiverB
        try caregiverB.mergeSharedFeeds(caregiverA.feeds)
        XCTAssertEqual(caregiverB, merged)
    }

    func testConcurrentSameFeedEditsHaveSameWinnerInEitherOrder() throws {
        var original = Ledger()
        try original.upsert(bottle(60))
        try original.stampFeedChanges(since: Ledger(), device: "Seed")
        var caregiverB = original, caregiverA = original
        caregiverB.feeds[0].millilitres = 75
        caregiverA.feeds[0].millilitres = 90
        try caregiverB.stampFeedChanges(since: original, device: "CaregiverB")
        try caregiverA.stampFeedChanges(since: original, device: "CaregiverA")
        let left = caregiverB.feeds, right = caregiverA.feeds
        try caregiverB.mergeSharedFeeds(right)
        try caregiverA.mergeSharedFeeds(left)
        XCTAssertEqual(caregiverB.feeds, caregiverA.feeds)
        XCTAssertEqual(caregiverB.feeds[0].millilitres, 75)
    }

    func testDeletedFeedDoesNotReturnFromAnOfflineOlderCopyAndCanBeRestored() throws {
        var ledger = Ledger()
        let feed = bottle(60)
        try ledger.upsert(feed)
        try ledger.stampFeedChanges(since: Ledger(), device: "CaregiverB")
        let offline = ledger
        ledger.setDeleted(feed.id, at: Date())
        try ledger.stampFeedChanges(since: offline, device: "CaregiverA")
        try ledger.mergeSharedFeeds(offline.feeds)
        XCTAssertTrue(ledger.visibleFeeds.isEmpty)
        let deleted = ledger
        ledger.setDeleted(feed.id, at: nil)
        try ledger.stampFeedChanges(since: deleted, device: "CaregiverB")
        try ledger.mergeSharedFeeds(deleted.feeds)
        XCTAssertEqual(ledger.visibleFeeds.count, 1)
        XCTAssertGreaterThan(ledger.feeds[0].revision!, deleted.feeds[0].revision!)
    }

    func testNotesAndVolumeShareOneAtomicRevisionAndWallClocksAreNotCompared() throws {
        var original = Ledger()
        var feed = bottle(60); feed.notes = "Original"
        try original.upsert(feed)
        try original.stampFeedChanges(since: Ledger(), device: "CaregiverB")
        var updated = original
        updated.feeds[0].millilitres = 75; updated.feeds[0].notes = "Correction"
        // Editing the recorded start time backwards must not make the correction stale.
        updated.feeds[0].startedAt = base.addingTimeInterval(-3600)
        try updated.stampFeedChanges(since: original, device: "CaregiverA")
        try original.mergeSharedFeeds(updated.feeds)
        XCTAssertEqual(original.feeds[0].millilitres, 75)
        XCTAssertEqual(original.feeds[0].notes, "Correction")
        XCTAssertEqual(original.feeds[0].startedAt, base.addingTimeInterval(-3600))
    }

    func testLegacyBackupLoadsWithoutSyncFieldsAndNewBackupRetainsRevisions() throws {
        var ledger = Ledger(); try ledger.upsert(bottle(60))
        let data = try JSONEncoder().encode(ledger)
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var feeds = object["feeds"] as! [[String: Any]]
        feeds[0].removeValue(forKey: "revision"); object["feeds"] = feeds
        object.removeValue(forKey: "sharedHistoryID")
        var legacy = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.feeds[0].revision)
        try legacy.stampFeedChanges(since: Ledger(), device: "CaregiverB")
        legacy.sharedHistoryID = "family-one"
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(restored, legacy)
    }

    func testInvalidRemoteBatchDoesNotPartiallyCommitAndActiveTimerStaysLocal() throws {
        var ledger = Ledger(); try ledger.upsert(bottle(60))
        try ledger.start(side: .left, now: base)
        let previous = ledger
        var invalid = bottle(90); invalid.millilitres = -5
        XCTAssertThrowsError(try ledger.mergeSharedFeeds([bottle(75), invalid]))
        XCTAssertEqual(ledger, previous)
        try ledger.mergeSharedFeeds([bottle(75)])
        XCTAssertEqual(ledger.active, previous.active)
    }

    func testOnlyActualFeedChangesAdvanceRevision() throws {
        var ledger = Ledger(); try ledger.upsert(bottle(60))
        try ledger.stampFeedChanges(since: Ledger(), device: "CaregiverB")
        let before = ledger
        try ledger.start(side: .left, now: base)
        try ledger.stampFeedChanges(since: before, device: "CaregiverB")
        XCTAssertEqual(ledger.feeds[0].revision, before.feeds[0].revision)
    }

    private func bottle(_ amount: Int) -> Feed {
        Feed(startedAt: base, endedAt: base.addingTimeInterval(600), kind: .expressed, millilitres: amount)
    }
}
