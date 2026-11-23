import Foundation

/// What the OS says about notifications for this app.
enum PushAuthorization: Sendable, Equatable {
    /// Allowed, including provisional and ephemeral authorization.
    case authorized
    case denied
    case notDetermined
}

/// The OS's side of push, so the registrar can be tested without UIKit.
protocol PushPlatform: Sendable {
    var isSupported: Bool { get }
    func authorization() async -> PushAuthorization
    /// Shows the prompt. True if the user allowed notifications.
    func requestAuthorization() async throws -> Bool
    /// Asks iOS for the APNs token, which arrives through ``PushTokens``.
    func registerForRemoteNotifications() async
    /// What Firebase registers this device as, for a push app that sends through Firebase:
    /// its registration token, or its installation id when the app is in Firebase's
    /// installation-id mode. Nil when the app doesn't include FirebaseMessaging, or Firebase
    /// has neither yet.
    func firebaseTarget() async -> PushTarget?
}

/// What a device registers as for push: a token or id, and its kind (`targetKind`).
struct PushTarget: Equatable, Sendable {
    var kind: String
    var token: String
}

/// The APNs device token, as iOS hands it to the app delegate. Process-wide, since iOS
/// gives one token per app, whichever Kirora client asks.
final class PushTokens: @unchecked Sendable {
    static let shared = PushTokens()

    private struct State {
        var latest: String?
        var waiting: [UUID: CheckedContinuation<String?, Never>] = [:]
        var observers: [UUID: @Sendable () -> Void] = [:]
    }

    private let state = Locked(State())

    /// The token iOS gave in this run of the app, if it has.
    var latest: String? { state.withLock { $0.latest } }

    func received(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let (waiting, observers, changed) = state.withLock { state in
            let changed = state.latest != token
            state.latest = token
            defer { state.waiting = [:] }
            return (Array(state.waiting.values), Array(state.observers.values), changed)
        }
        waiting.forEach { $0.resume(returning: token) }
        if changed { observers.forEach { $0() } }
    }

    /// Firebase made a new registration token.
    func firebaseTokenChanged() {
        let observers = state.withLock { Array($0.observers.values) }
        observers.forEach { $0() }
    }

    func failed() {
        let waiting = state.withLock { state -> [CheckedContinuation<String?, Never>] in
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        waiting.forEach { $0.resume(returning: nil) }
    }

    /// The token, waiting up to `timeout` for iOS to give it.
    func token(timeout: Double) async -> String? {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> String?? in
                if let latest = state.latest { return .some(latest) }
                state.waiting[id] = continuation
                return .none
            }
            if case .some(let token) = ready { continuation.resume(returning: token); return }
            Task {
                await sleep(seconds: timeout)
                let expired = self.state.withLock { $0.waiting.removeValue(forKey: id) }
                expired?.resume(returning: nil)
            }
        }
    }

    /// Calls `observer` when iOS gives a new token. Returns what stops it.
    func observe(_ observer: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id = UUID()
        state.withLock { $0.observers[id] = observer }
        return { [weak self] in self?.state.withLock { _ = $0.observers.removeValue(forKey: id) } }
    }

}

/// What this device was last registered for push as. `config` says what it was made for,
/// so a change of push app option or device id registers again. Device details (language,
/// time zone, versions) go with every registration and refresh, but don't cause one: the
/// interface repeats a registration only for a new user, token or day.
struct PushRegistrationRecord: Codable, Equatable {
    var userSubject: String
    var config: String
    var token: String
    /// `apns_token` or `fcm_token`, as Kirora said for the push app, or
    /// `firebase_installation_id` for an `fcm_token` app in Firebase's installation-id mode.
    var targetKind: String
    var pushAppId: String
    /// `granted`, or `denied` once a revoked permission was reported.
    var permission: String
    /// From Kirora's answer to the last successful `PUT /devices`: a denial report and a
    /// detachment name it.
    var lastSeenAt: String?
    /// When (epoch ms) it was registered.
    var at: Int64
    /// The device id it was registered as: what a detachment names, even if the id was
    /// since forgotten.
    var installationId: String
    /// A detachment of this registration was started and Kirora hasn't confirmed it. The
    /// record is kept, so the device id is too (Kirora may still have the device), but it no
    /// longer counts as registered: the user signing in again registers again.
    var detaching = false
    /// When (epoch ms, device clock) the detachment began: one still pending after a
    /// restart is retried until a day after it. Cleared once it's refused for good or given
    /// up on, so it isn't resumed.
    var detachingSince: Int64?
    /// A detachment to carry on at the next launch: begun, and neither refused nor given up.
    var isResumable: Bool { detaching && detachingSince != nil }
    /// The installation's secret this registration was sent with, to detach it with no user
    /// token held: a sign-out after a relaunch, before `identify()`, or a detachment retried
    /// after one.
    var deviceSecret: String
}

