import ActivityKit
import FeedingCore
import Observation
import UIKit

@MainActor @Observable final class FeedActivityController {
    private(set) var systemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    private var pending: Task<Void, Never>?
    private let push: ActivityPushController
    init(push: ActivityPushController) { self.push = push }
    private(set) var status = "Log a feed to start the Lock Screen timer." {
        didSet { saveDiagnosticStatus() }
    }

    // Serialize updates so a quick edit/delete cannot publish an older record last.
    func refresh(_ ledger: Ledger, enabled: Bool, force: Bool = false, preserveRemote: Bool = false) {
        let glance = ledger.latestFeedGlance
        let previous = pending
        pending = Task {
            if let previous { await previous.value }
            await reconcile(glance, enabled: enabled, force: force, preserveRemote: preserveRemote)
        }
    }

    private func reconcile(_ glance: FeedGlance?, enabled: Bool, force: Bool, preserveRemote: Bool) async {
        systemEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        let existing = Activity<FeedingActivityAttributes>.activities
        if enabled, systemEnabled, push.available, preserveRemote, !force,
           let remote = existing.first(where: { $0.content.state.encryptedSnapshot != nil &&
               ($0.activityState == .active || $0.activityState == .stale) }) {
            push.observe(remote)
            return
        }
        guard enabled, let glance else {
            push.observe(nil)
            for activity in existing { await activity.end(nil, dismissalPolicy: .immediate) }
            status = enabled ? "Log a feed to start the Lock Screen timer." : "Lock Screen timer is off."
            return
        }
        guard systemEnabled else {
            push.observe(nil)
            status = "Live Activities are disabled in iPhone Settings. Your feeds are still saved normally."
            return
        }
        let state = FeedingActivityAttributes.ContentState(
            startedAt: glance.startedAt, detail: detail(glance),
            isFeeding: glance.isFeeding, isPaused: glance.isPaused, languageCode: L10n.languageCode, feedID: glance.id)
        let content = ActivityContent(state: state, staleDate: nil)
        let remoteUpdates = push.available && !glance.isFeeding
        let matching = existing.first {
            ($0.attributes.remoteUpdates ?? false) == remoteUpdates && ($0.activityState == .active || $0.activityState == .stale)
        }
        let canRequest = UIApplication.shared.applicationState == .active
        if let matching, !force, !canRequest || (matching.content.state.resolved.feedID ?? matching.attributes.feedID) == glance.id {
            for other in existing where other.id != matching.id {
                await other.end(nil, dismissalPolicy: .immediate)
            }
            if matching.content.state != state { await matching.update(content) }
            push.observe(remoteUpdates ? matching : nil)
            status = "Showing time since the latest feed started."
            return
        }
        // iOS may remove an activity during an update or while this app is stopped.
        // Absence is not evidence of a user dismissal. Restore on the next foreground
        // refresh whenever the user has enabled the Lock Screen timer.
        guard canRequest else {
            status = "Open the app to show the Lock Screen timer."
            return
        }
        let defaults = UserDefaults.standard
        do {
            let replacement = try Activity.request(
                attributes: FeedingActivityAttributes(feedID: glance.id, createdAt: .now, remoteUpdates: remoteUpdates),
                content: content, pushType: remoteUpdates ? .token : nil)
            // Keep the previous activity until its replacement exists. A failed
            // request must not remove an otherwise working Lock Screen display.
            for activity in existing where activity.id != replacement.id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            defaults.set(glance.id.uuidString, forKey: "liveActivityLastFeedID")
            defaults.set(Date.now, forKey: "liveActivityRequestedAt")
            push.observe(remoteUpdates ? replacement : nil)
            status = "Showing time since the latest feed started."
        } catch {
            status = L10n.format("Could not show the Lock Screen timer: %@", error.localizedDescription)
        }
    }

    // Local, non-sensitive diagnostics let the paired Mac verify actual ActivityKit
    // state without copying feeding contents or relying on an extension process.
    private func saveDiagnosticStatus() {
        #if DEBUG
        let activities = Activity<FeedingActivityAttributes>.activities
        let receipt: [String: Any] = [
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "checkedAt": ISO8601DateFormatter().string(from: Date()),
            "systemEnabled": systemEnabled,
            "status": status,
            "activeCount": activities.filter { $0.activityState == .active || $0.activityState == .stale }.count
        ]
        let directory = URL.applicationSupportDirectory.appending(path: "FelixFeeds")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
                .write(to: directory.appending(path: "live-activity-status.json"), options: .atomic)
        } catch { /* Diagnostics must never affect recording or ActivityKit. */ }
        #endif
    }

    private func detail(_ glance: FeedGlance) -> String {
        if glance.isFeeding { return L10n.text("Breastfeeding") }
        if let amount = glance.millilitres {
            let title = glance.isMixedBottle ? L10n.text("Mixed bottle") : glance.kind.title
            return "\(title) · \(amount) ml"
        }
        return L10n.text("Breastfeeding")
    }
}
