import Foundation

let sessionStartedEvent = "Session Started"
let screenViewedEvent = "Screen Viewed"

/// A visit ends after 30 minutes without activity.
let sessionTimeout: Double = 30 * 60
/// How often the foreground keeps its visit alive: well inside the timeout.
let sessionKeepAlive: Double = 5 * 60

/// Tracking consent. With `requireTrackingConsent`, nothing is tracked until the user says
/// yes; without it, until they say no. The answer is kept in the app's store, per
/// workspace: in memory at once, shared by every client of the workspace, and saved.
///
/// A refusal is also kept in a second store of its own (`consent.json`, which nothing else
/// writes), so losing or corrupting either file can't lose it: either one saying
/// `refused` is a refusal, and a grant clears both.
///
/// If the main store's answer was lost (its file couldn't be read), a grant is never
/// assumed. With `requireTrackingConsent`, nothing is tracked until a fresh answer. Without
/// it, tracking goes on as on a fresh install, but only once the refusal copy has been read
/// and holds no refusal; while it can't be read either, nothing is tracked.
struct TrackingConsent: Sendable {
    let store: KeyValueStore
    /// The second copy of a refusal.
    let refusals: KeyValueStore
    let required: Bool
    let log: Log
    private let warned = Locked(false)

    init(store: KeyValueStore, refusals: KeyValueStore, required: Bool, log: Log = Log(level: .none)) {
        self.store = store
        self.refusals = refusals
        self.required = required
        self.log = log
    }

    var allowed: Bool {
        // One read of each copy; whether the main one was lost is asked only without an answer.
        let answer = store.string(StorageKeys.trackingConsent)
        if answer == "refused" || refusals.string(StorageKeys.trackingConsent) == "refused" { return false }
        if answer == "granted" { return true }
        guard Self.lost(store) else { return !required }
        if required {
            warnOnce("The saved tracking consent answer can't be read: nothing is tracked until setTrackingConsent(_:) is called again")
            return false
        }
        if Self.lost(refusals) {
            warnOnce("The saved tracking consent answer can't be read, nor whether the user refused: nothing is tracked until one can be, or setTrackingConsent(_:) is called again")
            return false
        }
        warnOnce("The saved tracking consent answer can't be read; no refusal is on record, so tracking goes on as on a fresh install")
        return true
    }

    /// The user said no, as opposed to not having answered yet: in either copy.
    var refused: Bool {
        store.string(StorageKeys.trackingConsent) == "refused"
            || refusals.string(StorageKeys.trackingConsent) == "refused"
    }

    /// Records the answer, in both copies. True if tracking has just become allowed.
    func answer(_ granted: Bool) -> Bool {
        let newlyAllowed = granted && !allowed
        // The refusal copy first, either way: a refusal is on record somewhere as soon as
        // possible, and a grant leaves the main copy's refusal until the copy is cleared.
        refusals.set(granted ? nil : "refused", for: StorageKeys.trackingConsent)
        store.set(granted ? "granted" : "refused", for: StorageKeys.trackingConsent)
        // A fresh answer: whatever either file lost no longer matters to this workspace.
        if Self.lost(store) { store.set("0", for: StorageKeys.trackingConsentUnknown) }
        if Self.lost(refusals) { refusals.set("0", for: StorageKeys.trackingConsentUnknown) }
        if store.writeFailed || (!granted && refusals.writeFailed) {
            log.error("The tracking consent answer can't be saved on this device: it holds until the app is closed, then ask again")
        }
        return newlyAllowed
    }

    private func warnOnce(_ message: String) {
        if warned.claimOnce() { log.error(message) }
    }

    /// Whether what `store` held for this workspace may have been lost (its file couldn't be
    /// read, or decoded), with no fresh answer since.
    private static func lost(_ store: KeyValueStore) -> Bool {
        switch store.string(StorageKeys.trackingConsentUnknown) {
        case "1": return true
        case "0": return false
        default: return store.string(StorageKeys.stateUnreadable) == "1"
        }
    }
}