/// Re-register at most daily for the same user, token and configuration.
private let registrationRefresh: Double = 24 * 60 * 60
let apnsTokenKind = "apns_token"
let fcmTokenKind = "fcm_token"
let firebaseInstallationIdKind = "firebase_installation_id"

/// How long to wait for iOS to give the APNs token.
private let tokenWait: Double = 10
/// A detachment Kirora couldn't take is retried for this long at most: tokens last a day.
private let detachRetryLimit: Double = 24 * 60 * 60

/// Detaching a signed-out user's device (or one turned off with `setPushEnabled(false)`),
/// retried in the background until it's done. It goes with the user's token, kept in memory
/// only, while there is one; otherwise, or once Kirora refuses it, with the registration's
/// device secret, which the saved record keeps, so it's resumed after a restart.
///
/// Every attempt names the `lastSeenAt` of the registration it undoes, so Kirora keeps any
/// registration made since (answering 409): a late retry can't undo a newer sign-in, whoever
/// made it. Kirora's answer, not local bookkeeping, decides when it's done.
private final class Cleanup: @unchecked Sendable {
    /// Whose registration it undoes: the record's `userSubject`.
    let subject: String
    /// The signed-out user, while their token can be used: nil with none held (a sign-out
    /// after a relaunch, a resumed detachment), or once Kirora refused it. Guarded by
    /// `cleanups`' lock.
    var user: SignedInUser?
    let deviceSecret: String
    let installationId: String
    /// The `lastSeenAt` of the registration being undone; nil makes the detach unconditional.
    /// Kirora answers every registration with one, so it's nil only if an answer lacked it.
    /// The device's own registration time isn't used instead: with its clock behind
    /// Kirora's, the detach would be refused (409) and the signed-out user's pushes would
    /// keep arriving.
    let lastSeenAt: String?
    let giveUpAt: Date
    var backoff: Backoff
    var retry: Task<Void, Never>?
    /// Kirora's `Retry-After`, if it gave one: nothing goes before it, even when the app's
    /// lifecycle waives the SDK's own backoff. Guarded by `cleanups`' lock, as `retry` is.
    var serverNotBefore = Date.distantPast

    init(
        subject: String, user: SignedInUser?, deviceSecret: String, installationId: String,
        lastSeenAt: String?, since: Date, timing: DeliveryTiming
    ) {
        self.subject = subject
        self.user = user
        self.deviceSecret = deviceSecret
        self.installationId = installationId
        self.lastSeenAt = lastSeenAt
        giveUpAt = since.addingTimeInterval(detachRetryLimit)
        backoff = Backoff(timing)
    }
}

/// Permission prompt and device registration with Kirora.
final class PushRegistrar: @unchecked Sendable {
    private let api: ClientAPI
    private let identity: Identity
    private let store: KeyValueStore
    private let options: KiroraPushOptions?
    private let deviceId: DeviceId
    private let deviceInfo: DeviceInfo
    private let platform: PushPlatform
    private let tokens: PushTokens
    private let log: Log
    private let now: @Sendable () -> Date
    private let recordKey: String
    /// The registration or detachment running now. Each waits for the one before, so
    /// Kirora hears them in order and the last asked for is the one it keeps.
    private let turns = InTurn()
    /// Detachments not yet done. `stopped` is for good, at `destroy()`.
    private let cleanups = Locked<(pending: [ObjectIdentifier: Cleanup], stopped: Bool)>(([:], false))
    /// Detach retry timing, as events retry.
    private let timing: DeliveryTiming
    /// Called once the device is no longer registered with Kirora, nor waiting to be
    /// detached: the device id may then go, if consent was refused.
    private let onDetached: @Sendable () -> Void
    /// The record as last saved, read once.
    private let cachedRecord = Locked<PushRegistrationRecord??>(nil)
    /// A detachment began in this run: one found pending at launch is then this run's, not
    /// one left from the last.
    private let detachedThisRun = Locked(false)
    /// The user whose latest registration failed, for ``status()``.
    private let failedFor = Locked<SignedInUser?>(nil)

