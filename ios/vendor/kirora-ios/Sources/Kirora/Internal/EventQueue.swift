import Foundation

/// As `POST /events/batch` takes it. The idempotency key, fixed when the event is queued,
/// makes resends safe.
struct QueuedEvent: Codable, Sendable, Equatable {
    var idempotencyKey: String
    var name: String
    var properties: [String: JSONValue]
    var occurredAt: String
    /// As `beforeSend` left it.
    var context: [String: JSONValue]
}

/// Where and on what an event happened, as the SDK collects it. Only the fields
/// `api/events.md` lists: Kirora refuses any other.
/// Who an event belongs to: the signed-in user's token subject when it was tracked, or nil
/// before sign-in. Kept on the device only, never sent.
private struct StoredEvent: Codable, Sendable {
    var owner: String?
    var event: QueuedEvent
    /// For an event from before sign-in that continued a user's visit (after a relaunch,
    /// say), whose visit it was. Kept after adoption, so one given back is checked again.
    var sessionOwner: String?

    /// Owned by `owner` from now on. Leaves another user's visit: two users' visits are
    /// never joined.
    func adopted(by owner: String) -> StoredEvent {
        var entry = self
        entry.owner = owner
        if let sessionOwner, sessionOwner != owner { entry.event.context["sessionId"] = nil }
        return entry
    }
}

/// Past this many, the oldest events are dropped (e.g. after a long time offline).
let maxQueuedEvents = 1000
/// Past this many UTF-8 bytes of stored entries, ownership included, the oldest are dropped.
let maxQueuedBytes = 1_000_000

/// Events waiting to be sent, kept in a file so they survive the app being killed. One
/// queue per workspace.
///
/// Events tracked before sign-in wait without an owner until a sign-in adopts them: from
/// then on they go as that user or not at all. An event tracked while a user was signed in
/// only ever goes as that user. At most 1,000 events and 1,000,000 bytes are kept.
///
/// Every client of the workspace in the process shares one (``shared(file:log:)``).
///
/// The file is read off the caller's thread, so creating the client never waits on the
/// disk. Events tracked before it's read are kept after those read; anything that reads or
/// removes events waits for it. The read happens on the file's own queue, after any write
/// an earlier client asked for, so a client never loses another's events.
final class EventQueue: @unchecked Sendable {
    private struct State {
        var stored: [StoredEvent] = []
        /// Each stored entry's encoded size, in step with `stored`.
        var sizes: [Int] = []
        var bytes = 0
        var loaded = false
        /// Clears made while the file couldn't be read, applied to what it holds once it can:
        /// every event, some users' (a logout, rare), and events settled by key (each batch
        /// sent, so a set rather than a closure per batch).
        var clearedAllWhileUnreadable = false
        var clearsWhileUnreadable: [(StoredEvent) -> Bool] = []
        var removedWhileUnreadable = Set<String>()

        mutating func replace(_ entries: [StoredEvent]) {
            stored = []
            sizes = []
            bytes = 0
            for entry in entries { append(entry, size: encodedSize(entry)) }
            trim()
        }

        /// Gives entry `index` a new owner, its size changed by `change`: the owners' bytes,
        /// worked out once by the caller for a whole loop.
        mutating func setOwner(_ owner: String?, at index: Int, sizeChange change: Int) {
            stored[index].owner = owner
            sizes[index] += change
            bytes += change
        }

        /// Puts `entry` in place of entry `index`, measuring it again.
        mutating func replace(at index: Int, with entry: StoredEvent) {
            let size = encodedSize(entry)
            stored[index] = entry
            bytes += size - sizes[index]
            sizes[index] = size
        }

        mutating func append(_ entry: StoredEvent, size: Int) {
            stored.append(entry)
            sizes.append(size)
            bytes += size
        }

        mutating func removeAll(where test: (StoredEvent) -> Bool) {
            var kept: [StoredEvent] = [], keptSizes: [Int] = []
            for (entry, size) in zip(stored, sizes) where !test(entry) {
                kept.append(entry)
                keptSizes.append(size)
            }
            stored = kept
            sizes = keptSizes
            bytes = keptSizes.reduce(0, +)
        }

        /// Drops the oldest until both budgets fit. The file is a JSON array: a comma per entry.
        mutating func trim() {
            var drop = 0
            while drop < stored.count,
                  stored.count - drop > maxQueuedEvents || fileBytes(bytes, stored.count - drop) > maxQueuedBytes {
                bytes -= sizes[drop]
                drop += 1
            }
            if drop > 0 {
                stored.removeFirst(drop)
                sizes.removeFirst(drop)
            }
        }
    }

    private let file: PersistentFile
    private let log: Log
    private let state = Locked(State())
    /// Whether the warning that events live in memory only has been given, since the file
    /// last worked.
    private let warnedMemoryOnly = Locked(false)

    private static let shared = SharedPerFile<EventQueue>()

    /// The queue for `file`, shared by every client of the workspace in the process, so
    /// two never overwrite each other's events or adopt the same ones.
    static func shared(file: PersistentFile, log: Log) -> EventQueue {
        shared.instance(for: file.url) { EventQueue(file: file, log: log) }
    }

