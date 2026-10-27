import Foundation
import Security
import FeedingCore

struct PrivateHistoryConfiguration: Codable {
    // Configure an exact trusted HTTPS origin locally; no live service is bundled.
    static let origin = Bundle.main.object(forInfoDictionaryKey: "FelixSyncOrigin") as? String
        ?? "https://sync.example.invalid"
    let endpoint: String
    let siteToken: String
    let deviceToken: String
    let familyKey: String
    let historyID: String
    var key: Data { Data(base64Encoded: familyKey) ?? Data() }
    func validate() throws {
        guard endpoint == Self.origin, !siteToken.isEmpty, siteToken.count < 8192,
              siteToken.rangeOfCharacter(from: .newlines) == nil,
              deviceToken.count == 64, deviceToken.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              key.count == 32, UUID(uuidString: historyID) != nil else {
            throw FeedingError.invalid("The private sync setup is invalid.")
        }
    }
}

enum PrivateHistoryKeychain {
    static let service = "com.jonbright.FelixFeeds.privateHistory"
    static let account = "connection-v1"
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
                                      kSecAttrService as String: service, kSecAttrAccount as String: account] }
    static func load() throws -> PrivateHistoryConfiguration? {
        var request = query; request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw FeedingError.invalid("Unlock this phone to open the private sync keys.") }
        let config = try JSONDecoder().decode(PrivateHistoryConfiguration.self, from: data)
        try config.validate(); return config
    }
    static func save(_ config: PrivateHistoryConfiguration) throws {
        try config.validate()
        let data = try JSONEncoder().encode(config)
        var attributes: [String: Any] = [kSecValueData as String: data,
                                        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            attributes.merge(query) { a, _ in a }
            guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw FeedingError.invalid("The private sync keys could not be saved securely.") }
        } else if result != errSecSuccess { throw FeedingError.invalid("The private sync keys could not be updated securely.") }
    }
}

enum HistorySyncCollection: String { case feeds = "/api/sync", observations = "/api/observations", pumping = "/api/pumping" }

/// A service deployed before pumping existed answers 404 for its collection.
struct PumpingSyncUnavailable: Error {}

// Never follow a redirect carrying either credential to another endpoint.
final class PrivateHistoryTransport: NSObject, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func exchange(_ packets: [HistoryPacket], cursor: String? = nil, config: PrivateHistoryConfiguration, collection: HistorySyncCollection = .feeds) async throws -> HistorySyncPage {
        try config.validate()
        struct Request: Encodable { let records: [HistoryPacket]; let cursor: String? }
        var request = URLRequest(url: URL(string: config.endpoint + collection.rawValue)!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + config.siteToken, forHTTPHeaderField: "OAI-Sites-Authorization")
        request.setValue("Bearer " + config.deviceToken, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(Request(records: packets, cursor: cursor))
        let (data, response) = try await session.data(for: request)
        if collection == .pumping, (response as? HTTPURLResponse)?.statusCode == 404 { throw PumpingSyncUnavailable() }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw FeedingError.invalid("The private service could not be reached or this phone needs pairing again.")
        }
        guard data.count <= 5_000_000 else { throw FeedingError.invalid("The sync response is too large.") }
        let page = try JSONDecoder().decode(HistorySyncPage.self, from: data)
        guard page.records.count <= 40, page.nextCursor.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw FeedingError.invalid("The sync service returned an invalid page.")
        }
        return page
    }
}