    init(
        api: ClientAPI, identity: Identity, store: KeyValueStore, options: KiroraPushOptions?,
        deviceId: DeviceId, deviceInfo: DeviceInfo, platform: PushPlatform, tokens: PushTokens,
        log: Log, timing: DeliveryTiming, now: @escaping @Sendable () -> Date,
        onDetached: @escaping @Sendable () -> Void = {}
    ) {
        self.timing = timing
        self.onDetached = onDetached
        self.api = api
        self.identity = identity
        self.store = store
        self.options = options
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo
        self.platform = platform
        self.tokens = tokens
        self.log = log
        self.now = now
        recordKey = StorageKeys.pushRegistration(api.namespace)
    }

    var enabled: Bool { options != nil && platform.isSupported }

    /// Whether Kirora may have this device registered, so its id must be kept to detach it:
    /// registered, being registered, or being detached (a record is kept until Kirora
    /// confirms a detachment).
    var registered: Bool {
        // `registering` first: a registration saves its record before it stops counting.
        registering.current > 0 || record != nil || cleanups.withLock { !$0.pending.isEmpty }
    }
    /// Registrations whose `PUT /devices` is under way, not yet saved.
    private let registering = Locked(0)

    /// The push app `user` is registered with, for app opens, while permission stands.
    func pushAppId(for user: SignedInUser) -> String? {
        record.flatMap { isLive($0, for: user) ? $0.pushAppId : nil }
    }

    /// Whether `record` is a standing registration of `user`'s: theirs, with permission,
    /// not being detached.
    private func isLive(_ record: PushRegistrationRecord, for user: SignedInUser) -> Bool {
        record.userSubject == user.subject && record.permission == "granted" && !record.detaching
    }

    /// The registration of the user signed in now, as it stands on this device: push on, not
    /// failed, for this device id and push app. What ``status()`` and ``registeredToken``
    /// both answer from. Makes no device id: a read makes nothing.
    private var currentRegistration: PushRegistrationRecord? {
        guard enabled, let user = identity.user, !isDisabled, failedFor.current !== user,
              let record, isLive(record, for: user),
              let deviceId = deviceId.existing, record.config == config(deviceId: deviceId)
        else { return nil }
        return record
    }

    func requestPermission() async -> PushPermission {
        guard enabled else { return .unsupported }
        let allowed: Bool
        do {
            allowed = try await platform.requestAuthorization()
        } catch {
            log.error("Couldn't ask for notification permission", error)
            return .unsupported
        }
        if allowed {
            // Saying yes to the prompt is turning push on.
            store.set(nil, for: StorageKeys.pushDisabled)
            do { try await register() } catch { log.error("Push registration failed", error) }
            return .granted
        }
        // iOS answers false both when the user says no and when they were never asked.
        switch await platform.authorization() {
        case .authorized: return .granted
        case .denied: return .denied
        case .notDetermined: return .unanswered
        }
    }

    /// The token this device is registered with for the user signed in now, while it is. Nil
    /// before sign-in, for another user's record (a restart before identify(), a switch whose
    /// registration failed), while off or being detached.
    var registeredToken: String? { currentRegistration?.token }

    /// This device's push, without prompting: the permission, then whether it's registered
    /// for the user signed in now. Waits for a registration under way.
    func status() async -> PushStatus {
        guard enabled else { return .unsupported }
        switch await platform.authorization() {
        case .denied: return .denied
        case .notDetermined: return .unanswered
        case .authorized: break
        }
        await turns.done()
        return currentRegistration != nil ? .enabled : .disabled
    }

    /// The device's own push choice, kept on the device for whoever signs in. Off detaches
    /// it from the user signed in now (retried as logout's is); on registers it again if
    /// permission is already granted, never prompting.
    func setEnabled(_ enabled: Bool) async {
        guard self.enabled else { return }
        if enabled {
            store.set(nil, for: StorageKeys.pushDisabled)
            do { try await register() } catch { log.error("Push registration failed", error) }
            return
        }
        store.set("1", for: StorageKeys.pushDisabled)
        await detach(as: identity.user)
    }

