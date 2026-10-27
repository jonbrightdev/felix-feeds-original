import Foundation
import CryptoKit

public struct HistoryPacket: Codable, Equatable, Sendable {
    public var id: String
    public var counter: String
    public var device: String
    public var ciphertext: String
    public var revision: FeedRevision? {
        guard let counter = Int64(counter), counter > 0 else { return nil }
        return FeedRevision(counter: counter, device: device)
    }
    public init(id: String, counter: String, device: String, ciphertext: String) {
        self.id = id; self.counter = counter; self.device = device; self.ciphertext = ciphertext
    }
    private var authenticatedMetadata: Data { Data("FelixFeeds/v1/\(id)/\(counter)/\(device)".utf8) }
    public static func seal(_ feed: Feed, key: Data) throws -> Self {
        try feed.validate()
        guard key.count == 32, let revision = feed.revision, revision.counter > 0,
              UUID(uuidString: revision.device) != nil else { throw FeedingError.invalid("A feed is not ready for encrypted sync.") }
        var packet = Self(id: feed.id.uuidString.lowercased(), counter: String(revision.counter),
                          device: revision.device.lowercased(), ciphertext: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let box = try AES.GCM.seal(encoder.encode(feed), using: SymmetricKey(data: key), authenticating: packet.authenticatedMetadata)
        guard let combined = box.combined else { throw FeedingError.invalid("Encryption could not finish.") }
        packet.ciphertext = combined.base64EncodedString()
        return packet
    }
    public func open(key: Data) throws -> Feed {
        guard key.count == 32, id == id.lowercased(), device == device.lowercased(), UUID(uuidString: id) != nil,
              UUID(uuidString: device) != nil, let revision, String(revision.counter) == counter,
              ciphertext.count <= 120000, let data = Data(base64Encoded: ciphertext) else {
            throw FeedingError.invalid("An encrypted feed is invalid.")
        }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: SymmetricKey(data: key), authenticating: authenticatedMetadata)
        let feed = try JSONDecoder().decode(Feed.self, from: clear)
        try feed.validate()
        guard feed.id.uuidString.lowercased() == id, let inner = feed.revision,
              inner.counter == revision.counter, inner.device.lowercased() == device else {
            throw FeedingError.invalid("An encrypted feed does not match its revision.")
        }
        return feed
    }
}

public struct HistorySyncPage: Codable, Sendable {
    public var records: [HistoryPacket]
    public var nextCursor: String?
}

public extension HistoryPacket {
    private var observationMetadata: Data { Data("FelixFeeds/observations/v1/\(id)/\(counter)/\(device)".utf8) }
    static func seal(_ cue: HungerCue, key: Data) throws -> Self {
        try cue.validate()
        guard key.count == 32, let revision = cue.revision, revision.counter > 0, UUID(uuidString: revision.device) != nil else {
            throw FeedingError.invalid("A hunger observation is not ready for encrypted sync.")
        }
        var packet = Self(id: cue.id.uuidString.lowercased(), counter: String(revision.counter), device: revision.device.lowercased(), ciphertext: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let box = try AES.GCM.seal(encoder.encode(cue), using: SymmetricKey(data: key), authenticating: packet.observationMetadata)
        guard let combined = box.combined else { throw FeedingError.invalid("Encryption could not finish.") }
        packet.ciphertext = combined.base64EncodedString(); return packet
    }
    func openHungerCue(key: Data) throws -> HungerCue {
        guard key.count == 32, id == id.lowercased(), device == device.lowercased(), UUID(uuidString: id) != nil,
              UUID(uuidString: device) != nil, let revision, String(revision.counter) == counter,
              ciphertext.count <= 120000, let encrypted = Data(base64Encoded: ciphertext) else {
            throw FeedingError.invalid("An encrypted hunger observation is invalid.")
        }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key), authenticating: observationMetadata)
        let cue = try JSONDecoder().decode(HungerCue.self, from: clear); try cue.validate()
        guard cue.id.uuidString.lowercased() == id, let inner = cue.revision,
              inner.counter == revision.counter, inner.device.lowercased() == device else {
            throw FeedingError.invalid("An encrypted hunger observation does not match its revision.")
        }
        return cue
    }
}

public extension HistoryPacket {
    private var pumpingMetadata: Data { Data("FelixFeeds/pumping/v1/\(id)/\(counter)/\(device)".utf8) }
    static func seal(_ session: PumpSession, key: Data) throws -> Self {
        try session.validate()
        guard key.count == 32, let revision = session.revision, revision.counter > 0, UUID(uuidString: revision.device) != nil else {
            throw FeedingError.invalid("A pumping session is not ready for encrypted sync.")
        }
        var packet = Self(id: session.id.uuidString.lowercased(), counter: String(revision.counter), device: revision.device.lowercased(), ciphertext: "")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let box = try AES.GCM.seal(encoder.encode(session), using: SymmetricKey(data: key), authenticating: packet.pumpingMetadata)
        guard let combined = box.combined else { throw FeedingError.invalid("Encryption could not finish.") }
        packet.ciphertext = combined.base64EncodedString(); return packet
    }
    func openPumpSession(key: Data) throws -> PumpSession {
        guard key.count == 32, id == id.lowercased(), device == device.lowercased(), UUID(uuidString: id) != nil,
              UUID(uuidString: device) != nil, let revision, String(revision.counter) == counter,
              ciphertext.count <= 120000, let encrypted = Data(base64Encoded: ciphertext) else {
            throw FeedingError.invalid("An encrypted pumping session is invalid.")
        }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: SymmetricKey(data: key), authenticating: pumpingMetadata)
        let session = try JSONDecoder().decode(PumpSession.self, from: clear); try session.validate()
        guard session.id.uuidString.lowercased() == id, let inner = session.revision,
              inner.counter == revision.counter, inner.device.lowercased() == device else {
            throw FeedingError.invalid("An encrypted pumping session does not match its revision.")
        }
        return session
    }
}
