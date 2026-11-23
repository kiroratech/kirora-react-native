import Foundation

/// The Kirora client. Create one for the whole app, as early as possible: in
/// `application(_:didFinishLaunchingWithOptions:)`, or your SwiftUI `App`'s `init`.
///
/// Nothing is sent until ``identify(_:)``: events tracked before that wait on the device and
/// go as the user who signs in. A failing Kirora never throws from ``track(_:properties:)``
/// and never breaks the app.
///
/// ```swift
/// let kirora = Kirora(options: KiroraOptions(
///     clientKey: "kirora_pk_…",
///     fetchUserToken: { try await MyServer.kiroraToken() },
///     push: .enabled
/// ))
/// try await kirora.identify()
/// kirora.track("Order Completed", properties: ["order_id": "1042", "total": 46.5])
/// ```
public final class Kirora: @unchecked Sendable {
    private let options: KiroraOptions
    private let log: Log
    private let identity: Identity
    private let api: ClientAPI
    private let store: KeyValueStore
    private let queue: EventQueue
    private let consent: TrackingConsent
    private let deviceId: DeviceId
    private let tracker: Tracker
    private let delivery: EventDelivery
    /// Internal, for tests.
    let push: PushRegistrar
    private let appOpens: AppOpens
    private let lifecycle: AppLifecycleSource
    private let lifecycleEvents: LifecycleEvents
    private let releaseDeviceId: DeviceIdRelease
    private let now: @Sendable () -> Date
    private let logoutWait: Double
    private let destroyedFlag = Locked(false)
    private let stopObservingTokens: @Sendable () -> Void
    /// The events a sign-in adopted, given back if Kirora refuses its token before ever
    /// accepting it.
    private let adoption = Locked<(user: SignedInUser, keys: Set<String>)?>(nil)
    /// Logouts, one after another.
    private let logouts = InTurn()

    /// Starts the client. Never throws and never blocks the app's launch: a bad option is
    /// logged, and the client then sends nothing.
    public convenience init(options: KiroraOptions) {
        self.init(options: options, environment: .live(log: Log(level: options.logLevel)))
    }

