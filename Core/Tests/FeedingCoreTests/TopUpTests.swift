import XCTest
@testable import FeedingCore

final class TopUpTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func bottle(at offset: TimeInterval = 0, topUp: Bool = false) -> Feed {
        Feed(startedAt: base.addingTimeInterval(offset), endedAt: base.addingTimeInterval(offset),
             kind: .formula, millilitres: topUp ? 30 : 90, isTopUp: topUp)
    }

    func testTopUpKeepsTimerButCountsInHistoryIntakeAndTrends() {
        var ledger = Ledger()
        let regular = bottle(), topUp = bottle(at: 3600, topUp: true)
        ledger.feeds = [regular, topUp]
        XCTAssertEqual(ledger.visibleFeeds.first?.id, topUp.id)
        XCTAssertEqual(ledger.latestTimerFeed?.id, regular.id)
        XCTAssertEqual(ledger.latestFeedGlance?.id, regular.id)
        XCTAssertEqual(LiveActivitySnapshot(ledger: ledger).feed?.id, regular.id)
        XCTAssertEqual(VolumeSummary(feeds: ledger.visibleFeeds).totalML, 120)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(ledger.milkProgress(on: base, calendar: calendar).last?.totalML, 120)
        XCTAssertTrue(ledger.csv().components(separatedBy: "\r\n")[0].hasSuffix(",is_top_up"))
        XCTAssertTrue(ledger.csv().contains("\"true\""))
    }

    func testOnlyTopUpsDoNotCreateTimerAndNextRegularFeedRestartsIt() {
        var ledger = Ledger(); ledger.feeds = [bottle(topUp: true)]
        XCTAssertNil(ledger.latestTimerFeed)
        XCTAssertNil(ledger.latestFeedGlance)
        XCTAssertNil(LiveActivitySnapshot(ledger: ledger).feed)
        let next = bottle(at: 7200)
        ledger.feeds.append(next)
        XCTAssertEqual(ledger.latestFeedGlance?.id, next.id)
    }

    func testEditingAndDeletingRecomputesTimer() {
        var ledger = Ledger()
        let first = bottle(), later = bottle(at: 3600)
        ledger.feeds = [first, later]
        XCTAssertEqual(ledger.latestTimerFeed?.id, later.id)
        ledger.feeds[1].isTopUp = true
        XCTAssertEqual(ledger.latestTimerFeed?.id, first.id)
        ledger.setDeleted(first.id, at: base.addingTimeInterval(7200))
        XCTAssertNil(ledger.latestTimerFeed)
        ledger.feeds[1].isTopUp = nil
        XCTAssertEqual(LiveActivitySnapshot(ledger: ledger).feed?.id, later.id)
    }

    func testBreastfeedingTopUpPreservesIntervalWhileRunningAndAfterFinishing() throws {
        var ledger = Ledger(); let regular = bottle(); ledger.feeds = [regular]
        try ledger.start(side: .left, now: base.addingTimeInterval(3600), isTopUp: true)
        XCTAssertEqual(ledger.latestFeedGlance?.id, regular.id)
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored.active?.isTopUp, true)
        try ledger.finish(now: base.addingTimeInterval(3900))
        XCTAssertEqual(ledger.visibleFeeds.first?.isTopUp, true)
        XCTAssertNil(ledger.visibleFeeds.first?.estimatedMillilitres)
        XCTAssertEqual(ledger.latestFeedGlance?.id, regular.id)
        XCTAssertEqual(LiveActivitySnapshot(ledger: ledger).feed?.id, regular.id)
    }

    func testLegacyRecordsAndTimersDecodeAsRegularFeeds() throws {
        var ledger = Ledger(); ledger.feeds = [bottle()]
        try ledger.start(side: .left, now: base.addingTimeInterval(600))
        let data = try JSONEncoder().encode(ledger)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("isTopUp"))
        let restored = try JSONDecoder().decode(Ledger.self, from: data)
        XCTAssertNil(restored.feeds[0].isTopUp)
        XCTAssertNil(restored.active?.isTopUp)
        XCTAssertEqual(restored.latestFeedGlance?.id, restored.active?.id)
    }

    func testTopUpSurvivesBackupEncryptedSharingAndRevisionEdits() throws {
        var ledger = Ledger(); ledger.feeds = [bottle(topUp: true)]
        try ledger.stampFeedChanges(since: Ledger(), device: UUID().uuidString)
        let restored = try JSONDecoder().decode(Ledger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(restored, ledger)
        let key = Data(repeating: 1, count: 32)
        let packet = try HistoryPacket.seal(ledger.feeds[0], key: key)
        XCTAssertEqual(try packet.open(key: key).isTopUp, true)
        let previous = ledger
        ledger.feeds[0].isTopUp = nil
        try ledger.stampFeedChanges(since: previous, device: UUID().uuidString)
        var remote = previous
        try remote.mergeSharedFeeds(ledger.feeds)
        XCTAssertEqual(remote.latestTimerFeed?.id, ledger.feeds[0].id)
    }
}
