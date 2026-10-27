import XCTest
@testable import FeedingCore

final class FeedingCoreTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testSwitchPauseResumeAndFinishExcludePausedTime() throws {
        var ledger = Ledger()
        try ledger.start(side: .left, now: base)
        ledger.active?.switchSide(to: .right, at: base.addingTimeInterval(120))
        ledger.active?.pause(at: base.addingTimeInterval(180))
        XCTAssertEqual(ledger.active?.seconds(for: .right, at: base.addingTimeInterval(500)), 60)
        ledger.active?.switchSide(to: .left, at: base.addingTimeInterval(500))
        XCTAssertNil(ledger.active?.runningSince)
        ledger.active?.resume(at: base.addingTimeInterval(600))
        try ledger.finish(now: base.addingTimeInterval(660))
        XCTAssertNil(ledger.active)
        XCTAssertEqual(ledger.feeds.count, 1)
        XCTAssertEqual(ledger.feeds[0].leftSeconds, 180)
        XCTAssertEqual(ledger.feeds[0].rightSeconds, 60)
        XCTAssertEqual(ledger.feeds[0].endedAt.timeIntervalSince(ledger.feeds[0].startedAt), 660)
    }

    func testActiveTimerSurvivesSerializationAndTimeAway() throws {
        var ledger = Ledger()
        try ledger.start(side: .right, now: base)
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.active?.seconds(for: .right, at: base.addingTimeInterval(3600)), 3600)
        XCTAssertEqual(restored.active?.id, ledger.active?.id)
        ledger.active?.pause(at: base.addingTimeInterval(10))
        let paused = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(paused.active?.seconds(for: .right, at: base.addingTimeInterval(3600)), 10)
    }

    func testCannotStartTwoTimersOrFinishInvalidFeed() throws {
        var ledger = Ledger()
        try ledger.start(side: .left, now: base)
        XCTAssertThrowsError(try ledger.start(side: .right, now: base))
        XCTAssertThrowsError(try ledger.finish(now: base))
        XCTAssertNotNil(ledger.active)
        XCTAssertTrue(ledger.feeds.isEmpty)
    }

    func testAtomicPersistenceAndSoftDeleteRestore() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = LedgerRepository(url: directory.appendingPathComponent("feeds.json"))
        XCTAssertTrue(try repo.load().feeds.isEmpty)
        var ledger = Ledger()
        let feed = bottle()
        try ledger.upsert(feed)
        try repo.save(ledger)
        XCTAssertEqual(try repo.load(), ledger)
        ledger.setDeleted(feed.id, at: Date())
        XCTAssertTrue(ledger.visibleFeeds.isEmpty)
        XCTAssertEqual(ledger.feeds.count, 1)
        try repo.save(ledger)
        ledger = try repo.load()
        ledger.setDeleted(feed.id, at: nil)
        XCTAssertEqual(ledger.visibleFeeds.count, 1)
        var invalid = ledger
        invalid.feeds[0].millilitres = -5
        XCTAssertThrowsError(try repo.save(invalid))
        XCTAssertEqual(try repo.load().feeds[0].deletedAt != nil, true)
    }

    func testCorruptFileIsNotSilentlyReplaced() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let bad = Data("broken-json".utf8)
        try bad.write(to: url)
        XCTAssertThrowsError(try LedgerRepository(url: url).load())
        XCTAssertEqual(try Data(contentsOf: url), bad)
    }

    func testValidationRejectsImpossibleAndFutureEntries() throws {
        var feed = bottle()
        feed.startedAt = Date().addingTimeInterval(3600)
        XCTAssertThrowsError(try feed.validate())
        feed = bottle(); feed.millilitres = 0
        XCTAssertThrowsError(try feed.validate())
        feed = Feed(startedAt: base, endedAt: base.addingTimeInterval(60), kind: .breast, leftSeconds: 90)
        XCTAssertThrowsError(try feed.validate())
        feed.leftSeconds = .infinity
        XCTAssertThrowsError(try feed.validate())
        feed.leftSeconds = .nan
        XCTAssertThrowsError(try feed.validate())
    }

    func testBackupMergeIsIdempotentAndDoesNotReplaceEditedRecordsOrTimer() throws {
        var local = Ledger()
        var backup = Ledger()
        var entry = bottle()
        try backup.upsert(entry)
        entry.notes = "Corrected"
        try local.upsert(entry)
        try local.start(side: .left, now: base)
        let activeID = local.active?.id
        try backup.upsert(bottle())
        XCTAssertEqual(try local.merge(backup), 1)
        XCTAssertEqual(try local.merge(backup), 0)
        XCTAssertEqual(local.feeds.first { $0.id == entry.id }?.notes, "Corrected")
        XCTAssertEqual(local.active?.id, activeID)
    }

    func testLocalDayTotalsHandleMidnightAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let iso = ISO8601DateFormatter()
        let beforeMidnight = iso.date(from: "2026-10-24T21:55:00Z")!
        let nextDay = iso.date(from: "2026-10-24T22:05:00Z")!
        let testNow = iso.date(from: "2026-10-26T12:00:00Z")!
        var ledger = Ledger()
        try ledger.upsert(Feed(startedAt: beforeMidnight, endedAt: nextDay, kind: .breast, leftSeconds: 600), now: testNow)
        try ledger.upsert(Feed(startedAt: nextDay, endedAt: nextDay, kind: .formula, millilitres: 60), now: testNow)
        // Two occurrences of 02:30 during the Berlin autumn clock change.
        let first = iso.date(from: "2026-10-25T00:30:00Z")!
        let second = iso.date(from: "2026-10-25T01:30:00Z")!
        try ledger.upsert(Feed(startedAt: first, endedAt: first, kind: .formula, millilitres: 60), now: testNow)
        try ledger.upsert(Feed(startedAt: second, endedAt: second, kind: .formula, millilitres: 60), now: testNow)
        XCTAssertEqual(ledger.feeds(on: beforeMidnight, calendar: calendar).count, 1)
        XCTAssertEqual(ledger.feeds(on: nextDay, calendar: calendar).count, 3)
    }

    func testCSVQuotesNotesAndNeutralizesSpreadsheetFormulas() throws {
        var ledger = Ledger()
        var feed = bottle()
        feed.notes = "=HYPERLINK(\"bad\")\nline, two"
        try ledger.upsert(feed)
        let csv = ledger.csv()
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"bad\"\")\nline, two\""))
        ledger.setDeleted(feed.id, at: Date())
        XCTAssertEqual(ledger.csv().components(separatedBy: "\r\n").count, 1)
    }

    func testUnknownBackupVersionAndDuplicateIDsAreRejected() throws {
        var ledger = Ledger()
        ledger.version = 2
        XCTAssertThrowsError(try ledger.validate())
        ledger.version = 1
        let feed = bottle()
        ledger.feeds = [feed, feed]
        XCTAssertThrowsError(try ledger.validate())
    }

    func testVolumeTotalsFollowEditsDeletionAndRestoration() throws {
        var ledger = Ledger()
        var expressed = bottle()
        let formula = Feed(startedAt: base, endedAt: base, kind: .formula, millilitres: 90)
        let breast = Feed(startedAt: base, endedAt: base.addingTimeInterval(600), kind: .breast, leftSeconds: 600)
        try ledger.upsert(expressed)
        try ledger.upsert(formula)
        try ledger.upsert(breast)
        var summary = VolumeSummary(feeds: ledger.feeds)
        XCTAssertEqual(summary.expressedML, 60)
        XCTAssertEqual(summary.formulaML, 90)
        XCTAssertEqual(summary.totalML, 150)
        XCTAssertEqual(summary.bottleCount, 2)
        expressed.millilitres = 75
        try ledger.upsert(expressed)
        ledger.setDeleted(formula.id, at: Date())
        summary = VolumeSummary(feeds: ledger.feeds)
        XCTAssertEqual(summary.totalML, 75)
        XCTAssertEqual(summary.bottleCount, 1)
        ledger.setDeleted(formula.id, at: nil)
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(VolumeSummary(feeds: restored.feeds).totalML, 165)
    }

    func testRollingVolumeUsesExact24HourWindowAcrossCalendarMidnight() throws {
        var ledger = Ledger()
        let now = base.addingTimeInterval(100_000)
        for (offset, amount) in [(-86_401.0, 20), (-86_400.0, 30), (-1.0, 40), (0.0, 50), (1.0, 60)] {
            let date = now.addingTimeInterval(offset)
            try ledger.upsert(Feed(startedAt: date, endedAt: date, kind: .formula, millilitres: amount), now: now.addingTimeInterval(10))
        }
        let summary = ledger.volumeInLast24Hours(at: now)
        XCTAssertEqual(summary.totalML, 120)
        XCTAssertEqual(summary.bottleCount, 3)
    }

    func testLockScreenUsesFeedStartAndReflectsEditsAndDeletion() throws {
        var ledger = Ledger()
        XCTAssertNil(ledger.latestFeedGlance)
        let older = bottle()
        var newer = Feed(startedAt: base.addingTimeInterval(3600), endedAt: base.addingTimeInterval(4200),
                         kind: .formula, millilitres: 90)
        try ledger.upsert(older)
        try ledger.upsert(newer)
        XCTAssertEqual(ledger.latestFeedGlance?.startedAt, newer.startedAt)
        XCTAssertEqual(ledger.latestFeedGlance?.millilitres, 90)
        XCTAssertEqual(ledger.latestFeedGlance?.isFeeding, false)
        newer.millilitres = 75
        try ledger.upsert(newer)
        XCTAssertEqual(ledger.latestFeedGlance?.millilitres, 75)
        ledger.setDeleted(newer.id, at: Date())
        XCTAssertEqual(ledger.latestFeedGlance?.id, older.id)
        ledger.setDeleted(older.id, at: Date())
        XCTAssertNil(ledger.latestFeedGlance)
    }

    func testLockScreenTracksActivePauseAndFinishWithoutChangingClockOrigin() throws {
        var ledger = Ledger()
        try ledger.upsert(bottle())
        let start = base.addingTimeInterval(3600)
        try ledger.start(side: .left, now: start)
        let id = ledger.active?.id
        XCTAssertEqual(ledger.latestFeedGlance?.id, id)
        XCTAssertEqual(ledger.latestFeedGlance?.isFeeding, true)
        ledger.active?.switchSide(to: .right, at: start.addingTimeInterval(60))
        ledger.active?.pause(at: start.addingTimeInterval(120))
        XCTAssertEqual(ledger.latestFeedGlance?.side, .right)
        XCTAssertEqual(ledger.latestFeedGlance?.isPaused, true)
        XCTAssertEqual(ledger.latestFeedGlance?.startedAt, start)
        try ledger.finish(now: start.addingTimeInterval(180))
        XCTAssertEqual(ledger.latestFeedGlance?.id, id)
        XCTAssertEqual(ledger.latestFeedGlance?.startedAt, start)
        XCTAssertEqual(ledger.latestFeedGlance?.isFeeding, false)
        XCTAssertEqual(ledger.latestFeedGlance?.isPaused, false)
    }

    func testLaterBottleWinsOverEarlierActiveBreastfeedAndBackupRetainsGlance() throws {
        var ledger = Ledger()
        try ledger.start(side: .left, now: base)
        let later = Feed(startedAt: base.addingTimeInterval(60), endedAt: base.addingTimeInterval(120),
                         kind: .expressed, millilitres: 60)
        try ledger.upsert(later)
        XCTAssertEqual(ledger.latestFeedGlance?.id, later.id)
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.latestFeedGlance, ledger.latestFeedGlance)
    }

    private func bottle() -> Feed {
        Feed(startedAt: base, endedAt: base.addingTimeInterval(600), kind: .expressed, millilitres: 60)
    }
}
