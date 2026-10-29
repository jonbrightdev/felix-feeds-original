import ActivityKit
import FeedingCore
import Observation
import Foundation

@MainActor @Observable final class ActivityPushController {
    // Free-account builds retain local ActivityKit and ordinary history sync.
    // Push is opt-in only after the signing and service setup is available.
    static var supportedBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "FelixRemoteTimerUpdates") as? String == "YES"
    }
    private(set) var available = false
    private(set) var status = "Remote timer updates are not configured."
    private(set) var deliveryStatus = "Timer updates are sent after feeds sync."
    @ObservationIgnored private var credentials = supportedBuild ? try? ActivityPushCredentials.load() : nil
    @ObservationIgnored private let transport = PrivateHistoryTransport()
    @ObservationIgnored private var tokenWatcher: Task<Void, Never>?
    @ObservationIgnored private var stateWatcher: Task<Void, Never>?
    @ObservationIgnored private var registrationWork: Task<Void, Never>?
    @ObservationIgnored private var observedID: String?
    @ObservationIgnored private var desired: ActivityPushRequest?
    @ObservationIgnored private var lastRegistered: ActivityPushRequest?
    private let defaults = UserDefaults.standard

    func configure(_ config: PrivateHistoryConfiguration?, enabled: Bool) {
        guard Self.supportedBuild else { available = false; return }
        do {
            if let config {
                let key = try LiveActivitySnapshot.displayKey(familyKey: config.key, historyID: config.historyID)
                let existing = ActivityDisplayKeychain.load()
                if existing?.key != key || existing?.languageCode != L10n.languageCode {
                    try ActivityDisplayKeychain.save(.init(key: key, languageCode: L10n.languageCode))
                }
                credentials = ActivityPushCredentials(config)
                try credentials?.save()
            }
            available = enabled && credentials != nil && ActivityDisplayKeychain.load() != nil
        } catch {
            available = false
            status = "Open the app to finish setting up remote timer updates."
        }
        if !available { observe(nil) }
    }

    func restoreExistingActivity() {
        guard Self.supportedBuild else { return }
        let timerEnabled = defaults.object(forKey: "liveActivityEnabled") as? Bool ?? true
        observe(timerEnabled ? Activity<FeedingActivityAttributes>.activities.first {
            $0.attributes.remoteUpdates == true && ($0.activityState == .active || $0.activityState == .stale)
        } : nil)
    }

    func observe(_ activity: Activity<FeedingActivityAttributes>?) {
        guard Self.supportedBuild else { return }
        let activity = available ? activity : nil
        guard observedID != activity?.id else {
            if activity == nil, defaults.bool(forKey: "activityRemoteRegistered"), desired == nil { unregister() }
            retryRegistration(); return
        }
        tokenWatcher?.cancel(); stateWatcher?.cancel()
        observedID = activity?.id
        guard let activity else { unregister(); return }
        status = "Connecting the Lock Screen timer…"
        tokenWatcher = Task { [weak self] in
            if let token = activity.pushToken { self?.register(token, for: activity) }
            for await token in activity.pushTokenUpdates {
                guard !Task.isCancelled, let self, self.observedID == activity.id else { return }
                self.register(token, for: activity)
            }
        }
        stateWatcher = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.observedID == activity.id else { return }
                if state == .ended || state == .dismissed { self.observe(nil); return }
            }
        }
    }

    private func register(_ token: Data, for activity: Activity<FeedingActivityAttributes>) {
        guard available, observedID == activity.id, let createdAt = activity.attributes.createdAt else { return }
        let request = ActivityPushRequest(action: "register", activityID: activity.id,
            token: token.map { String(format: "%02x", $0) }.joined(),
            environment: Bundle.main.object(forInfoDictionaryKey: "FelixAPNSEnvironment") as? String ?? "development",
            expiresAt: Int(createdAt.addingTimeInterval(8 * 3600).timeIntervalSince1970))
        setDesired(request)
    }
    private func unregister() {
        guard credentials != nil else { return }
        setDesired(ActivityPushRequest(action: "unregister"))
    }
    private func setDesired(_ request: ActivityPushRequest) {
        var old = desired; old?.registration = nil
        if old == request { retryRegistration(); return }
        var request = request
        let next = max(Int64(Date().timeIntervalSince1970 * 1000), Int64(defaults.double(forKey: "activityRegistrationRevision")) + 1)
        defaults.set(next, forKey: "activityRegistrationRevision")
        request.registration = next
        desired = request
        // Remember even an interrupted registration, so pausing after relaunch
        // still revokes it. Tokens themselves are not persisted in preferences.
        defaults.set(true, forKey: "activityRemoteRegistered")
        retryRegistration()
    }
    func retryRegistration() {
        guard Self.supportedBuild else { return }
        guard registrationWork == nil, let credentials, desired != lastRegistered, desired != nil else { return }
        registrationWork = Task { [weak self] in
            guard let self else { return }
            let background = BackgroundExecution(name: "Register feeding timer") { [weak self] in self?.registrationWork?.cancel() }
            defer { background.end(); self.registrationWork = nil }
            var failures = 0
            while !Task.isCancelled, let request = self.desired, request != self.lastRegistered {
                do {
                    let ready = try await self.transport.activity(request, credentials: credentials)
                    if ready || request.action == "unregister" { self.lastRegistered = request }
                    if request == self.desired {
                        self.defaults.set(request.action == "register", forKey: "activityRemoteRegistered")
                        self.status = request.action == "unregister" ? "Remote timer updates are off on this phone." :
                            ready ? "Remote timer updates are ready." : "The private service needs its timer update setup."
                    }
                    if !ready, request == self.desired { return }
                } catch is ActivityRegistrationRejected {
                    if request != self.desired { continue }
                    if request == self.desired {
                        self.available = false
                        self.observe(nil)
                        self.status = "Reopen the app to reconnect remote timer updates."
                    }
                    return
                } catch {
                    self.status = "Timer updates will retry. Your feeds are saved."
                    failures += 1
                    guard failures < 3, !Task.isCancelled else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    func publish(_ ledger: Ledger, config: PrivateHistoryConfiguration) async throws {
        guard Self.supportedBuild else { return }
        let key = try LiveActivitySnapshot.displayKey(familyKey: config.key, historyID: config.historyID)
        let request = ActivityPushRequest(action: "publish", digest: try LiveActivitySnapshot.historyDigest(ledger.feeds),
            ciphertext: try LiveActivitySnapshot(ledger: ledger).seal(key: key))
        for attempt in 0..<2 {
            do {
                try Task.checkCancellation()
                let ready = try await transport.activity(request, credentials: ActivityPushCredentials(config))
                deliveryStatus = ready ? "Shared timer update is saved." : "The private service needs its timer update setup."
                return
            } catch is ActivityHistoryChanged { throw ActivityHistoryChanged() }
            catch {
                // Feed upload succeeded. Push errors never block other records.
                deliveryStatus = "Timer updates will retry. Your feeds are saved."
                guard attempt == 0, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
