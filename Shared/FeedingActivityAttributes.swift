import ActivityKit
import Foundation

struct FeedingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var startedAt: Date
        var detail: String
        var isFeeding: Bool
        var isPaused: Bool
        var languageCode: String? = nil
    }
    var feedID: UUID
}
