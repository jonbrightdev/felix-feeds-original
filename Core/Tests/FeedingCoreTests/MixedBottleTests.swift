import XCTest
@testable import FeedingCore

final class MixedBottleTests: XCTestCase {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    func mixed(total: Int = 100, formula: Int = 40, at date: Date? = nil) -> Feed {
        let date = date ?? base
        return Feed(startedAt: date, endedAt: date, kind: .expressed,
                    millilitres: total, formulaMillilitres: formula)
    }

    func testValidationRequiresTwoPositiveAmountsAndLimitsCombinedVolume() throws {
        try mixed().validate()
        try mixed(total: 2, formula: 1).validate()
        try mixed(total: 2000, formula: 1999).validate()
        for feed in [mixed(total: 0), mixed(total: 2001), mixed(formula: -1),
                     mixed(formula: 0), mixed(formula: 100), mixed(formula: 101),
                     mixed(formula: Int.max), mixed(formula: Int.min)] {
            XCTAssertThrowsError(try feed.validate())
        }
        var invalid = mixed(); invalid.millilitres = nil
        XCTAssertThrowsError(try invalid.validate())
        invalid = mixed(); invalid.kind = .formula
        XCTAssertThrowsError(try invalid.validate())
        invalid = mixed(); invalid.estimatedMillilitres = 30
        XCTAssertThrowsError(try invalid.validate())
        invalid = Feed(startedAt: base, endedAt: base.addingTimeInterval(60), kind: .breast,
                       leftSeconds: 60, formulaMillilitres: 10)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testOneFeedAndSplitTotalsFollowEditsDeletionRestorationAndTypeChanges() throws {
        var ledger = Ledger(); var bottle = mixed()
        try ledger.upsert(bottle)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).expressedML, 60)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).formulaML, 40)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 100)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).bottleCount, 1)
        XCTAssertEqual(ledger.visibleHistory.count, 1)
        XCTAssertTrue(ledger.latestFeedGlance?.isMixedBottle == true)
        XCTAssertEqual(ledger.latestFeedGlance?.millilitres, 100)
        bottle.millilitres = 120; bottle.formulaMillilitres = 30
        try ledger.upsert(bottle)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).expressedML, 90)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).formulaML, 30)
        ledger.setDeleted(bottle.id, at: base)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 0)
        ledger.setDeleted(bottle.id, at: nil)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).totalML, 120)
        bottle.kind = .formula; bottle.formulaMillilitres = nil
        try ledger.upsert(bottle)
        XCTAssertFalse(ledger.feeds[0].isMixedBottle)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).expressedML, 0)
        XCTAssertEqual(VolumeSummary(feeds: ledger.feeds).formulaML, 120)
    }

    func testDailyRollingTrendsAndShortcutsUseOneCombinedBottle() throws {
        let now = ISO8601DateFormatter().date(from: "2026-10-25T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var ledger = Ledger()
        ledger.feeds = [mixed(at: now.addingTimeInterval(-3600)),
                        mixed(total: 80, formula: 20, at: now.addingTimeInterval(-86400)),
                        mixed(total: 200, formula: 50, at: now.addingTimeInterval(-86401))]
        let rolling = ledger.volumeInLast24Hours(at: now)
        XCTAssertEqual(rolling.expressedML, 120)
        XCTAssertEqual(rolling.formulaML, 60)
        XCTAssertEqual(rolling.bottleCount, 2)
        let today = try XCTUnwrap(ledger.feedingDays(count: 1, endingAt: now, calendar: calendar).last)
        XCTAssertEqual(today.volume.expressedML, 60)
        XCTAssertEqual(today.volume.formulaML, 40)
        XCTAssertEqual(today.feedCount, 1)
        XCTAssertEqual(today.breastSeconds, 0)
        ledger.feeds = [mixed(at: now)]
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [80, 90, 100, 110, 120])
    }

    func testLegacyRecordsRemainReadableAndBackupsRetainTheSplit() throws {
        var ledger = Ledger(); ledger.feeds = [mixed()]
        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(Ledger.self, from: data)
        XCTAssertEqual(restored, ledger)
        var imported = Ledger()
        XCTAssertEqual(try imported.merge(restored), 1)
        XCTAssertEqual(try imported.merge(restored), 0)
        XCTAssertEqual(imported.feeds[0].formulaML, 40)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var feeds = try XCTUnwrap(legacy["feeds"] as? [[String: Any]])
        XCTAssertEqual(feeds[0]["kind"] as? String, "expressed")
        feeds[0].removeValue(forKey: "formulaMillilitres"); legacy["feeds"] = feeds
        let old = try JSONDecoder().decode(Ledger.self, from: JSONSerialization.data(withJSONObject: legacy))
        try old.validate()
        XCTAssertFalse(old.feeds[0].isMixedBottle)
        XCTAssertEqual(old.feeds[0].expressedML, 100)
        XCTAssertEqual(old.feeds[0].formulaML, 0)
    }

    func testEncryptedSharingAndPersistenceRetainSplitCorrectionsAndDeletion() throws {
        let key = Data(repeating: 12, count: 32)
        let device = UUID().uuidString.lowercased()
        var source = Ledger(); source.feeds = [mixed()]
        try source.stampFeedChanges(since: Ledger(), device: device)
        var other = Ledger()
        try other.mergeSharedFeeds([HistoryPacket.seal(source.feeds[0], key: key).open(key: key)])
        XCTAssertEqual(other.feeds, source.feeds)
        let previous = source
        source.feeds[0].formulaMillilitres = 55
        try source.stampFeedChanges(since: previous, device: device)
        try other.mergeSharedFeeds([HistoryPacket.seal(source.feeds[0], key: key).open(key: key)])
        XCTAssertEqual(other.feeds[0].expressedML, 45)
        XCTAssertEqual(other.feeds[0].formulaML, 55)
        let beforeDelete = source
        source.setDeleted(source.feeds[0].id, at: base)
        try source.stampFeedChanges(since: beforeDelete, device: device)
        try other.mergeSharedFeeds([HistoryPacket.seal(source.feeds[0], key: key).open(key: key)])
        XCTAssertTrue(other.visibleFeeds.isEmpty)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let repository = LedgerRepository(url: url)
        try repository.save(other)
        XCTAssertEqual(try repository.load(), other)
    }

    func testCSVExportsOneRowWithTotalAndBothComponentsAndLocalizedLabels() throws {
        var ledger = Ledger(); ledger.feeds = [mixed()]
        let rows = ledger.csv().components(separatedBy: "\r\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows[0].hasSuffix(",expressed_millilitres,formula_millilitres"))
        XCTAssertTrue(rows[1].contains("\"Mixed bottle\",\"0\",\"0\",\"100\""))
        XCTAssertTrue(rows[1].hasSuffix("\"60\",\"40\""))
        let de = Locale(identifier: "de_DE")
        XCTAssertEqual(L10n.text("Mixed bottle", locale: de), "Gemischtes Fläschchen")
        XCTAssertEqual(L10n.format("%d ml expressed + %d ml formula", 60, 40, locale: de),
                       "60 ml abgepumpte Milch + 40 ml Säuglingsnahrung")
    }
}
