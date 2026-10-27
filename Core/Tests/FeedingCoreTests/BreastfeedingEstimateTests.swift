import XCTest
@testable import FeedingCore

final class BreastfeedingEstimateTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)
    func breast(_ estimate: Int? = nil, at start: Date? = nil) -> Feed {
        let start = start ?? base
        return Feed(startedAt: start, endedAt: start.addingTimeInterval(600), kind: .breast,
                    leftSeconds: 240, rightSeconds: 300, estimatedMillilitres: estimate)
    }

    func testEstimateValidationAndMeasuredVolumeStaySeparate() throws {
        for estimate in [nil, 0, 60, 2000] as [Int?] { try breast(estimate).validate() }
        for estimate in [-1, 2001] { XCTAssertThrowsError(try breast(estimate).validate()) }
        var invalid = breast(60)
        invalid.millilitres = 60
        XCTAssertThrowsError(try invalid.validate())
        invalid = breast(60); invalid.leftSeconds = 0; invalid.rightSeconds = 0
        XCTAssertThrowsError(try invalid.validate())
        let bottle = Feed(startedAt: base, endedAt: base, kind: .formula,
                          millilitres: 60, estimatedMillilitres: 60)
        XCTAssertThrowsError(try bottle.validate())
    }

    func testEstimateCountsInIntakeAndFollowsCorrectionDeletionAndRestore() throws {
        var ledger = Ledger()
        var nursing = breast(50)
        try ledger.upsert(nursing)
        try ledger.upsert(breast()) // Unknown amount never inferred from minutes.
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .expressed, millilitres: 70))
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90))
        let first = VolumeSummary(feeds: ledger.feeds)
        XCTAssertEqual(first.estimatedBreastML, 50)
        XCTAssertEqual(first.bottleML, 160)
        XCTAssertEqual(first.totalML, 210)
        XCTAssertEqual(first.bottleCount, 2)
        nursing.estimatedMillilitres = 80
        try ledger.upsert(nursing)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 240)
        ledger.setDeleted(nursing.id, at: base.addingTimeInterval(1000))
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 160)
        ledger.setDeleted(nursing.id, at: nil)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 240)
        nursing.estimatedMillilitres = nil
        try ledger.upsert(nursing)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 160)
        XCTAssertEqual(nursing.duration, 540)
    }

    func testDailyAndRollingSummariesIncludeEstimatesWithoutPumpingOrActiveTimers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        let today = now.addingTimeInterval(-3600)
        var ledger = Ledger()
        ledger.feeds = [breast(40, at: today), breast(30, at: now.addingTimeInterval(-86400)),
                        breast(200, at: now.addingTimeInterval(-86401))]
        ledger.pumpSessions = [PumpSession(pumpedAt: today, millilitres: 500)]
        try ledger.start(side: .right, now: now.addingTimeInterval(-100))
        XCTAssertEqual(ledger.volumeInLast24Hours(at: now).totalML, 70)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds(on: today, calendar: calendar)).totalML, 40)
        let day = try XCTUnwrap(ledger.feedingDays(count: 1, endingAt: now, calendar: calendar).last)
        XCTAssertEqual(day.volume.totalML, 40)
        XCTAssertEqual(day.breastSeconds, 540)
        XCTAssertEqual(day.feedCount, 1)
    }

    func testLegacyBackupLoadsWithoutEstimatesAndNewBackupRetainsThem() throws {
        var ledger = Ledger(); ledger.feeds = [breast(65)]
        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(Ledger.self, from: data)
        XCTAssertEqual(restored, ledger)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var feeds = try XCTUnwrap(legacy["feeds"] as? [[String: Any]])
        feeds[0].removeValue(forKey: "estimatedMillilitres"); legacy["feeds"] = feeds
        let old = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: legacy))
        try old.validate()
        XCTAssertNil(old.feeds[0].estimatedMillilitres)
        XCTAssertEqual(old.feeds[0].leftSeconds, 240)
        XCTAssertEqual(old.feeds[0].rightSeconds, 300)
        XCTAssertEqual(VolumeSummary(feeds: old.feeds).totalML, 0)
        var imported = Ledger()
        XCTAssertEqual(try imported.merge(restored), 1)
        XCTAssertEqual(try imported.merge(restored), 0)
        XCTAssertEqual(imported.feeds[0].estimatedMillilitres, 65)
    }

    func testEncryptedSharingAndAtomicPersistenceRetainEstimateCorrections() throws {
        let key = Data(repeating: 8, count: 32)
        var ledger = Ledger(); let original = ledger
        ledger.feeds = [breast(75)]
        try ledger.stampFeedChanges(since: original, device: UUID().uuidString.lowercased())
        let packet = try HistoryPacket.seal(ledger.feeds[0], key: key)
        XCTAssertEqual(try packet.open(key: key), ledger.feeds[0])
        var other = Ledger()
        try other.mergeSharedFeeds([packet.open(key: key)])
        let before = ledger
        ledger.feeds[0].estimatedMillilitres = 95
        try ledger.stampFeedChanges(since: before, device: UUID().uuidString.lowercased())
        try other.mergeSharedFeeds([HistoryPacket.seal(ledger.feeds[0], key: key).open(key: key)])
        XCTAssertEqual(VolumeSummary(feeds: other.feeds).totalML, 95)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = LedgerRepository(url: url)
        try repository.save(other)
        XCTAssertEqual(try repository.load(), other)
    }

    func testCSVLabelsEstimatesAndBottleShortcutsIgnoreThem() throws {
        var ledger = Ledger(); ledger.feeds = [breast(900)]
        try ledger.upsert(Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 60))
        XCTAssertTrue(ledger.csv().hasPrefix("start_utc,end_utc,type,left_seconds,right_seconds,millilitres,notes,estimated_millilitres"))
        XCTAssertTrue(ledger.csv().contains("\"Breast\",\"240\",\"300\",\"\",\"\",\"900\""))
        XCTAssertEqual(ledger.bottleVolumePresets(at: base.addingTimeInterval(3600)), [40, 50, 60, 70, 80])
    }
}