/// The current visit, kept in device storage so a relaunch continues it. Read once and kept
/// in memory; written when a visit starts, when the app goes to the background, and at most
/// once a minute otherwise: a minute is nothing against the 30-minute timeout.
///
/// A visit is its owner's: the user signed in when it began, or nobody. A different user's
/// activity begins a visit of their own; one begun before sign-in becomes the user's.
final class Sessions: @unchecked Sendable {
    private struct Stored: Codable, Equatable {
        var sessionId: String
        var lastActivityAt: Int64
        /// Whose visit: the token subject, or nil before sign-in.
        var owner: String?
    }

    /// The visit as last recorded, and when it was last written.
    private struct State {
        var loaded = false
        var current: Stored?
        var writtenAt: Int64 = 0
    }

    private static let writeEvery: Int64 = 60_000

    private let store: KeyValueStore
    private let now: @Sendable () -> Date
    private let state = Locked(State())

    init(store: KeyValueStore, now: @escaping @Sendable () -> Date) {
        self.store = store
        self.now = now
    }

    /// Records `owner`'s activity on the current visit. `started` is true if a new one began;
    /// `visitOwner` is whose visit it is: before sign-in, a user's whose visit it continues.
    func touch(owner: String?) -> (sessionId: String, started: Bool, visitOwner: String?) {
        state.withLock { state in
            var live = liveSessionId(&state)
            if live != nil, let owner, let current = state.current?.owner, current != owner { live = nil }
            let sessionId = live ?? newId()
            let keptOwner = owner ?? (live == nil ? nil : state.current?.owner)
            record(sessionId, owner: keptOwner, &state, writeNow: live == nil || keptOwner != state.current?.owner)
            return (sessionId, live == nil, keptOwner)
        }
    }

    /// Extends the current visit without starting one, so time in the foreground never
    /// ends a visit but a timer alone never begins one. `writeNow` before suspension.
    func keepAlive(writeNow: Bool = false) {
        state.withLock { state in
            if let sessionId = liveSessionId(&state) {
                record(sessionId, owner: state.current?.owner, &state, writeNow: writeNow)
            }
        }
    }

    /// The current visit's id, if one is live; neither starts nor extends one.
    var currentId: String? { state.withLock { liveSessionId(&$0) } }

    /// Ends the visit; with an `owner`, only if it's theirs, as they sign out (one begun
    /// since, by nobody, goes on, and becomes the next user's).
    func end(ifOwnedBy owner: String? = nil) {
        state.withLock { state in
            if let owner {
                _ = liveSessionId(&state)
                guard state.current?.owner == owner else { return }
            }
            state = State(loaded: true)
            store.set(nil, for: StorageKeys.session)
        }
    }

    private func record(_ sessionId: String, owner: String?, _ state: inout State, writeNow: Bool) {
        let at = epochMs(now())
        state.current = Stored(sessionId: sessionId, lastActivityAt: at, owner: owner)
        if writeNow || at - state.writtenAt >= Self.writeEvery {
            store.setJSON(state.current, for: StorageKeys.session)
            state.writtenAt = at
        }
    }

    private func liveSessionId(_ state: inout State) -> String? {
        if !state.loaded {
            state.current = store.json(Stored.self, StorageKeys.session)
            state.loaded = true
        }
        guard let current = state.current else { return nil }
        let idle = Double(epochMs(now()) - current.lastActivityAt) / 1000
        return idle < sessionTimeout ? current.sessionId : nil
    }
}

/// Turns what the app tracks into queued events: their time, visit and device, owned by
/// whoever is signed in, passed through the app's `beforeSend`. Nothing is recorded without
/// tracking consent, and nothing here throws: a failure is logged, so it never breaks the app.
///
/// Everything runs on the caller's thread. Events are built under one lock, with the user
/// signed in at that moment, and queued in the order they're tracked. The app's
/// `beforeSend` runs outside the lock, so a hook that waits on another thread that is
/// itself tracking can't freeze the app; with a hook, events tracked at the same moment on
/// different threads may be queued in either order (each keeps its own time).
final class Tracker: @unchecked Sendable {
    private let identity: Identity
    private let queue: EventQueue
    private let consent: TrackingConsent
    private let sessions: Sessions

    /// The current visit's id, if one is live.
    var currentSessionId: String? { sessions.currentId }
    private let deviceId: DeviceId
    private let deviceInfo: DeviceInfo
    private let trackSessions: Bool
    private let beforeSend: (@Sendable (BeforeSendEvent) throws -> BeforeSendEvent?)?
    private let log: Log
    private let now: @Sendable () -> Date
    private let onQueued: @Sendable (Int) -> Void
    private let lock = NSLock()
    /// Events built under `lock`, waiting for `beforeSend` outside it. Only under `lock`.
    private var drafts: [Draft] = []

