import XCTest
import CryptoKit
@testable import FeedingCore

final class LiveActivitySnapshotTests: XCTestCase {
    private let familyKey = Data(repeating: 37, count: 32)
    private let history = "11111111-1111-4111-8111-111111111111"
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func bottle(id: UUID = UUID(), at: Date? = nil, counter: Int64 = 1) -> Feed {
        var feed = Feed(id: id, startedAt: at ?? base, endedAt: at ?? base, kind: .formula, millilitres: 90, notes: "Private note")
        feed.revision = FeedRevision(counter: counter, device: history)
        return feed
    }

    func testEncryptedRoundTripAndPayloadContainsNoNotesOrHistoryKey() throws {
        var ledger = Ledger(); ledger.feeds = [bottle()]
        let snapshot = LiveActivitySnapshot(ledger: ledger)
        let key = try LiveActivitySnapshot.displayKey(familyKey: familyKey, historyID: history)
        XCTAssertNotEqual(key, familyKey)
        let encrypted = try snapshot.seal(key: key)
        XCTAssertEqual(try LiveActivitySnapshot.open(encrypted, key: key), snapshot)
        XCTAssertNotEqual(try snapshot.seal(key: key), encrypted)
        XCTAssertLessThan(encrypted.utf8.count, 2500)
        let plain = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
        XCTAssertFalse(plain.contains("Private note")); XCTAssertFalse(plain.contains("notes"))
        XCTAssertFalse(encrypted.contains("formula")); XCTAssertFalse(encrypted.contains("startedAt"))
    }

    func testAuthenticationRejectsTamperingWrongHistoryAndHistoryPackets() throws {
        var ledger = Ledger(); ledger.feeds = [bottle()]
        let key = try LiveActivitySnapshot.displayKey(familyKey: familyKey, historyID: history)
        let encrypted = try LiveActivitySnapshot(ledger: ledger).seal(key: key)
        var tampered = try XCTUnwrap(Data(base64Encoded: encrypted)); tampered[tampered.count - 1] ^= 1
        XCTAssertThrowsError(try LiveActivitySnapshot.open(tampered.base64EncodedString(), key: key))
        let other = try LiveActivitySnapshot.displayKey(familyKey: familyKey, historyID: UUID().uuidString)
        XCTAssertThrowsError(try LiveActivitySnapshot.open(encrypted, key: other))
        XCTAssertThrowsError(try LiveActivitySnapshot.open(encrypted, key: familyKey))
        let packet = try HistoryPacket.seal(ledger.feeds[0], key: familyKey)
        XCTAssertThrowsError(try LiveActivitySnapshot.open(packet.ciphertext, key: key))
        XCTAssertThrowsError(try LiveActivitySnapshot.open(String(repeating: "a", count: 2501), key: key))
    }

    func testOnlyLatestSavedFeedIsProjectedAndDeletionFallsBack() throws {
        var ledger = Ledger()
        let earlier = bottle(), later = bottle(at: base.addingTimeInterval(600), counter: 2)
        ledger.feeds = [later, earlier]
        try ledger.start(side: .left, now: base.addingTimeInterval(1200))
        XCTAssertEqual(LiveActivitySnapshot(ledger: ledger).feed?.id, later.id)
        ledger.setDeleted(later.id, at: base.addingTimeInterval(1800))
        XCTAssertEqual(LiveActivitySnapshot(ledger: ledger).feed?.id, earlier.id)
        ledger.setDeleted(earlier.id, at: base.addingTimeInterval(1800))
        XCTAssertNil(LiveActivitySnapshot(ledger: ledger).feed)
        XCTAssertNotNil(ledger.active)
    }

    func testMixedBottleAndUnknownBreastfeedingVolumeKeepTheirMeaning() throws {
        var ledger = Ledger()
        ledger.feeds = [Feed(startedAt: base, endedAt: base, kind: .expressed, millilitres: 100, formulaMillilitres: 40)]
        let mixed = try XCTUnwrap(LiveActivitySnapshot(ledger: ledger).feed)
        XCTAssertTrue(mixed.isMixedBottle)
        XCTAssertEqual(mixed.detail(locale: Locale(identifier: "de")), "Gemischtes Fläschchen · 100 ml")
        ledger.feeds = [Feed(startedAt: base, endedAt: base.addingTimeInterval(600), kind: .breast, leftSeconds: 600)]
        let breast = try XCTUnwrap(LiveActivitySnapshot(ledger: ledger).feed)
        XCTAssertNil(breast.millilitres)
        XCTAssertEqual(breast.detail(locale: Locale(identifier: "en")), "Breastfeeding")
    }

    func testEqualStartTimesChooseSameFeedRegardlessOfMergeOrder() {
        var ledger = Ledger()
        let first = bottle(id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        let second = bottle(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!)
        ledger.feeds = [first, second]
        let snapshot = LiveActivitySnapshot(ledger: ledger)
        ledger.feeds.reverse()
        XCTAssertEqual(snapshot, LiveActivitySnapshot(ledger: ledger))
        XCTAssertEqual(snapshot.feed?.id, second.id)
    }

    func testDigestIncludesTombstonesAndExactInt64RevisionsButNotFeedContents() throws {
        var first = bottle(id: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!, counter: 9_223_372_036_854_775_806)
        let second = bottle(id: UUID(uuidString: history)!, counter: 2)
        let digest = try LiveActivitySnapshot.historyDigest([first, second])
        // Shared wire fixture with the JavaScript relay (including exact Int64 digits).
        XCTAssertEqual(digest, "6c23e4702ab92341b18726615f26f2921938609a084049d67ca067d741276bbf")
        XCTAssertEqual(digest, try LiveActivitySnapshot.historyDigest([second, first]))
        first.notes = "Another private note"
        XCTAssertEqual(digest, try LiveActivitySnapshot.historyDigest([first, second]))
        first.deletedAt = base; first.revision!.counter += 1
        XCTAssertNotEqual(digest, try LiveActivitySnapshot.historyDigest([first, second]))
        XCTAssertNotEqual(try LiveActivitySnapshot.historyDigest([second]), try LiveActivitySnapshot.historyDigest([first, second]))
        first.revision = nil
        XCTAssertThrowsError(try LiveActivitySnapshot.historyDigest([first]))
        XCTAssertEqual(try LiveActivitySnapshot.historyDigest([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