    private var isDisabled: Bool { store.string(StorageKeys.pushDisabled) != nil }

    /// As ``register()``, in the background, logging a failure: for a new token, the app
    /// coming back to the foreground (notifications turned off in Settings, a day-old
    /// registration), or the network coming back (a registration that failed offline).
    func registerInBackground() {
        guard identity.sendingUser != nil, enabled else { return }
        let log = self.log
        Task {
            do { try await self.register() } catch { log.error("Push registration failed", error) }
        }
    }

    /// Registers this device as the user signed in now, or reports that the user turned
    /// notifications off. Gives up as soon as someone else signs in. Not while the device's
    /// push is turned off with `setPushEnabled(false)`.
    func register() async throws {
        guard let user = identity.sendingUser, enabled, !isStopped else { return }
        // A registration that can't be saved could never be undone, and the saved one may
        // name another device id: wait until the device's storage can be read (after the
        // first unlock). The next sign-in or trip to the foreground registers.
        guard store.isReadable() else {
            log.debug("Push registration waits until the device's storage can be read")
            return
        }
        guard !isDisabled else { return }
        try await oneAtATime {
            do {
                try await self.register(as: user)
                self.failedFor.withLock { if $0 === user { $0 = nil } }
            } catch {
                self.failedFor.withLock { $0 = user }
                throw error
            }
        }
    }

    /// Detaches this device from `user` at sign-out, and never fails the app's sign-out:
    /// if Kirora can't be reached (offline, 429, 5xx), it keeps trying in the background,
    /// holding the user's token in memory only, for a day at most. It stops when Kirora
    /// answers (204: detached; 409: the user registered the device again since, which is
    /// kept; another 4xx: refused for good), or at `destroy()`. Another user signing in, or
    /// registering, doesn't stop it: the server scopes it to this user's registrations.
    ///
    /// Waits its turn behind registrations, then reads what to undo, so one still running
    /// at sign-out is detached too. The first attempt's request is cancelled at `deadline`,
    /// if given, and retried in the background like any other failure.
    ///
    /// Only `user`'s registration (someone else's is left alone). With `user` nil (nobody
    /// signed in: a sign-out after a relaunch, before `identify()`), the device's last
    /// registration, whoever's it is, by its device secret, the only way without the user's
    /// token; not that of whoever has signed in by the time it's read (an identify() during
    /// the logout). A token Kirora refused goes by the secret too.
    func detach(as user: SignedInUser?, deadline: Date? = nil) async {
        guard !isStopped else { return }
        try? await oneAtATime {
            guard !self.isStopped, var record = self.record else { return }
            // As `user`, only theirs; by the secret, not that of whoever is signed in now.
            let isTheirs = user.map { $0.subject == record.userSubject }
                ?? (record.userSubject != self.identity.user?.subject)
            guard isTheirs else { return }
            self.detachedThisRun.withLock { $0 = true }
            // No longer counts as registered; kept until Kirora confirms.
            if !record.detaching {
                record.detaching = true
                record.detachingSince = epochMs(Date())
                self.save(record)
            }
            await self.attemptInTurn(self.cleanup(of: record, as: user), deadline: deadline)
        }
    }

    /// A detachment left pending when the app last ended, retried with its device secret
    /// until a day after it began. At launch, once the device's storage can be read.
    func resumeDetachment() async {
        guard enabled, !isStopped, store.isReadable(), record?.isResumable == true else { return }
        try? await oneAtATime {
            guard !self.detachedThisRun.current, let record = self.record, record.isResumable else { return }
            let cleanup = self.cleanup(of: record, as: nil)
            guard Date() < cleanup.giveUpAt else {
                self.finish(cleanup, confirmed: false)
                return
            }
            await self.attemptInTurn(cleanup, deadline: nil)
        }
    }

    /// The detachment of `record`, as `user` (nil: by its secret). One already pending for
    /// it (setPushEnabled(false), then logout) is tried again now, rather than a second
    /// retry loop beside it.
    private func cleanup(of record: PushRegistrationRecord, as user: SignedInUser?) -> Cleanup {
        let since = record.detachingSince.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date()
        return cleanups.withLock { state -> Cleanup in
            if let existing = state.pending.values.first(where: {
                $0.subject == record.userSubject && $0.installationId == record.installationId
                    && $0.lastSeenAt == record.lastSeenAt
            }) {
                existing.retry?.cancel()
                existing.retry = nil
                return existing
            }
            let cleanup = Cleanup(
                subject: record.userSubject, user: user, deviceSecret: record.deviceSecret,
                installationId: record.installationId, lastSeenAt: record.lastSeenAt, since: since, timing: timing
            )
            state.pending[ObjectIdentifier(cleanup)] = cleanup
            return cleanup
        }
    }