    /// An event as built, before `beforeSend`.
    private struct Draft {
        let name: String
        let properties: [String: JSONValue]
        let context: [String: JSONValue]
        let occurredAt: String
        let owner: String?
        let sessionOwner: String?
        /// Its place in ``inFlight`` while `beforeSend` runs.
        let id: Int
    }

    /// The events `beforeSend` is running for, outside the lock, by id, with their owners.
    /// A clear under the lock (consent withdrawn, a logout) removes them here as it clears
    /// the queue, and only those still here are queued once the hook returns.
    private var inFlight: [Int: Flight] = [:]

    /// An event `beforeSend` is running for: its owner, and whether, tracked before sign-in,
    /// it continued a signed-in user's visit.
    private struct Flight {
        let owner: String?
        let onSignedInVisit: Bool
        /// Held by a logout, as it was waiting for a sign-in as the logout began.
        var held = false
    }
    private var nextDraftId = 0

    /// While a logout waits: the events that were waiting for a sign-in as it began, held
    /// for a sign-in already under way then (one that lands leaving), and never for a later
    /// one. Only under `lock`.
    /// By key, each with whether it continued a signed-in user's visit; those still in
    /// `beforeSend` are marked in ``inFlight``.
    private var held: [String: Bool]?

    init(
        identity: Identity,
        queue: EventQueue,
        consent: TrackingConsent,
        sessions: Sessions,
        deviceId: DeviceId,
        deviceInfo: DeviceInfo,
        trackSessions: Bool,
        beforeSend: (@Sendable (BeforeSendEvent) throws -> BeforeSendEvent?)? = nil,
        log: Log,
        now: @escaping @Sendable () -> Date,
        onQueued: @escaping @Sendable (Int) -> Void
    ) {
        self.identity = identity
        self.queue = queue
        self.consent = consent
        self.sessions = sessions
        self.deviceId = deviceId
        self.deviceInfo = deviceInfo
        self.trackSessions = trackSessions
        self.beforeSend = beforeSend
        self.log = log
        self.now = now
        self.onQueued = onQueued
    }

    /// Builds the event right away so its time is accurate, then queues it. Kirora decides
    /// whether its name is acceptable.
    func track(_ name: String, properties: [String: JSONValue]) {
        exclusively {
            guard consent.allowed else { return }
            let owner = identity.capturingSubject
            capture(name, properties, touchSession(owner), owner)
        }
    }

    /// Activity keeps the visit alive, or starts a new one with `Session Started`.
    func noteActivity() {
        exclusively {
            guard consent.allowed else { return }
            _ = touchSession(identity.capturingSubject)
        }
    }

    /// Extends the current visit without starting one, e.g. while in the foreground.
    /// `writeNow` as the app goes to the background.
    func keepSessionAlive(writeNow: Bool = false) {
        exclusively {
            if trackSessions, consent.allowed { sessions.keepAlive(writeNow: writeNow) }
        }
    }

    /// Tracks the events `build` makes, building them only if tracking is allowed: building
    /// may store state (the app's version, for lifecycle events), which consent covers too.
    func trackAll(_ build: () -> [(String, [String: JSONValue])]) {
        exclusively {
            guard consent.allowed else { return }
            let owner = identity.capturingSubject
            for (name, properties) in build() {
                capture(name, properties, touchSession(owner), owner)
            }
        }
    }

    /// Gives the events waiting for a sign-in to `owner`. Under the tracker's lock, so an
    /// event tracked as they sign in is either tracked as theirs or adopted, never left
    /// waiting for whoever signs in next. While a logout waits, one leaving (a sign-in under
    /// way as it began) takes only those held for it, and any other only the rest. Returns
    /// the keys adopted, and whether `user` is leaving; nothing for one signed out already.
    func adoptWaitingEvents(as user: SignedInUser) -> (keys: Set<String>, leaving: Bool) {
        withQueueLock {
            guard identity.user === user else { return ([], true) }
            // Read under this lock, as a logout begins under it too.
            let leaving = identity.capturingUser !== user
            guard let held else { return (queue.adopt(user.subject), leaving) }
            return (queue.adopt(user.subject) { (held[$0] != nil) == leaving }, leaving)
        }
    }

