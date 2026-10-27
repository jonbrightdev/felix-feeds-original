import XCTest
@testable import FeedingCore

final class BottleVolumePresetsTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_411_200)

    func bottle(_ ml: Int?, daysAgo: Double = 1, kind: FeedKind = .expressed) -> Feed {
        let start = now.addingTimeInterval(-daysAgo * 86_400)
        return Feed(startedAt: start, endedAt: start, kind: kind, millilitres: ml)
    }

    func testEmptyAndStaleHistoriesUseTightDefaults() {
        var ledger = Ledger()
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [70, 80, 90, 100, 110])
        ledger.feeds = [bottle(180, daysAgo: 7.001)]
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [70, 80, 90, 100, 110])
    }

    func testAverageCombinesBottleKindsAndRoundsUpToNextTen() {
        var ledger = Ledger()
        ledger.feeds = [bottle(80), bottle(110, kind: .formula)]
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [80, 90, 100, 110, 120])
        ledger.feeds = [bottle(94)]
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [80, 90, 100, 110, 120])
        ledger.feeds = [bottle(90), bottle(91, kind: .formula)] // 90.5 rounds up
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [80, 90, 100, 110, 120])
        ledger.feeds = [bottle(90)] // exact multiples stay unchanged
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [70, 80, 90, 100, 110])
        ledger.feeds = [bottle(160), bottle(180), bottle(200, kind: .formula)]
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [160, 170, 180, 190, 200])
    }

    func testWindowIncludesExactBoundaryAndExcludesIneligibleRecords() {
        var ledger = Ledger()
        var deleted = bottle(1500); deleted.deletedAt = now
        var unfinished = bottle(1500, daysAgo: 0)
        unfinished.endedAt = now.addingTimeInterval(1)
        var reversed = bottle(1500)
        reversed.endedAt = reversed.startedAt.addingTimeInterval(-1)
        ledger.feeds = [bottle(60, daysAgo: 7), bottle(100, daysAgo: 0),
                        bottle(1500, daysAgo: 7.00001), bottle(1500, daysAgo: -1),
                        bottle(1500, kind: .breast), deleted, unfinished, reversed,
                        bottle(nil), bottle(0), bottle(-10), bottle(2001), bottle(Int.max)]
        ledger.active = ActiveFeed(side: .left, now: now)
        ledger.hungerCues = [HungerCue(recordedAt: now)]
        let before = ledger
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [60, 70, 80, 90, 100])
        XCTAssertEqual(ledger, before)
    }

    func testEditsDeletionRestorationAndAgingRecalculatePresets() throws {
        var ledger = Ledger()
        let original = bottle(60)
        try ledger.upsert(original, now: now)
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [40, 50, 60, 70, 80])
        var edited = original; edited.millilitres = 160
        try ledger.upsert(edited, now: now)
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [140, 150, 160, 170, 180])
        ledger.setDeleted(edited.id, at: now)
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [70, 80, 90, 100, 110])
        ledger.setDeleted(edited.id, at: nil)
        XCTAssertEqual(ledger.bottleVolumePresets(at: now), [140, 150, 160, 170, 180])
        XCTAssertEqual(ledger.bottleVolumePresets(at: now.addingTimeInterval(7 * 86_400)),
                       [70, 80, 90, 100, 110])
    }

    func testEveryAllowedVolumeProducesFiveDistinctValidChoicesIncludingRoundedAverage() {
        for amount in 1...2000 {
            var ledger = Ledger(); ledger.feeds = [bottle(amount)]
            let choices = ledger.bottleVolumePresets(at: now)
            XCTAssertEqual(choices.count, 5)
            XCTAssertEqual(Set(choices).count, 5)
            XCTAssertEqual(choices, choices.sorted())
            XCTAssertTrue(zip(choices, choices.dropFirst()).allSatisfy { $1 - $0 == 10 })
            XCTAssertTrue(choices.allSatisfy { (1...2000).contains($0) && $0.isMultiple(of: 10) })
            XCTAssertTrue(choices.contains(Int((Double(amount) / 10).rounded(.up)) * 10))
        }
    }
}