    /// Stops for good, at `destroy()`: no registration, detachment or retry starts after.
    func stop() {
        let stopped = cleanups.withLock { state -> [Cleanup] in
            state.stopped = true
            defer { state.pending = [:] }
            return Array(state.pending.values)
        }
        stopped.forEach { $0.retry?.cancel() }
    }

    private var isStopped: Bool { cleanups.withLock { $0.stopped } }

    /// Detachments still being retried, for tests.
    var pendingDetachments: Int { cleanups.withLock { $0.pending.count } }

    private func isPending(_ cleanup: Cleanup) -> Bool {
        cleanups.withLock { !$0.stopped && $0.pending[ObjectIdentifier(cleanup)] != nil }
    }

    /// Tries every detachment still waiting at once, rather than at the SDK's own backoff:
    /// as the app goes to the background (with time from iOS, as a suspended app retries
    /// nothing) and comes back. One Kirora asked to wait (`Retry-After`) keeps its scheduled
    /// retry. Returns once each has been tried.
    func retryDetachmentsNow() async {
        let now = Date()
        let waiting = cleanups.withLock { state -> [Cleanup] in
            guard !state.stopped else { return [] }
            return state.pending.values.filter { $0.serverNotBefore <= now }.map { cleanup in
                cleanup.retry?.cancel()
                cleanup.retry = nil
                return cleanup
            }
        }
        for cleanup in waiting { await retry(cleanup) }
    }

    /// A retry of `cleanup`, in turn with registrations.
    private func retry(_ cleanup: Cleanup) async {
        try? await oneAtATime { await self.attemptInTurn(cleanup, deadline: nil) }
    }

    /// One attempt at `cleanup`. Runs in its turn.
    private func attemptInTurn(_ cleanup: Cleanup, deadline: Date?) async {
        guard isPending(cleanup) else { return }
        let query = cleanup.lastSeenAt.map { [URLQueryItem(name: "lastSeenAt", value: $0)] } ?? []
        let api = self.api, path = "/devices/\(cleanup.installationId)"
        let user = cleanups.withLock { _ in cleanup.user }
        let delete: @Sendable () async throws -> JSONValue? = {
            if let user {
                // The captured token, never refreshed (the next user's callback may answer).
                return try await api.request("DELETE", path, query: query, as: user, refreshing: false)
            }
            return try await api.request("DELETE", path, query: query, deviceSecret: cleanup.deviceSecret)
        }
        do {
            // Past the deadline (waiting behind a registration), it goes without one.
            if let remaining = deadline?.timeIntervalSinceNow, remaining > 0 {
                _ = try await withTimeout(seconds: remaining, delete)
            } else {
                _ = try await delete()
            }
            log.debug("Detached this device from the user's pushes")
            finish(cleanup, confirmed: true)
        } catch let error as KiroraApiError where error.status == 409 {
            // The user registered the device again since: Kirora keeps that registration.
            log.debug("Detached the user's older registrations; a newer one is kept")
            finish(cleanup, confirmed: true)
        } catch let error as KiroraApiError where error.status == 401 && user != nil {
            // The token expired, say: the device secret goes on from here, at once.
            log.debug("Detaching with the device's secret: Kirora refused the user's token")
            cleanups.withLock { _ in cleanup.user = nil }
            await attemptInTurn(cleanup, deadline: deadline)
        } catch let error as KiroraApiError where !error.isRetryable {
            // Refused for good (e.g. the token, with no fresh one to be had). Kirora may
            // still have the device, so its record, and id, are kept.
            log.error("Couldn't detach this device from the user's pushes", error)
            finish(cleanup, confirmed: false)
        } catch {
            scheduleRetry(cleanup, after: error)
        }
    }