    init(file: PersistentFile, log: Log = Log(level: .none)) {
        self.file = file
        self.log = log
        file.onRecovered { [weak self] data in self?.recover(data) }
        file.readSoon { data in self.load(data) }
    }

    /// Queues `event`, dropping the oldest past the limits; an event larger than the whole
    /// byte budget is dropped itself. Returns how many `owner` may send now, leaving out
    /// other users' events, which can't go in their batch.
    ///
    /// Never waits for the file: before it's read, the read writes what was added meanwhile
    /// together with what it read, so the file never holds less than it did.
    @discardableResult
    /// `sessionOwner`: for one tracked before sign-in, whose visit it continued; one given
    /// straight to a user who has signed in since (after `beforeSend`) is adopted by them.
    func add(_ event: QueuedEvent, owner: String?, sessionOwner: String? = nil) -> Int {
        let unowned = StoredEvent(owner: nil, event: event, sessionOwner: sessionOwner)
        let entry = owner.map { unowned.adopted(by: $0) } ?? unowned
        let size = encodedSize(entry)
        guard fileBytes(size, 1) <= maxQueuedBytes else {
            log.error("\(event.name) not tracked: larger than the \(maxQueuedBytes)-byte queue")
            return state.withLock { state in state.stored.lazy.filter { sendable($0, by: owner) }.count }
        }
        let waiting = state.withLock { state -> Int in
            state.append(entry, size: size)
            state.trim()
            if state.loaded { persist() }
            return state.stored.lazy.filter { sendable($0, by: owner) }.count
        }
        warnIfMemoryOnly()
        return waiting
    }

    /// Once each time saving starts failing: the queue goes on in memory, within the same
    /// limits, but what it holds is lost when the app is killed.
    private func warnIfMemoryOnly() {
        guard file.writeFailed else {
            warnedMemoryOnly.withLock { $0 = false }
            return
        }
        if warnedMemoryOnly.claimOnce() {
            log.error(
                "Events can't be saved on this device: up to \(maxQueuedEvents) are kept in memory, and they won't survive a restart"
            )
        }
    }

    /// Makes the events from before sign-in `owner`'s, as they sign in: from now on they go
    /// as `owner` or not at all, whoever signs in next. Returns their idempotency keys, for
    /// ``release(_:owner:)``.
    func adopt(_ owner: String, where include: (String) -> Bool = { _ in true }) -> Set<String> {
        loadIfNeeded()
        return state.withLock { state in
            var adopted = Set<String>()
            let change = ownerBytes(owner)
            for index in state.stored.indices
            where state.stored[index].owner == nil && include(state.stored[index].event.idempotencyKey) {
                let entry = state.stored[index]
                if let sessionOwner = entry.sessionOwner, sessionOwner != owner {
                    state.replace(at: index, with: entry.adopted(by: owner))
                } else {
                    state.setOwner(owner, at: index, sizeChange: change)
                }
                adopted.insert(entry.event.idempotencyKey)
            }
            if !adopted.isEmpty {
                state.trim()
                persist()
            }
            return adopted
        }
    }

    /// Undoes ``adopt(_:)`` for those of `keys` still waiting as `owner`'s, as a sign-in
    /// turns out to have failed: they wait for the next sign-in again.
    func release(_ keys: Set<String>, owner: String) {
        guard !keys.isEmpty else { return }
        state.withLock { state in
            var changed = false
            let change = -ownerBytes(owner)
            for index in state.stored.indices
            where state.stored[index].owner == owner && keys.contains(state.stored[index].event.idempotencyKey) {
                state.setOwner(nil, at: index, sizeChange: change)
                changed = true
            }
            if changed { persist() }
        }
    }

    /// Events waiting on the device, whoever owns them.
    var count: Int {
        loadIfNeeded()
        return state.withLock { $0.stored.count }
    }

    /// The oldest events `owner` may send: only their own.
    func oldest(_ count: Int, owner: String?) -> [QueuedEvent] {
        loadIfNeeded()
        return state.withLock { state in
            Array(state.stored.lazy.filter { sendable($0, by: owner) }.prefix(count).map(\.event))
        }
    }

    func remove(_ idempotencyKeys: Set<String>) {
        guard !idempotencyKeys.isEmpty else { return }
        keep(recording: { $0.removedWhileUnreadable.formUnion(idempotencyKeys) }) {
            !idempotencyKeys.contains($0.event.idempotencyKey)
        }
    }

    /// Forgets the events `test` picks of those with an owner, leaving those from before
    /// sign-in to whoever's next.
    func clearOwned(where test: @escaping (String, QueuedEvent) -> Bool) {
        keep { stored in
            guard let owner = stored.owner else { return true }
            return !test(owner, stored.event)
        }
    }

    /// The keys of the events waiting for a sign-in now, and of those that continued a
    /// signed-in user's visit.
    func waitingKeys() -> (all: Set<String>, onSignedInVisits: Set<String>) {
        loadIfNeeded()
        return state.withLock { state in
            let waiting = state.stored.filter { $0.owner == nil }
            return (
                Set(waiting.map(\.event.idempotencyKey)),
                Set(waiting.filter { $0.sessionOwner != nil }.map(\.event.idempotencyKey))
            )
        }
    }