    init(options: KiroraOptions, environment: KiroraEnvironment) {
        self.options = options
        let log = Log(level: options.logLevel)
        self.log = log
        now = environment.now
        logoutWait = environment.logoutWait
        if !options.clientKey.hasPrefix("kirora_pk_") {
            log.error("clientKey should be your client key, kirora_pk_…")
        }
        identity = Identity(
            fetchUserToken: options.fetchUserToken, tokenTimeout: environment.tokenTimeout,
            onAuthenticationFailed: options.onAuthenticationFailed, now: environment.now
        )
        api = ClientAPI(
            clientKey: options.clientKey, apiUrl: options.apiUrl,
            identity: identity, transport: environment.transport
        )
        if let problem = api.urlProblem { log.error(problem) }
        if let apiUrl = api.apiUrl {
            useApiUrlForReports(apiUrl)
            // For a tap that launches the app before the next launch's client exists. Only
            // with push: without it, nothing is stored before consent. Off the app's thread,
            // as it may read the file.
            if options.push != nil {
                let store = environment.store
                DispatchQueue.global(qos: .utility).async { store.set(apiUrl.absoluteString, for: StorageKeys.apiUrl) }
            }
        }
        store = WorkspaceStore(base: environment.store, namespace: api.namespace)
        queue = EventQueue.shared(file: environment.eventsFile(api.namespace), log: log)
        consent = TrackingConsent(
            store: store, refusals: WorkspaceStore(base: environment.refusals, namespace: api.namespace),
            required: options.requireTrackingConsent, log: log
        )
        deviceId = DeviceId(store: store)
        let delivery = EventDelivery(
            api: api, identity: identity, queue: queue,
            consentAllowed: { [consent] in consent.allowed },
            log: log, timing: environment.timing, now: environment.now
        )
        self.delivery = delivery
        tracker = Tracker(
            identity: identity, queue: queue, consent: consent,
            sessions: Sessions(store: store, now: environment.now),
            deviceId: deviceId, deviceInfo: environment.deviceInfo,
            trackSessions: options.trackSessions, beforeSend: options.beforeSend, log: log, now: environment.now,
            onQueued: { waiting in Task { await delivery.onEventQueued(waiting: waiting) } }
        )
        let releaseDeviceId = DeviceIdRelease(consent: consent, deviceId: deviceId)
        push = PushRegistrar(
            api: api, identity: identity, store: store, options: options.push,
            deviceId: deviceId, deviceInfo: environment.deviceInfo,
            platform: environment.pushPlatform, tokens: environment.tokens,
            log: log, timing: environment.timing, now: environment.now,
            // Kept past a consent withdrawal only so the device could be detached.
            onDetached: { releaseDeviceId.ifUnneeded(registered: false) }
        )
        self.releaseDeviceId = releaseDeviceId
        appOpens = AppOpens(
            api: api, identity: identity, store: store, registrar: push, deviceId: deviceId,
            consent: consent, log: log, timing: environment.timing,
            trackSessions: options.trackSessions, now: environment.now
        )
        lifecycle = environment.lifecycle
        lifecycleEvents = LifecycleEvents(store: store, deviceInfo: environment.deviceInfo)
        // A sign-in Kirora never accepted gives back the events it adopted.
        let queue = self.queue, adoption = self.adoption
        api.onTokenRefused.withLock { hook in
            hook = { user in
                guard !user.confirmed,
                      let adopted = adoption.withLock({ current -> Set<String>? in
                          guard current?.user === user else { return nil }
                          defer { current = nil }
                          return current?.keys
                      })
                else { return }
                queue.release(adopted, owner: user.subject)
            }
        }

        // A new APNs or Firebase token while signed in registers again.
        let push = self.push
        let stopObserving: @Sendable () -> Void = { }
        stopObservingTokens = push.enabled ? environment.tokens.observe { push.registerInBackground() } : stopObserving
        // What's stored from before the user refused, e.g. before consent was required. Off
        // the app's thread, as it reads the disk; nothing is tracked meanwhile, as tracking
        // checks the same answer.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.tracker.forget(if: { self.consent.refused }) {
                self.appOpens.forget()
                self.releaseDeviceId.ifUnneeded(registered: self.push.registered)
            }
            // A detachment the app ended before Kirora confirmed.
            let push = self.push
            Task { await push.resumeDetachment() }
        }
        if push.enabled { environment.installPushIntegration(log) }
        deepLinkHandler.withLock { $0 = options.handleDeepLink }
        lifecycle.start { [weak self] event in self?.handle(event) }
    }

    deinit {
        // Released without destroy(): its timers, observers and retries go too.
        destroy()
    }

    /// Signs the user in and starts sending their queued events. Call it at every start
    /// while they're signed in. Without a token, it asks `fetchUserToken` for one. If called
    /// again before a token arrives, the latest call wins.
    ///
    /// Also registers the device for push if the user allowed notifications.
    ///
    /// - Throws: A ``KiroraError``, for the token or the setup: ``UserTokenError`` if
    ///   `fetchUserToken` fails, ``KiroraApiError`` with status 401 if Kirora refuses a fresh
    ///   one too, and ``KiroraError`` itself with no token and no `fetchUserToken`, or an
    ///   `apiUrl` that isn't an address. A push registration that fails is logged.
    public func identify(_ userToken: String? = nil) async throws {
        guard !destroyed else { return }
        if let problem = api.urlProblem { throw KiroraError(problem) }
        do {
            try await identity.signIn(token: userToken) { [weak self] in try await self?.onSignedIn() }
        } catch {
            throw asKiroraError(error)
        }
    }

    /// Call before your own sign-out. Tries to send queued events, detaches this device from
    /// the user's pushes, then forgets the user and anything still unsent. Safe to call twice.
    ///
    /// Never fails your sign-out, and waits 5 seconds at most to send and detach: if Kirora
    /// can't be reached, the SDK keeps trying to detach the device in the background, and
    /// the user is forgotten all the same.
    public func logout() async {
        // One at a time, each after the last, with its own deadline: a logout's wait for a
        // sign-in is its own.
        try? await logouts.run { await self.logOut(by: Date().addingTimeInterval(self.logoutWait)) }
    }

    private func logOut(by deadline: Date) async {
        guard !destroyed else { return }
        let identity = self.identity
        // Events waiting for a sign-in may be the outgoing user's, signed in to the SDK or
        // not (an app that restored its own session): never the next user's. Held now, for
        // a sign-in already under way at most, so what's tracked during the logout, or a
        // later identify(), doesn't take them.
        // Nothing tracked from now on joins whoever is signed in, or whoever a sign-in under
        // way signs in: it waits for the next user. An identify() made during the logout
        // comes after it, and stays.
        let (current, signIn, call) = tracker.holdWaitingEvents(beginningLogout: identity.beginLogout)
        if let current { tracker.endSession(ownedBy: current.subject) }
        // Otherwise that sign-in's push registration could land after the detachment.
        let signInSettled = await finish(by: deadline) { _ = try? await signIn?.value }
        // Still waiting for its token: it never signs anyone in now, so it can't bring the
        // user back after this logout. Whoever is signed in is signed out as usual.
        if !signInSettled { identity.abandonSignIn(call) }
        let signedIn = identity.leavingUser
        // Dropped once a sign-in under way has had its chance to adopt them.
        tracker.releaseHeldEvents(forgettingOnlyOnSignedInVisits: signedIn == nil)
        guard let user = signedIn else {
            // Nobody signed in (the app restored its own session after a relaunch): the
            // device's last registration is still detached, by its device secret.
            let push = self.push
            _ = await finish(by: deadline) { await push.detach(as: nil, deadline: deadline) }
            return
        }
        // Past the deadline, the user is forgotten all the same, and a detachment still under
        // way carries on in the background, behind any registration it must follow.
        let delivery = self.delivery, push = self.push
        let finished = await finish(by: deadline) {
            // Independent: the detachment waits only for registrations, not for events.
            async let sent: Void = delivery.flush()
            await push.detach(as: user, deadline: deadline)
            await sent
        }
        // Out of time: a send still under way is cancelled (its events go with the user). The
        // detachment's own request is cancelled at the same deadline, then retried.
        if !finished { await delivery.cancel(sendingAs: user) }
        let signedOut = identity.signOut(user)
        // Anything left is this user's, so it never goes as the next one; but if they
        // signed in again meanwhile, it's theirs to send.
        let nowSignedIn = identity.user?.subject
        if nowSignedIn != user.subject {
            tracker.forgetEvents(ownedBy: user.subject)
            appOpens.clear(owner: user.subject)
            forgetPushConsent(unlessOf: nowSignedIn)
        }
        if signedOut { tracker.endSession(ownedBy: user.subject) }
        adoption.withLock { if $0?.user === user { $0 = nil } }
    }

    /// Runs `work` in a task of its own and waits for it until `deadline`; past it, the work
    /// carries on in the background. True if it finished in time.
    private func finish(by deadline: Date, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        let task = Task { await work() }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { return false }
        return (try? await withTimeout(seconds: remaining) { await task.value }) != nil
    }

    /// Queues an event, with a copy of `properties` as they are now. Returns at once and
    /// never throws: an event Kirora refuses is logged, and the rest still go through.
    ///
    /// Properties must be JSON: strings, finite numbers, booleans, `NSNull`, arrays and
    /// dictionaries of them. A `nil` member is left out; dates are sent as ISO 8601 strings,
    /// URLs and UUIDs as strings. An event holding anything else is dropped and logged.
    public func track(_ name: String, properties: [String: Any] = [:]) {
        guard !destroyed else { return }
        guard !name.isEmpty else {
            log.error("Not tracked: an event needs a name")
            return
        }
        let converted: [String: JSONValue]
        do {
            converted = try JSONValue.fromObject(properties)
        } catch {
            // The kind of problem only: properties may hold what the app keeps private.
            log.error("\(name) not tracked: its properties hold \(error)")
            return
        }
        tracker.track(name, properties: converted)
    }

    /// Tracks `Screen Viewed` with the screen's name, as your app calls it: `Checkout`.
    /// Screens are never tracked automatically.
    public func trackScreenView(_ name: String) {
        guard !destroyed else { return }
        tracker.track(screenViewedEvent, properties: ["name": .string(name)])
    }

    /// The user's answer, for ``KiroraOptions/requireTrackingConsent``. Remembered on the
    /// device. Withdrawing consent also forgets queued events, the visit, and the device id
    /// unless a push registration still needs it.
    public func setTrackingConsent(_ granted: Bool) {
        let newlyAllowed = consent.answer(granted)
        if !granted {
            tracker.forget()
            appOpens.forget()
            let delivery = self.delivery
            Task { await delivery.cancelIfDisallowed() }
            releaseDeviceId.ifUnneeded(registered: push.registered)
        }
        guard newlyAllowed, !destroyed else { return }
        // Catch up on the visit we skipped while waiting for consent, and send what waited.
        tracker.noteActivity()
        Task { await delivery.flush() }
    }

    /// Shows iOS's notification prompt, then registers the device if the user allows it.
    /// iOS shows the prompt once; after that this answers with the user's earlier choice.
    ///
    /// - Returns: ``PushPermission/unsupported`` when ``KiroraOptions/push`` is off.
    public func requestPushPermission() async -> PushPermission {
        await push.requestPermission()
    }

    /// This device's push, for an app's "notifications on/off" setting. Never prompts, and
    /// waits for a sign-in under way. The permission comes first (``PushStatus/denied``,
    /// ``PushStatus/unanswered``, ``PushStatus/unsupported``); with it granted,
    /// ``PushStatus/enabled`` when this device is registered for the signed-in user, and
    /// ``PushStatus/disabled`` otherwise: turned off, signed out, or the registration failed.
    public func getPushStatus() async -> PushStatus {
        await identity.settled()
        guard !destroyed else { return push.enabled ? .disabled : .unsupported }
        return await push.status()
    }

    /// This device's own push on/off, kept on the device for whoever signs in next too, as
    /// opposed to the user's marketing consent (``setPushConsent(_:)``). `false` detaches
    /// the device from the signed-in user's pushes (retried in the background as
    /// ``logout()``'s is), and while it holds, ``identify(_:)`` doesn't register the device.
    /// `true` registers it again if notifications are already allowed, never prompting; so
    /// does ``requestPushPermission()`` answered ``PushPermission/granted``. Never fails.
    public func setPushEnabled(_ enabled: Bool) async {
        guard !destroyed else { return }
        await identity.settled()
        await push.setEnabled(enabled)
    }

    /// Records the user's consent to marketing pushes, as your app asked them. The
    /// notification permission alone doesn't grant it.
    ///
    /// - Throws: A ``KiroraError`` when Kirora hasn't recorded the choice: ``KiroraApiError``
    ///   for its refusal or a server error, ``UserTokenError``, or ``KiroraError`` itself when
    ///   it couldn't be reached or nobody is signed in. Ask again later.
    public func setPushConsent(_ granted: Bool) async throws {
        await identity.settled()
        guard !destroyed else { return }
        let user = identity.user
        do {
            try await Identity.$callerHearsFailures.withValue(true) {
                try await api.request("PUT", "/push-consent", body: JSONValue.object(["granted": .bool(granted)]))
            }
        } catch {
            throw asKiroraError(error)
        }
        // The user's choice, for getState(): kept only while they're the one signed in.
        if let user, identity.user?.subject == user.subject {
            store.setJSON(RecordedPushConsent(user: user.subject, granted: granted), for: StorageKeys.pushConsent)
        }
    }

    /// The signed-in user's last recorded marketing push choice, or nil.
    private var recordedPushConsent: RecordedPushConsent? {
        guard let record = store.json(RecordedPushConsent.self, StorageKeys.pushConsent),
              record.user == identity.user?.subject
        else { return nil }
        return record
    }

    /// Forgets the recorded push choice unless it's `subject`'s.
    private func forgetPushConsent(unlessOf subject: String?) {
        guard let record = store.json(RecordedPushConsent.self, StorageKeys.pushConsent),
              record.user != subject
        else { return }
        store.set(nil, for: StorageKeys.pushConsent)
    }

    /// Whether tracking is allowed now: the user's answer to ``setTrackingConsent(_:)``, or
    /// the default for ``KiroraOptions/requireTrackingConsent`` without one. The same as
    /// `getState().trackingConsent`, without reading the rest of the state (the event queue
    /// included). Never prompts or fails.
    public var trackingConsent: Bool { consent.allowed }

    /// A snapshot of the client, for your app's support and debug screens. Read-only and
    /// never sent anywhere: it never prompts, makes no network call and never fails.
    public func getState() -> KiroraState {
        KiroraState(
            isInitialized: !destroyed,
            isIdentified: identity.user != nil,
            deviceId: deviceId.existing,
            sessionId: tracker.currentSessionId,
            pushToken: push.registeredToken,
            trackingConsent: consent.allowed,
            pushConsent: recordedPushConsent?.granted ?? false,
            queuedEventCount: queue.count
        )
    }

    /// Sends queued events now; rarely needed. Returning doesn't mean all were accepted:
    /// after a network or server failure they wait for a retry.
    public func flush() async {
        await delivery.flush()
        appOpens.send()
    }

    /// Stops this client's timers and observers at once, without sending or deleting
    /// anything: for tests, or replacing the client. A destroyed client tracks and sends
    /// nothing; events still waiting stay on the device for the next client.
    public func destroy() {
        guard destroyedFlag.claimOnce() else { return }
        // Forgetting the user stops work already under way for them at its next step.
        identity.end()
        lifecycle.stop()
        appOpens.destroy()
        push.stop()
        stopObservingTokens()
        let delivery = self.delivery
        Task { await delivery.destroy() }
        // Nothing to wait for: the next client reads the files on the same queues, after
        // this one's writes.
    }

    // MARK: - Internals

    private var destroyed: Bool { destroyedFlag.current }


    /// Once signed in: send what waits, and register this device for push.
    private func onSignedIn() async throws {
        let user = identity.user
        // Leaving: signed in by a sign-in under way as a logout began, which signs them out.
        var leaving = false
        // What was tracked before sign-in is this user's from now on, whoever signs in next,
        // unless Kirora refuses their token before accepting it once.
        if let user {
            // A choice recorded for someone else isn't this user's.
            forgetPushConsent(unlessOf: user.subject)
            let keys: Set<String>
            (keys, leaving) = tracker.adoptWaitingEvents(as: user)
            adoption.withLock { $0 = keys.isEmpty || user.confirmed ? nil : (user, keys) }
        }
        // Events left by earlier sign-ins with tokens naming no one: they'd otherwise wait for
        // good. Only once they're old, as another client may still be signed in to send them.
        let staleBefore = now().addingTimeInterval(-24 * 60 * 60)
        queue.clearOwned { owner, event in
            owner != user?.subject && isUnnamedSubject(owner)
                && (parseIsoTimestamp(event.occurredAt) ?? .distantPast) < staleBefore
        }
        let delivery = self.delivery
        Task { await delivery.flush() }
        do {
            // identify() throws a token failure here itself.
            try await Identity.$callerHearsFailures.withValue(true) { try await push.register() }
        } catch where (error as? KiroraApiError)?.status == 401 || error is UserTokenError {
            throw error
        } catch {
            log.error("Push registration failed", error)
        }
        if let user, !leaving { appOpens.onSignedIn(user) }
    }

    private func handle(_ event: LifecycleEvent) {
        guard !destroyed else { return }
        switch event {
        case .launched:
            tracker.noteActivity()
            if options.trackAppLifecycle { tracker.trackAll(lifecycleEvents.launch) }
            appOpens.appCameToForeground()
        case .foreground:
            identity.appCameToForeground()
            tracker.noteActivity()
            if options.trackAppLifecycle {
                let (name, properties) = lifecycleEvents.opened(fromBackground: true)
                tracker.track(name, properties: properties)
            }
            appOpens.appCameToForeground()
            // Notices notifications turned off in Settings, and refreshes a day-old registration.
            push.registerInBackground()
            // A signed-out user's device still to detach: tried now, not at its backoff.
            let push = self.push
            Task { await push.retryDetachmentsNow() }
        case .background:
            if options.trackAppLifecycle { tracker.track(applicationBackgroundedEvent, properties: [:]) }
            tracker.keepSessionAlive(writeNow: true)
            appOpens.appWentToBackground()
            // The last chance to send, and to detach a signed-out user's device, before iOS
            // suspends the app: nothing retries while it's suspended.
            let delivery = self.delivery, push = self.push, queue = self.queue
            lifecycle.runInBackground("Kirora flush") {
                async let detached: Void = push.retryDetachmentsNow()
                await delivery.flush()
                await detached
                // The one file whose writes are spaced out.
                await queue.writesDone()
            }
        case .keepAlive:
            tracker.keepSessionAlive()
            appOpens.touchVisit()
        case .online:
            Task { await self.flush() }
            // Retries a push registration that failed offline.
            push.registerInBackground()
        }
    }

}