    /// Ends `owner`'s visit, as they sign out: the next activity begins a new one.
    func endSession(ownedBy owner: String) {
        lock.lock()
        defer { lock.unlock() }
        sessions.end(ifOwnedBy: owner)
    }

    /// Forgets queued events and the visit, as when consent is withdrawn; if `condition`
    /// holds, checked under the same lock as tracking, so an event tracked right after
    /// consent is granted is never forgotten with the rest. Never refused, even from
    /// inside `beforeSend`.
    @discardableResult
    func forget(if condition: () -> Bool = { true }) -> Bool {
        withQueueLock {
            guard condition() else { return false }
            queue.clearAll()
            sessions.end()
            inFlight = [:]
            return true
        }
    }

    /// Holds the events waiting for a sign-in as a logout begins, those being built
    /// included: only a sign-in already under way may adopt them now. `beginLogout` runs
    /// under the same lock as adoption, so no sign-in lands between the two.
    func holdWaitingEvents<T>(beginningLogout beginLogout: () -> T) -> T {
        withQueueLock {
            let (keys, onSignedInVisits) = queue.waitingKeys()
            held = Dictionary(uniqueKeysWithValues: keys.map { ($0, onSignedInVisits.contains($0)) })
            for id in inFlight.keys where inFlight[id]?.owner == nil { inFlight[id]?.held = true }
            return beginLogout()
        }
    }

    /// As the logout's wait ends, forgets the held events still waiting: a sign-in under way
    /// as it began has adopted them, if it signed in. What was tracked since waits for the
    /// next user, as do those not forgotten.
    ///
    /// With a user signed out, all of them: they were waiting as theirs. With nobody signed in
    /// (`onlyOnSignedInVisits`), only those that continued a signed-in user's visit, made by an
    /// app that restored its own session without identify(); a visitor who never signed in
    /// keeps theirs, so a logout() on a screen before sign-up can't lose them. Without visits,
    /// that can't be told, so none.
    func releaseHeldEvents(forgettingOnlyOnSignedInVisits onlyOnSignedInVisits: Bool) {
        withQueueLock {
            guard let held else { return }
            self.held = nil
            queue.clearWaiting(Set(held.filter { !onlyOnSignedInVisits || $0.value }.keys))
            inFlight = inFlight.filter { _, flight in
                !(flight.held && (!onlyOnSignedInVisits || flight.onSignedInVisit))
            }
        }
    }

    /// Forgets `owner`'s queued events, as they sign out, including one being built for
    /// them right now.
    func forgetEvents(ownedBy owner: String) {
        withQueueLock {
            queue.clearOwned { stored, _ in stored == owner }
            inFlight = inFlight.filter { $0.value.owner != owner }
        }
    }

