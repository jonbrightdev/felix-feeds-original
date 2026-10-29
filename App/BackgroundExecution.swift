import UIKit

/// A bounded chance to finish a user-initiated save after the screen locks.
/// iOS expiration cancels network work; the ledger remains the durable outbox.
@MainActor final class BackgroundExecution {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    init(name: String, expiration: @escaping @MainActor () -> Void) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { expiration(); self?.end() }
        }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
    }
}
