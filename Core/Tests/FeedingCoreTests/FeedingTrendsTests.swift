import XCTest
@testable import FeedingCore

final class FeedingTrendsTests: XCTestCase {
    var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }
    func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    func bottle(_ at: Date, ml: Int = 80, kind: FeedKind = .expressed) -> Feed {
        Feed(startedAt: at, endedAt: at.addingTimeInterval(60), kind: kind, millilitres: ml)
    }

    func testTotalsStaySeparateAndExcludeDeletedFutureAndActiveRecords() throws {
        let now = date("2026-10-16T12:00:00Z")
        var ledger = Ledger()
        let start = now.addingTimeInterval(-3600)
        ledger.feeds = [bottle(start), bottle(start, ml: 60, kind: .formula),
                        Feed(startedAt: start, endedAt: start.addingTimeInterval(1200), kind: .breast,
                             leftSeconds: 120, rightSeconds: 180),
                        bottle(now.addingTimeInterval(3600)),
                        bottle(now.addingTimeInterval(-30))] // unfinished future end
        var deleted = bottle(start, ml: 999); deleted.deletedAt = now
        ledger.feeds.append(deleted)
        ledger.hungerCues = [HungerCue(recordedAt: start), HungerCue(recordedAt: now.addingTimeInterval(1)),
                             HungerCue(recordedAt: start, deletedAt: now)]
        try ledger.start(side: .left, now: now.addingTimeInterval(-600))
        let before = ledger
        let days = ledger.feedingDays(count: 7, endingAt: now, calendar: berlin)
        let today = try XCTUnwrap(days.last)
        XCTAssertEqual(today.feedCount, 3)
        XCTAssertEqual(today.volume.expressedML, 80)
        XCTAssertEqual(today.volume.formulaML, 60)
        XCTAssertEqual(today.volume.totalML, 140)
        XCTAssertEqual(today.volume.bottleCount, 2)
        XCTAssertEqual(today.leftSeconds, 120)
        XCTAssertEqual(today.rightSeconds, 180)
        XCTAssertEqual(today.breastSeconds, 300) // wall-clock duration and active time excluded
        XCTAssertEqual(ledger, before)
        XCTAssertEqual(days.count, 7)
        XCTAssertTrue(days.dropLast().allSatisfy { !$0.hasRecords })
        XCTAssertTrue(ledger.feedingDays(count: 0, endingAt: now).isEmpty)
    }

    func testDayBoundaryUsesStartDateAndIncludesExactWindowStart() throws {
        let now = date("2026-10-16T10:00:00Z")
        let midnight = date("2026-10-15T22:00:00Z") // Berlin 16 Oct 00:00
        var ledger = Ledger()
        ledger.feeds = [bottle(midnight, ml: 50), bottle(midnight.addingTimeInterval(-30), ml: 70),
                        bottle(date("2026-10-09T22:00:00Z"), ml: 90),
                        bottle(date("2026-10-09T21:59:59Z"), ml: 100)]
        let days = ledger.feedingDays(count: 7, endingAt: now, calendar: berlin)
        XCTAssertEqual(days.first?.volume.totalML, 90)
        XCTAssertEqual(days[5].volume.totalML, 70) // crosses midnight, attributed to start
        XCTAssertEqual(days.last?.volume.totalML, 50)
        XCTAssertEqual(days.reduce(0) { $0 + $1.feedCount }, 3)
        ledger.setDeleted(ledger.feeds[0].id, at: now)
        XCTAssertEqual(ledger.feedingDays(count: 7, endingAt: now, calendar: berlin).last?.feedCount, 0)
        ledger.setDeleted(ledger.feeds[0].id, at: nil)
        ledger.feeds[0].millilitres = 65
        XCTAssertEqual(ledger.feedingDays(count: 7, endingAt: now, calendar: berlin).last?.volume.totalML, 65)
    }

    func testSpringAndAutumnClockChangesKeepOneBucketPerLocalDay() {
        for (end, expectedHours) in [("2026-03-30T12:00:00Z", 23.0), ("2026-10-26T12:00:00Z", 25.0)] {
            let now = date(end)
            let days = Ledger().feedingDays(count: 3, endingAt: now, calendar: berlin)
            XCTAssertEqual(days.count, 3)
            XCTAssertEqual(Set(days.map(\.date)).count, 3)
            XCTAssertEqual(days[2].date.timeIntervalSince(days[1].date) / 3600, expectedHours)
            XCTAssertTrue(days.allSatisfy { berlin.component(.hour, from: $0.date) == 0 })
        }
        var ledger = Ledger()
        // Both occurrences of 02:30 on the autumn clock-change day belong together.
        ledger.feeds = [bottle(date("2026-10-25T00:30:00Z")), bottle(date("2026-10-25T01:30:00Z"))]
        let days = ledger.feedingDays(count: 3, endingAt: date("2026-10-26T12:00:00Z"), calendar: berlin)
        XCTAssertEqual(days[1].feedCount, 2)
        XCTAssertEqual(days[1].volume.totalML, 160)
    }

    func testObservationOnlyDayHasNoRecordsAndDaysFollowTimeZones() throws {
        let now = date("2026-10-16T12:00:00Z")
        var ledger = Ledger()
        ledger.hungerCues = [HungerCue(recordedAt: date("2026-10-15T23:30:00Z"))]
        XCTAssertFalse(try XCTUnwrap(ledger.feedingDays(count: 1, endingAt: now, calendar: berlin).first).hasRecords)
        ledger.feeds = [Feed(startedAt: date("2026-10-15T23:30:00Z"), endedAt: date("2026-10-15T23:35:00Z"),
                             kind: .formula, millilitres: 60)]
        let day = try XCTUnwrap(ledger.feedingDays(count: 1, endingAt: now, calendar: berlin).first)
        XCTAssertTrue(day.hasRecords)
        XCTAssertEqual(day.feedCount, 1)
        XCTAssertEqual(day.breastSeconds, 0)
        var utc = berlin; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertFalse(ledger.feedingDays(count: 1, endingAt: now, calendar: utc)[0].hasRecords)
    }

    func testMilkProgressStepsThroughTheLocalDayAndStopsAtTheGivenTime() {
        var ledger = Ledger()
        let breast = date("2026-03-10T09:00:00Z")
        ledger.feeds = [
            bottle(date("2026-03-09T22:30:00Z"), ml: 50),               // 23:30 the previous Berlin day
            bottle(date("2026-03-10T01:00:00Z"), ml: 120),
            Feed(startedAt: breast, endedAt: breast.addingTimeInterval(600), kind: .breast,
                 leftSeconds: 600, estimatedMillilitres: 30),
            Feed(startedAt: breast.addingTimeInterval(3600), endedAt: breast.addingTimeInterval(4200), kind: .breast, leftSeconds: 600),
            bottle(date("2026-03-10T12:00:00Z"), ml: 90, kind: .formula),
            Feed(startedAt: date("2026-03-10T13:00:00Z"), endedAt: date("2026-03-10T13:01:00Z"), kind: .expressed,
                 millilitres: 70, deletedAt: date("2026-03-10T13:05:00Z")),
            bottle(date("2026-03-10T20:00:00Z"), ml: 100),
        ]
        let now = date("2026-03-10T15:00:00Z")
        let points = ledger.milkProgress(on: now, until: now, calendar: berlin)
        XCTAssertEqual(points.map(\.time), [date("2026-03-09T23:00:00Z"), date("2026-03-10T01:00:00Z"), breast,
                                            date("2026-03-10T12:00:00Z"), now])
        XCTAssertEqual(points.map(\.totalML), [0, 120, 150, 240, 240])

        let fullDay = ledger.milkProgress(on: now, calendar: berlin)
        XCTAssertEqual(fullDay.last, MilkProgressPoint(time: date("2026-03-10T23:00:00Z"), totalML: 340))
        XCTAssertEqual(fullDay.last?.totalML, VolumeSummary(feeds: ledger.feeds(on: now, calendar: berlin)).totalML)
    }
}
