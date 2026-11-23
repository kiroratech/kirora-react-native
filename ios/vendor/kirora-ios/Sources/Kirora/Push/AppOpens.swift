import Foundation

/// Kirora accepts an app open up to 7 days old.
private let appOpenMaxAge: Double = 7 * 24 * 60 * 60
/// At most this many wait, oldest dropped: a device offline for a week opens the app a lot.
private let maxPendingAppOpens = 50

/// Reports each cold launch and return to the foreground (`POST /devices/{id}/app-opens`)
/// so Kirora can count opens a push influenced without a tap. Not an event: sent whether
/// or not the app tracks lifecycle events, and never counted against the plan.
///
/// Only for a signed-in user on a device registered for push, at most once per visit (30
/// minutes), and only while behavioural tracking is allowed: nothing of it is stored or
/// sent otherwise. Queued and retried as events are; dropped on 404 or 400, once 7 days
/// old, and when tracking consent is withdrawn.
final class AppOpens: @unchecked Sendable {
    private struct Pending: Codable, Equatable {
        var occurredAt: String
        var pushAppId: String
        var owner: String
    }

    private struct State {
        /// The waiting opens, read once from the store and kept in step with it.
        var pending: [Pending]?
        var sending: Task<Void, Never>?
        /// Asked to send while a send ran: it goes again once done.
        var rerun = false
        var retry: Task<Void, Never>?
        var backoff: Backoff
        var destroyed = false
    }

    private let api: ClientAPI
    private let identity: Identity
    private let store: KeyValueStore
    private let registrar: PushRegistrar
    private let deviceId: DeviceId
    private let consent: TrackingConsent
    private let log: Log
    private let now: @Sendable () -> Date
    private let key: String
    private let state: Locked<State>
    /// When the app came to the foreground before anyone had signed in: claimed by a
    /// sign-in in the same foreground stay, as the app calls identify() at every start.
    private let unclaimed = Locked<Date?>(nil)
    /// Where the spacing is kept: saved with visits on, so it holds across launches; in
    /// memory with visits off, as no visit is stored.
    private let spacing: KeyValueStore

    init(
        api: ClientAPI, identity: Identity, store: KeyValueStore, registrar: PushRegistrar,
        deviceId: DeviceId, consent: TrackingConsent, log: Log, timing: DeliveryTiming,
        trackSessions: Bool = true, now: @escaping @Sendable () -> Date
    ) {
        spacing = trackSessions ? store : MemoryKeyValueStore()
        self.consent = consent
        self.api = api
        self.identity = identity
        self.store = store
        self.registrar = registrar
        self.deviceId = deviceId
        self.log = log
        self.now = now
        key = StorageKeys.appOpens(api.namespace)
        state = Locked(State(backoff: Backoff(timing)))
    }

    /// The app launched or came to the foreground. Counted only if a new visit begins.
    /// Nothing is stored, or sent, unless push is on: app opens are push reporting.
    func appCameToForeground() {
        guard collecting else { return }
        let at = now()
        let newVisit = isNewVisit(at)
        touchVisit()
        guard newVisit else { return }
        if let user = identity.capturingUser {
            queue(at, for: user)
            send()
        } else {
            unclaimed.withLock { $0 = at }
        }
    }

    /// Activity in the foreground keeps the visit going.
    func touchVisit() {
        guard collecting else { return }
        spacing.set(String(epochMs(now())), for: StorageKeys.appOpenActivity)
    }

    func appWentToBackground() {
        guard collecting else { return }
        touchVisit()
        unclaimed.withLock { $0 = nil }
    }

    /// After sign-in and push registration: claim this start's open, and send what waits.
    func onSignedIn(_ user: SignedInUser) {
        // `queue` checks consent.
        if let unclaimed = unclaimed.take() { queue(unclaimed, for: user) }
        send()
    }

    /// Tracking consent was withdrawn: forgets every waiting open, the visit's spacing and
    /// any scheduled retry.
    func forget() {
        unclaimed.withLock { $0 = nil }
        state.withLock { state in
            state.retry?.cancel()
            state.retry = nil
            state.sending?.cancel()
            state.pending = []
        }
        store.set(nil, for: key)
        spacing.set(nil, for: StorageKeys.appOpenActivity)
    }