/// The rule for `device.id`: it goes once tracking consent is refused, unless a push
/// registration still needs it (it's also the installation id). Checked whenever either
/// changes: at a refusal, and when the device is detached.
struct DeviceIdRelease: Sendable {
    let consent: TrackingConsent
    let deviceId: DeviceId

    func ifUnneeded(registered: Bool) {
        if consent.refused, !registered { deviceId.remove() }
    }
}

/// What the client runs on: the device in the app, fakes in tests.
struct KiroraEnvironment {
    var transport: HTTPTransport
    var store: KeyValueStore
    /// The second copy of a tracking refusal: a store nothing else writes.
    var refusals: KeyValueStore
    var eventsFile: (String) -> PersistentFile
    var lifecycle: AppLifecycleSource
    var pushPlatform: PushPlatform
    var tokens: PushTokens
    var deviceInfo: DeviceInfo
    var timing: DeliveryTiming
    var tokenTimeout: Double
    /// How long `logout()` waits to send and detach.
    var logoutWait: Double = 5
    var now: @Sendable () -> Date
    var installPushIntegration: (Log) -> Void

    /// The app's `state.json`, shared by every client, and readable before any exists.
    static func liveStateStore(onError: @escaping @Sendable (Error) -> Void = { _ in }) -> FileKeyValueStore {
        let url = StorageLocation.directory().appendingPathComponent("state.json")
        return FileKeyValueStore.shared(file: PersistentFile(url: url, onError: onError))
    }