    private func scheduleRetry(_ cleanup: Cleanup, after error: Error) {
        let retryAt = cleanup.backoff.failed(error)
        guard retryAt < cleanup.giveUpAt else {
            log.error("Gave up detaching this device from the signed-out user's pushes", error)
            finish(cleanup, confirmed: false)
            return
        }
        log.error("Couldn't detach this device yet; retrying in the background", error)
        let serverNotBefore = cleanup.backoff.notBefore(waivingOwnDelay: true)
        cleanups.withLock { state in
            guard !state.stopped, state.pending[ObjectIdentifier(cleanup)] != nil else { return }
            cleanup.serverNotBefore = serverNotBefore
            // One retry loop per detachment: an attempt started meanwhile (the app going to
            // the background) replaces the one waiting, never runs beside it.
            cleanup.retry?.cancel()
            cleanup.retry = Task { [weak self] in
                await sleep(seconds: retryAt.timeIntervalSinceNow)
                guard !Task.isCancelled, let self else { return }
                await self.retry(cleanup)
            }
        }
    }

    /// `cleanup` needs nothing more. If Kirora `confirmed` it, the record it undid goes,
    /// unless the device was registered again since; then the device id may go too.
    private func finish(_ cleanup: Cleanup, confirmed: Bool) {
        cleanups.withLock { state in
            state.pending[ObjectIdentifier(cleanup)] = nil
            cleanup.retry?.cancel()
        }
        if var record, record.detaching, record.userSubject == cleanup.subject,
           record.lastSeenAt == cleanup.lastSeenAt {
            if confirmed {
                save(nil)
            } else if record.detachingSince != nil {
                // Refused for good, or given up on: not resumed at the next launch either.
                record.detachingSince = nil
                save(record)
            }
        }
        if !registered { onDetached() }
    }

    private func register(as user: SignedInUser) async throws {
        // Not for a user signing out: their detachment may already have run.
        let current = { self.identity.capturingUser === user }
        guard current() else { return }
        // Counted as registered throughout, so a tracking refusal meanwhile keeps the device
        // id this registration uses, from its configuration to the record it saves.
        registering.withLock { $0 += 1 }
        defer { registering.withLock { $0 -= 1 } }
        switch await platform.authorization() {
        case .notDetermined:
            return
        case .denied:
            try await reportDenied(as: user)
            return
        case .authorized:
            break
        }
        // Firebase needs the APNs token too, to make its own. Asked for once a run: a token
        // iOS changes later arrives through `PushTokens` and registers again.
        if tokens.latest == nil { await platform.registerForRemoteNotifications() }
        let apnsToken: String?
        if let fresh = await tokens.token(timeout: tokenWait) {
            apnsToken = fresh
            store.set(fresh, for: StorageKeys.apnsToken)
        } else {
            // iOS is slow to answer; last launch's token is almost always still right.
            apnsToken = store.string(StorageKeys.apnsToken)
        }
        let installationId = deviceId.value()
        let config = self.config(deviceId: installationId)
        // A signed-in start costs no push calls: the kind of token comes from the last
        // registration while it's fresh, and from Kirora otherwise.
        if let record, isFresh(record, user: user, config: config) {
            let target = await self.target(for: record.targetKind, apnsToken: apnsToken)
            if target == PushTarget(kind: record.targetKind, token: record.token) || !current() { return }
        }
        guard current(), let pushApp = try await choosePushApp(as: user), current() else { return }
        guard let target = await self.target(for: pushApp.targetKind, apnsToken: apnsToken) else {
            log.error(pushApp.targetKind == fcmTokenKind
                ? "This push app sends through Firebase, but Firebase gave no token or installation id. Add FirebaseMessaging and configure Firebase"
                : "iOS gave no APNs token. Is the Push Notifications capability on?")
            return
        }
        let deviceSecret = deviceId.secret()
        var body = deviceInfo.registrationDetails()
        body["deviceSecret"] = .string(deviceSecret)
        body["pushAppId"] = .string(pushApp.pushAppId)
        body["targetKind"] = .string(target.kind)
        body["permission"] = .string("granted")
        body["target"] = .string(target.token)
        let answer = try await api.request("PUT", "/devices/\(installationId)", body: JSONValue.object(body), as: user)
        // Saved even if the user changed meanwhile: it records who Kirora now has, so the
        // next user's registration (queued behind this one) isn't skipped as fresh.
        save(PushRegistrationRecord(
            userSubject: user.subject, config: config, token: target.token, targetKind: target.kind,
            pushAppId: pushApp.pushAppId, permission: "granted",
            lastSeenAt: answer?["lastSeenAt"]?.stringValue, at: epochMs(now()), installationId: installationId,
            deviceSecret: deviceSecret
        ))
        log.debug("Registered this device for push")
    }