    /// App opens are push reporting that needs behavioural tracking consent.
    private var collecting: Bool { registrar.enabled && consent.allowed }

    /// Forgets `subject`'s opens, at sign-out.
    func clear(owner subject: String) {
        modify { $0.removeAll { $0.owner == subject } }
        unclaimed.withLock { $0 = nil }
    }

    func destroy() {
        state.withLock { state in
            state.destroyed = true
            state.retry?.cancel()
        }
    }

    /// Sends what waits for the signed-in user. One send at a time; one asked for meanwhile
    /// (another user signed in) runs once it's done.
    func send() {
        state.withLock { state in
            guard !state.destroyed else { return }
            guard state.sending == nil else { return state.rerun = true }
            state.sending = Task {
                repeat {
                    await self.sendPending()
                } while self.state.withLock { state -> Bool in
                    defer { state.rerun = false }
                    guard state.rerun, !state.destroyed else {
                        state.sending = nil
                        return false
                    }
                    return true
                }
            }
        }
    }

    private func queue(_ at: Date, for user: SignedInUser) {
        // Never while unregistered for push: Kirora only credits a registered device.
        guard consent.allowed, let pushAppId = registrar.pushAppId(for: user) else { return }
        modify { pending in
            pending.append(Pending(occurredAt: isoTimestamp(at), pushAppId: pushAppId, owner: user.subject))
            if pending.count > maxPendingAppOpens { pending.removeFirst(pending.count - maxPendingAppOpens) }
        }
    }

    private func sendPending() async {
        guard let user = identity.sendingUser else { return }
        if Date() < state.withLock({ $0.backoff.notBefore() }) { return }
        // Kirora takes an app open up to 7 days old.
        let oldest = now().addingTimeInterval(-appOpenMaxAge)
        modify { $0.removeAll { (parseIsoTimestamp($0.occurredAt) ?? .distantPast) < oldest } }
        while identity.user === user, !state.withLock({ $0.destroyed }), consent.allowed {
            guard let next = modify({ $0.first { $0.owner == user.subject } }) else {
                state.withLock { $0.backoff.succeeded() }
                return
            }
            do {
                try await api.request(
                    "POST", "/devices/\(deviceId.value())/app-opens",
                    body: JSONValue.object(["occurredAt": .string(next.occurredAt), "pushAppId": .string(next.pushAppId)]),
                    as: user
                )
                log.debug("Reported an app open")
                remove(next)
            } catch let error as KiroraApiError where error.status == 404 || error.status == 400 {
                // Not registered to this user any more, or too old: the next start registers.
                log.debug("App open dropped: \(error)")
                remove(next)
            } catch let error as KiroraApiError where error.status == 401 {
                log.error("App open not sent", error)
                return
            } catch {
                if !Task.isCancelled { retryLater(error) }
                return
            }
        }
    }

    private func retryLater(_ error: Error) {
        state.withLock { state in
            guard !state.destroyed else { return }
            let delay = state.backoff.failed(error).timeIntervalSinceNow
            state.retry?.cancel()
            // Weak, so a client released without destroy() isn't kept alive by a long wait.
            state.retry = Task { [weak self] in
                await sleep(seconds: delay)
                guard !Task.isCancelled else { return }
                self?.send()
            }
        }
    }

    private func isNewVisit(_ at: Date) -> Bool {
        guard let last = spacing.string(StorageKeys.appOpenActivity).flatMap(Int64.init) else { return true }
        return Double(epochMs(at) - last) / 1000 >= sessionTimeout
    }

    private func remove(_ open: Pending) {
        modify { pending in
            if let index = pending.firstIndex(of: open) { pending.remove(at: index) }
        }
    }

    /// Reads and changes the waiting opens under the one lock, writing only if they changed.
    @discardableResult
    private func modify<Result>(_ body: (inout [Pending]) -> Result) -> Result {
        state.withLock { state in
            let before = state.pending ?? store.json([Pending].self, key) ?? []
            var list = before
            let result = body(&list)
            state.pending = list
            if list != before { store.setJSON(list.isEmpty ? nil : list, for: key) }
            return result
        }
    }
}