    /// Runs `body` under the lock, having read the event file first: `track()` waits on the
    /// lock, so that wait is never a disk read.
    private func withQueueLock<T>(_ body: () -> T) -> T {
        queue.preload()
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Runs `body` under the lock, then passes what it built through `beforeSend` and queues
    /// it.
    private func exclusively(_ body: () -> Void) {
        // An app's beforeSend that tracks would otherwise call itself without end.
        // Only a hook sets the flag: without one, no thread lookup.
        guard beforeSend == nil || !inBeforeSendOnThisThread else {
            log.error("Not tracked: called from beforeSend")
            return
        }
        lock.lock()
        body()
        let built = drafts
        drafts = []
        lock.unlock()
        guard !built.isEmpty else { return }
        let redactedEvents = built.compactMap { draft in
            redacted(draft.name, draft.properties, draft.context).map { (draft, $0.0, $0.1) }
        }
        lock.lock()
        defer { lock.unlock() }
        // Those a clear didn't take while the hook ran (consent withdrawn, their user signed out).
        var live: [Int: Flight] = [:]
        for draft in built { live[draft.id] = inFlight.removeValue(forKey: draft.id) }
        // The hook may have withdrawn consent.
        guard consent.allowed else { return }
        for (draft, properties, context) in redactedEvents {
            guard let flight = live[draft.id] else { continue }
            let event = QueuedEvent(
                idempotencyKey: newId(), name: draft.name, properties: properties,
                occurredAt: draft.occurredAt, context: context
            )
            // Held by a logout still waiting: it waits with the others it held, for the
            // same end. Otherwise, from before sign-in with a sign-in since, that user adopts
            // it, as they adopted what was queued already.
            let isHeld = flight.held && held != nil
            if isHeld { held?[event.idempotencyKey] = flight.onSignedInVisit }
            enqueue(event, owner: isHeld ? nil : draft.owner ?? identity.capturingSubject, sessionOwner: draft.sessionOwner)
        }
    }

    /// True on a thread running the app's `beforeSend`.
    private var inBeforeSendOnThisThread: Bool {
        Thread.current.threadDictionary[beforeSendThreadKey] != nil
    }

    /// The visit an event joins, if visits are on, starting one if needed. `borrowedFrom`:
    /// for one tracked before sign-in, the user whose visit it continues (after a relaunch,
    /// say), so that if someone else adopts it, it leaves their visit.
    private typealias Visit = (id: String?, borrowedFrom: String?)

    private func touchSession(_ owner: String?) -> Visit {
        guard trackSessions else { return (nil, nil) }
        let (sessionId, started, visitOwner) = sessions.touch(owner: owner)
        // Mobile SDKs track `Session Started` without properties.
        if started { capture(sessionStartedEvent, [:], (sessionId, nil), owner) }
        return (sessionId, owner == nil ? visitOwner : nil)
    }

    /// Makes the event and queues it as `owner`'s, or, with a `beforeSend`, leaves it for
    /// the hook outside the lock. Its time is taken first, so a slow hook doesn't move it.
    /// Under `lock`.
    private func capture(_ name: String, _ properties: [String: JSONValue], _ visit: Visit, _ owner: String?) {
        let occurredAt = isoTimestamp(now())
        // device.id will let Kirora link activity from before sign-in to the user later.
        let context = deviceInfo.eventContext(deviceId: deviceId.value(), sessionId: visit.id)
        guard beforeSend == nil else {
            nextDraftId += 1
            inFlight[nextDraftId] = Flight(owner: owner, onSignedInVisit: visit.borrowedFrom != nil)
            drafts.append(Draft(name: name, properties: properties, context: context, occurredAt: occurredAt, owner: owner, sessionOwner: visit.borrowedFrom, id: nextDraftId))
            return
        }
        enqueue(QueuedEvent(
            idempotencyKey: newId(), name: name, properties: properties,
            occurredAt: occurredAt, context: context
        ), owner: owner, sessionOwner: visit.borrowedFrom)
    }

    /// Under `lock`.
    private func enqueue(_ event: QueuedEvent, owner: String?, sessionOwner: String?) {
        let waiting = queue.add(event, owner: owner, sessionOwner: sessionOwner)
        log.debug("Queued \(event.name)")
        onQueued(waiting)
    }

    /// The event as `beforeSend` leaves it, or nil if it drops it. Only a failure's kind is
    /// logged, never the event: it may be what the hook was there to hide.
    private func redacted(
        _ name: String, _ properties: [String: JSONValue], _ context: [String: JSONValue]
    ) -> ([String: JSONValue], [String: JSONValue])? {
        guard let beforeSend else { return (properties, context) }
        let event = BeforeSendEvent(
            name: name,
            properties: properties.mapValues(\.foundationValue),
            context: context.mapValues(\.foundationValue)
        )
        let answer: BeforeSendEvent?
        let thread = Thread.current.threadDictionary
        thread[beforeSendThreadKey] = true
        defer { thread.removeObject(forKey: beforeSendThreadKey) }
        do {
            answer = try beforeSend(event)
        } catch {
            log.error("\(name) not tracked: beforeSend threw")
            return nil
        }
        guard let answer else {
            log.debug("\(name) dropped by beforeSend")
            return nil
        }
        do {
            return (try JSONValue.fromObject(answer.properties), try JSONValue.fromObject(answer.context))
        } catch {
            log.error("\(name) not tracked: beforeSend answered \(error)")
            return nil
        }
    }
}

/// Marks a thread running the app's `beforeSend`.
private let beforeSendThreadKey = "io.kirora.sdk.inBeforeSend"
