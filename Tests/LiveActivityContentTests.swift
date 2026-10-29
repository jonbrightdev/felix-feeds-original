import XCTest
import FeedingCore

final class LiveActivityContentTests: XCTestCase {
    func testExistingInstalledActivityStillDecodesWithoutNewFields() throws {
        let data = Data(#"{"startedAt":700000000,"detail":"Formula · 90 ml","isFeeding":false,"isPaused":false,"languageCode":"en"}"#.utf8)
        let state = try JSONDecoder().decode(FeedingActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(state.resolved(using: nil), state)
        XCTAssertNil(state.encryptedSnapshot)
        let attributes = try JSONDecoder().decode(FeedingActivityAttributes.self,
            from: Data(#"{"feedID":"11111111-1111-4111-8111-111111111111"}"#.utf8))
        XCTAssertNil(attributes.remoteUpdates)
    }

    func testAPNsPayloadDecodesAndDisplaysOnReceivingPhonesLocale() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = Ledger()
        ledger.feeds = [Feed(startedAt: start, endedAt: start, kind: .formula, millilitres: 90)]
        let key = try LiveActivitySnapshot.displayKey(familyKey: Data(repeating: 37, count: 32),
            historyID: "11111111-1111-4111-8111-111111111111")
        let encrypted = try LiveActivitySnapshot(ledger: ledger).seal(key: key)
        // Same wire contract as the server; dates use ActivityKit's default coding.
        let wire = try JSONSerialization.data(withJSONObject: ["startedAt": 0, "detail": "",
            "isFeeding": false, "isPaused": false, "encryptedSnapshot": encrypted])
        let state = try JSONDecoder().decode(FeedingActivityAttributes.ContentState.self, from: wire)
        let resolved = state.resolved(using: .init(key: key, languageCode: "de"))
        XCTAssertEqual(resolved.startedAt, start)
        XCTAssertEqual(resolved.feedID, ledger.feeds[0].id)
        XCTAssertEqual(resolved.detail, "Säuglingsnahrung · 90 ml")
        XCTAssertEqual(resolved.hasFeed, true)
        XCTAssertEqual(resolved.languageCode, "de")
        XCTAssertFalse(resolved.isFeeding)
        XCTAssertEqual(state.resolved(using: nil).hasFeed, false)
        XCTAssertEqual(state.resolved(using: .init(key: Data(repeating: 0, count: 32), languageCode: "de")).hasFeed, false)
    }

    func testDeletingLastFeedShowsEmptyStateInsteadOfAnEpochTimer() throws {
        let key = Data(repeating: 37, count: 32)
        let state = FeedingActivityAttributes.ContentState(startedAt: Date(timeIntervalSinceReferenceDate: 0),
            detail: "", isFeeding: false, isPaused: false,
            encryptedSnapshot: try LiveActivitySnapshot(ledger: Ledger()).seal(key: key))
        let resolved = state.resolved(using: .init(key: key, languageCode: "en"))
        XCTAssertEqual(resolved.hasFeed, false)
        XCTAssertEqual(resolved.detail, "No saved feeds")
    }
}
