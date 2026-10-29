import Foundation
import CryptoKit

/// Only the saved-feed glance travels through APNs. Notes, full records and the
/// local in-progress breastfeeding timer never enter this payload.
public struct LiveActivitySnapshot: Codable, Equatable, Sendable {
    public struct SavedFeed: Codable, Equatable, Sendable {
        public let id: UUID
        public let startedAt: Date
        public let kind: FeedKind
        public let millilitres: Int?
        public let isMixedBottle: Bool

        public func detail(locale: Locale) -> String {
            let title = L10n.text(isMixedBottle ? "Mixed bottle" : kind == .breast ? "Breastfeeding" : kind == .formula ? "Formula" : "Expressed milk", locale: locale)
            return millilitres.map { "\(title) · \($0) ml" } ?? title
        }
    }

    public let version: Int
    public let feed: SavedFeed?
    private static let context = Data("FelixFeeds/live-activity/v1".utf8)

    public init(ledger: Ledger) {
        version = 1
        let latest = ledger.feeds.filter { $0.deletedAt == nil }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString > $1.id.uuidString : $0.startedAt > $1.startedAt
        }.first
        feed = latest.map { SavedFeed(id: $0.id, startedAt: $0.startedAt, kind: $0.kind,
            millilitres: $0.kind == .breast ? nil : $0.millilitres, isMixedBottle: $0.isMixedBottle) }
    }

    /// The widget receives a derived display key, never the family history key
    /// or either service credential. Different histories have different keys.
    public static func displayKey(familyKey: Data, historyID: String) throws -> Data {
        guard familyKey.count == 32, let id = UUID(uuidString: historyID) else {
            throw FeedingError.invalid("The private sync setup is invalid.")
        }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: familyKey),
            salt: Data(id.uuidString.lowercased().utf8), info: context, outputByteCount: 32)
        return key.withUnsafeBytes { Data($0) }
    }

    public func seal(key: Data) throws -> String {
        guard key.count == 32 else { throw FeedingError.invalid("Invalid timer key.") }
        let box = try AES.GCM.seal(JSONEncoder().encode(self), using: SymmetricKey(data: key), authenticating: Self.context)
        guard let combined = box.combined else { throw FeedingError.invalid("Encryption could not finish.") }
        return combined.base64EncodedString()
    }

    public static func open(_ ciphertext: String, key: Data) throws -> Self {
        guard key.count == 32, ciphertext.count <= 2500, let encrypted = Data(base64Encoded: ciphertext) else {
            throw FeedingError.invalid("Invalid encrypted timer.")
        }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key), authenticating: context)
        let snapshot = try JSONDecoder().decode(Self.self, from: data)
        guard snapshot.version == 1,
              snapshot.feed.map({ $0.startedAt.timeIntervalSince1970.isFinite &&
                  ($0.millilitres.map { (1...2000).contains($0) } ?? true) }) ?? true else {
            throw FeedingError.invalid("Invalid encrypted timer.")
        }
        return snapshot
    }

    /// Must match the server's complete revision inventory before publishing.
    /// Includes tombstones; a stale phone cannot roll the timer back after a
    /// concurrent edit, deletion or a feed on a later page.
    public static func historyDigest(_ feeds: [Feed]) throws -> String {
        let lines = try feeds.sorted { $0.id.uuidString < $1.id.uuidString }.map { feed -> String in
            guard let revision = feed.revision, revision.counter > 0, UUID(uuidString: revision.device) != nil else {
                throw FeedingError.invalid("A feed is not ready for encrypted sync.")
            }
            return "\(feed.id.uuidString.lowercased())/\(revision.counter)/\(revision.device.lowercased())\n"
        }.joined()
        return SHA256.hash(data: Data(lines.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
