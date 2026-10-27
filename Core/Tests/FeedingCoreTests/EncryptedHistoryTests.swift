import XCTest
import CryptoKit
@testable import FeedingCore

final class EncryptedHistoryTests: XCTestCase {
    let key = Data(repeating: 42, count: 32)
    func feed() -> Feed {
        Feed(startedAt: Date(timeIntervalSince1970: 1700000000), endedAt: Date(timeIntervalSince1970: 1700000300),
             kind: .formula, millilitres: 90, notes: "Private note",
             revision: FeedRevision(counter: 7, device: UUID().uuidString.lowercased()))
    }
    func testPacketKeepsFeedContentsEncryptedAndRoundTripsDeletion() throws {
        var original = feed(); original.deletedAt = Date()
        let packet = try HistoryPacket.seal(original, key: key)
        let data = try JSONEncoder().encode(packet)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private note"))
        XCTAssertEqual(try packet.open(key: key), original)
        XCTAssertNotEqual(try HistoryPacket.seal(original, key: key).ciphertext, packet.ciphertext)
    }
    func testWrongKeyTamperingAndRevisionSubstitutionAreRejected() throws {
        let original = try HistoryPacket.seal(feed(), key: key)
        XCTAssertThrowsError(try original.open(key: Data(repeating: 43, count: 32)))
        var altered = original; altered.counter = "8"
        XCTAssertThrowsError(try altered.open(key: key))
        altered = original; altered.id = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try altered.open(key: key))
        altered = original; altered.device = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try altered.open(key: key))
        altered = original; var bytes = Data(base64Encoded: altered.ciphertext)!; bytes[20] ^= 1
        altered.ciphertext = bytes.base64EncodedString()
        XCTAssertThrowsError(try altered.open(key: key))
    }
    func testTwoPhonesMergeEncryptedOfflineEditsAndTombstones() throws {
        let caregiverBID = UUID().uuidString.lowercased(), caregiverAID = UUID().uuidString.lowercased()
        var caregiverB = Ledger(); try caregiverB.upsert(feed()); try caregiverB.stampFeedChanges(since: Ledger(), device: caregiverBID)
        var caregiverA = Ledger()
        try caregiverA.mergeSharedFeeds(caregiverB.feeds.map { try HistoryPacket.seal($0, key: key).open(key: key) })
        let old = caregiverA
        caregiverA.feeds[0].millilitres = 120; try caregiverA.stampFeedChanges(since: old, device: caregiverAID)
        let previous = caregiverB; caregiverB.setDeleted(caregiverB.feeds[0].id, at: Date()); try caregiverB.stampFeedChanges(since: previous, device: caregiverBID)
        let caregiverBPackets = try caregiverB.feeds.map { try HistoryPacket.seal($0, key: key) }
        let caregiverAPackets = try caregiverA.feeds.map { try HistoryPacket.seal($0, key: key) }
        try caregiverB.mergeSharedFeeds(caregiverAPackets.map { try $0.open(key: key) })
        try caregiverA.mergeSharedFeeds(caregiverBPackets.map { try $0.open(key: key) })
        XCTAssertEqual(caregiverB.feeds, caregiverA.feeds)
    }
}