    /// What to register as for a push app taking `kind`: the APNs token, or Firebase's.
    private func target(for kind: String, apnsToken: String?) async -> PushTarget? {
        kind == apnsTokenKind ? apnsToken.map { PushTarget(kind: apnsTokenKind, token: $0) } : await platform.firebaseTarget()
    }

    /// Notifications are off: tell Kirora, so it stops sending, naming the registration it
    /// saw last so a stale report can't undo a newer one. Sent when the user turned them off
    /// in Settings, and when a different user signs in on a device registered for someone
    /// else: the report moves the device to them, so it stops taking the earlier user's
    /// pushes.
    private func reportDenied(as user: SignedInUser) async throws {
        guard var record, record.userSubject != user.subject || record.permission == "granted" else { return }
        let deviceSecret = deviceId.secret()
        var body = deviceInfo.registrationDetails()
        body["deviceSecret"] = .string(deviceSecret)
        body["pushAppId"] = .string(record.pushAppId)
        body["permission"] = .string("denied")
        body["lastSeenAt"] = .string(record.lastSeenAt ?? isoTimestamp(Date(timeIntervalSince1970: Double(record.at) / 1000)))
        do {
            let answer = try await api.request("PUT", "/devices/\(record.installationId)", body: JSONValue.object(body), as: user)
            record.lastSeenAt = answer?["lastSeenAt"]?.stringValue ?? record.lastSeenAt
        } catch let error as KiroraApiError where error.status == 409 || error.status == 404 {
            // 409: Kirora has a registration newer than the one the SDK last saw, and this
            // was already the latest `lastSeenAt` it has, so sending again would only be
            // refused again; that registration decides. 404: the device was never
            // registered in this push app, so there's nothing to turn off.
            log.debug("Denial not reported: Kirora answered \(error.status)")
        }
        record.deviceSecret = deviceSecret
        record.userSubject = user.subject
        record.permission = "denied"
        record.detaching = false
        record.detachingSince = nil
        record.at = epochMs(now())
        save(record)
    }

    /// Asks Kirora which push app to use. Nil, logged, if none is set up.
    private func choosePushApp(as user: SignedInUser) async throws -> (pushAppId: String, targetKind: String)? {
        var query = [URLQueryItem(name: "platform", value: "ios")]
        if let pushAppId = options?.pushAppId { query.append(URLQueryItem(name: "pushAppId", value: pushAppId)) }
        do {
            let answer = try await api.request("GET", "/push-app", query: query, as: user)
            guard let pushAppId = answer?["pushAppId"]?.stringValue else {
                log.error("Kirora's push app answer had no pushAppId")
                return nil
            }
            // Servers from before Firebase was supported on iOS only took APNs tokens.
            let targetKind = answer?["targetKind"]?.stringValue ?? apnsTokenKind
            guard targetKind == apnsTokenKind || targetKind == fcmTokenKind else {
                log.error("This push app takes \(targetKind) tokens, which iOS can't give")
                return nil
            }
            return (pushAppId, targetKind)
        } catch let error as KiroraApiError where error.status == 404 {
            log.error("No ready iOS push app in this workspace")
            return nil
        }
    }

    /// Registered for this user and configuration in the last day, with permission.
    private func isFresh(_ record: PushRegistrationRecord, user: SignedInUser, config: String) -> Bool {
        let age = Double(epochMs(now()) - record.at) / 1000
        return age >= 0 && age < registrationRefresh && record.config == config && isLive(record, for: user)
    }

    private func config(deviceId: String? = nil) -> String {
        "\(options?.pushAppId ?? "")|\(deviceId ?? self.deviceId.value())"
    }

    private var record: PushRegistrationRecord? {
        cachedRecord.withLock { cached in
            if cached == nil { cached = .some(store.json(PushRegistrationRecord.self, recordKey)) }
            return cached ?? nil
        }
    }

    private func save(_ record: PushRegistrationRecord?) {
        cachedRecord.withLock { cached in
            cached = .some(record)
            store.setJSON(record, for: recordKey)
        }
    }

    private func oneAtATime(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        try await turns.run(operation)
    }
}
