import ActivityKit
import Foundation
import FeedingCore

struct FeedingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var detail: String
        var isFeeding: Bool
        var isPaused: Bool
        var languageCode: String? = nil
        var encryptedSnapshot: String? = nil
        var hasFeed: Bool? = nil
        var feedID: UUID? = nil

        /// Remote content is authenticated and decrypted only on this device.
        /// A missing key or corrupt payload must never display a fabricated timer.
        var resolved: Self {
            guard encryptedSnapshot != nil else { return self }
            return resolved(using: ActivityDisplayKeychain.load())
        }
        func resolved(using config: ActivityDisplayKeychain.Configuration?) -> Self {
            guard let encryptedSnapshot else { return self }
            guard let config,
                  let snapshot = try? LiveActivitySnapshot.open(encryptedSnapshot, key: config.key) else {
                return Self(startedAt: .distantPast, detail: L10n.text("Open the app to refresh the timer."),
                            isFeeding: false, isPaused: false, hasFeed: false)
            }
            let locale = Locale(identifier: config.languageCode)
            return Self(startedAt: snapshot.feed?.startedAt ?? .distantPast,
                detail: snapshot.feed?.detail(locale: locale) ?? L10n.text("No saved feeds", locale: locale),
                isFeeding: false, isPaused: false, languageCode: config.languageCode,
                hasFeed: snapshot.feed != nil, feedID: snapshot.feed?.id)
        }
    }
    // Kept for compatibility with activities created by earlier app versions.
    // Remote feeds update ContentState on the same activity; attributes are immutable.
    var feedID: UUID
    var createdAt: Date? = nil
    var remoteUpdates: Bool? = nil
}