    /// Drops those of `keys` still waiting for a sign-in.
    func clearWaiting(_ keys: Set<String>) {
        guard !keys.isEmpty else { return }
        keep { $0.owner != nil || !keys.contains($0.event.idempotencyKey) }
    }

    func clearAll() {
        keep(recording: { $0.clearedAllWhileUnreadable = true }) { _ in false }
    }

    /// Removes what `test` rejects, writing only if that was anything. While the file can't
    /// be read, `test` is kept too, for the events it holds once it can be: a clear (consent
    /// withdrawn, a logout) covers them as well.
    private func keep(
        recording record: ((inout State) -> Void)? = nil,
        _ test: @escaping (StoredEvent) -> Bool
    ) {
        loadIfNeeded()
        state.withLock { state in
            if file.unreadable {
                if let record { record(&state) } else { state.clearsWhileUnreadable.append(test) }
            }
            let before = state.stored.count
            state.removeAll { !test($0) }
            if state.stored.count != before, state.loaded { persist() }
        }
    }

    /// Reads the file now if it hasn't been: before taking a lock that `track()` waits on, so
    /// that wait is never a disk read.
    func preload() { loadIfNeeded() }

    /// Writes the events now rather than when their spacing allows: before the app is
    /// suspended.
    func writesDone() async { await file.writesDone() }

    private func loadIfNeeded() {
        if !state.withLock({ $0.loaded }) { file.readNow { load($0) } }
        file.retryIfUnreadable()
    }

    /// On the file's queue, once a file that couldn't be read (before the first unlock) can
    /// be: its events, which nothing wrote over, come first, then those tracked meanwhile.
    private func recover(_ data: Data?) {
        let decoded = Self.decode(data)
        state.withLock { state in
            // What was cleared meanwhile stays cleared.
            let kept = state.clearedAllWhileUnreadable ? [] : decoded.filter { entry in
                !state.removedWhileUnreadable.contains(entry.event.idempotencyKey)
                    && state.clearsWhileUnreadable.allSatisfy { $0(entry) }
            }
            state.clearedAllWhileUnreadable = false
            state.clearsWhileUnreadable = []
            state.removedWhileUnreadable = []
            let saved = Set(kept.map(\.event.idempotencyKey))
            state.replace(kept + state.stored.filter { !saved.contains($0.event.idempotencyKey) })
            // Under the same lock as any change, so none falls between the two.
            file.markReadable()
        }
        persist()
    }

    /// On the file's queue: takes the events read, once, keeping those tracked meanwhile
    /// after them, and writes the two together at once.
    private func load(_ data: Data?) {
        if state.withLock({ $0.loaded }) { return }
        let decoded = Self.decode(data)
        let merged = state.withLock { state -> [StoredEvent]? in
            guard !state.loaded else { return nil }
            let trackedMeanwhile = state.stored
            state.replace(decoded + trackedMeanwhile)
            state.loaded = true
            return trackedMeanwhile.isEmpty ? nil : state.stored
        }
        // A file that couldn't be read is never written over: what it holds is merged in once
        // it can be.
        if let merged, !file.unreadable, let data = try? JSONEncoder().encode(merged) { file.writeNow(data) }
    }

    /// Writes the queue soon, as it stands when the write runs: a burst of changes costs
    /// one copy and one write, and nothing is copied on the caller's thread.
    private func persist() {
        file.write {
            let stored = self.state.withLock { $0.stored }
            return stored.isEmpty ? nil : try JSONEncoder().encode(stored)
        }
    }

    /// The events `data` holds; unreadable entries are skipped rather than losing the whole
    /// queue to them.
    private static func decode(_ data: Data?) -> [StoredEvent] {
        (data.flatMap { try? JSONDecoder().decode([Lenient].self, from: $0) } ?? []).compactMap(\.value)
    }

    /// One entry of the stored queue, or nil if it can't be read.
    private struct Lenient: Decodable {
        let value: StoredEvent?
        init(from decoder: Decoder) throws {
            value = try? StoredEvent(from: decoder)
        }
    }
}

/// A signed-in user sends only their own events; those from before sign-in wait to be
/// adopted.
private func sendable(_ stored: StoredEvent, by owner: String?) -> Bool {
    owner != nil && stored.owner == owner
}

/// The file's size for entries of `bytes` in all: a JSON array, with a comma between each.
private func fileBytes(_ bytes: Int, _ count: Int) -> Int {
    bytes + max(count - 1, 0) + 2
}

/// What an owner adds to an entry's JSON: `"owner":"…",`, or nothing when there's none.
private func ownerBytes(_ owner: String?) -> Int {
    guard let owner, let encoded = try? JSONEncoder().encode(["owner": owner]) else { return 0 }
    return encoded.count - 2 + 1
}

/// An entry's size in the file, as UTF-8 JSON.
private func encodedSize(_ entry: StoredEvent) -> Int {
    (try? JSONEncoder().encode(entry).count) ?? 0
}