    static func live(log: Log) -> KiroraEnvironment {
        let directory = StorageLocation.directory()
        let onError: @Sendable (Error) -> Void = { error in log.error("Couldn't save to the device", error) }
        #if canImport(UIKit) && !os(watchOS)
        let lifecycle: AppLifecycleSource = UIKitLifecycle()
        let platform: PushPlatform = UIKitPushPlatform()
        let installPushIntegration: (Log) -> Void = { PushIntegration.install(log: $0) }
        readDeviceScreen()
        #else
        let lifecycle: AppLifecycleSource = NoLifecycle()
        let platform: PushPlatform = UnsupportedPushPlatform()
        let installPushIntegration: (Log) -> Void = { _ in }
        #endif
        return KiroraEnvironment(
            transport: URLSessionTransport(),
            store: liveStateStore(onError: onError),
            refusals: FileKeyValueStore.shared(file: PersistentFile(url: directory.appendingPathComponent("consent.json"), onError: onError)),
            eventsFile: { namespace in
                // At most one rewrite of every waiting event a second, however fast events come;
                // written at once before the app is suspended (`EventQueue.writesDone()`).
                PersistentFile(
                    url: directory.appendingPathComponent("events-\(fileSafe(namespace)).json"),
                    writeSpacing: 1, onError: onError
                )
            },
            lifecycle: lifecycle,
            pushPlatform: platform,
            tokens: .shared,
            deviceInfo: DeviceInfo(),
            timing: DeliveryTiming(),
            tokenTimeout: 30,
            now: { Date() },
            installPushIntegration: installPushIntegration
        )
    }
}


/// Where push isn't available.
struct UnsupportedPushPlatform: PushPlatform {
    var isSupported: Bool { false }
    func authorization() async -> PushAuthorization { .notDetermined }
    func requestAuthorization() async throws -> Bool { false }
    func registerForRemoteNotifications() async {}
    func firebaseTarget() async -> PushTarget? { nil }
}

/// The latest client's `handleDeepLink`. Taps reach the SDK through iOS, not a client, so
/// the client created last speaks for the app.
let deepLinkHandler = Locked<(@MainActor @Sendable (URL) -> Bool)?>(nil)

/// A file name for a workspace's namespace (`kirora_pk_…@api.kirora.io`): a stable hash, so
/// no key or host characters end up in a path.
func fileSafe(_ namespace: String) -> String {
    // FNV-1a, 64-bit: stable across launches, unlike `hashValue`.
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in namespace.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}
