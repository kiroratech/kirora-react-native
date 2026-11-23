import Foundation

/// Small values the SDK keeps on the device: `device.id`, the visit, consent, what was
/// last registered for push. Everything is in the app's own container, so it goes with an
/// uninstall.
protocol KeyValueStore: AnyObject, Sendable {
    func string(_ key: String) -> String?
    func set(_ value: String?, for key: String)
    /// The value for `key`, or, with none, `make()`'s, stored: in one step, so callers on
    /// two threads get the same value.
    func string(_ key: String, orSet make: () -> String) -> String
    /// A change couldn't be saved: it holds in memory only, until the app is killed.
    var writeFailed: Bool { get }
    /// Whether what's saved can be read, trying it again now if it couldn't (before the
    /// first unlock). While it can't, what's stored is in memory only. Waits for the read:
    /// never on the app's own thread.
    func isReadable() -> Bool
}

extension KeyValueStore {
    func json<Value: Decodable>(_ type: Value.Type, _ key: String) -> Value? {
        guard let text = string(key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setJSON<Value: Encodable>(_ value: Value?, for key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            set(nil, for: key)
            return
        }
        set(String(decoding: data, as: UTF8.self), for: key)
    }
}

/// Every key the SDK stores under. The README's "What the SDK stores" lists the same.
///
/// Those in ``scoped`` are kept per workspace and API deployment by ``WorkspaceStore``, so
/// two clients in one app never share a device id, visit or choice.
enum StorageKeys {
    static let scoped: Set<String> = [
        deviceId, deviceSecret, session, trackingConsent, trackingConsentUnknown, appVersion, appOpenActivity, pushDisabled,
        pushConsent,
    ]
    /// Where a scoped key is kept for `namespace`.
    static func scoped(_ key: String, _ namespace: String) -> String { "\(key):\(namespace)" }
    /// The key a stored one is, scoped or not.
    static func base(of storedKey: String) -> String {
        storedKey.split(separator: ":", maxSplits: 1).first.map(String.init) ?? storedKey
    }
    /// The user's own choices, and the token iOS gave last: set while the file couldn't be
    /// read, they win over what it held.
    static let userChoices: Set<String> = [trackingConsent, trackingConsentUnknown, pushDisabled, pushConsent, apnsToken]

    /// `device.id`, also the device's installation id for push.
    static let deviceId = "device-id"
    /// The installation's secret, sent with every push registration: it can only detach
    /// the device, with no user token held.
    static let deviceSecret = "device-secret"
    /// The current visit: its id and last activity.
    static let session = "session"
    /// The user's tracking consent answer.
    static let trackingConsent = "tracking-consent"
    /// `0` once this workspace has a fresh answer after ``stateUnreadable``; `1` if it lost
    /// one some other way.
    static let trackingConsentUnknown = "tracking-consent-unknown"
    /// `1` when the state file couldn't be read, so every workspace's saved answer may have
    /// been lost: tracking waits for a fresh one in each. Survives the file being written
    /// again, so a lost refusal never turns into the default.
    static let stateUnreadable = "state-unreadable"
    /// The app's version and build at the last launch, for lifecycle events.
    static let appVersion = "app-version"
    /// The last foreground activity, so app opens go at most once per 30 minutes.
    static let appOpenActivity = "app-open-activity"
    /// Set while `setPushEnabled(false)` holds: the device's own choice, kept past sign-out.
    static let pushDisabled = "push-disabled"
    /// The signed-in user's last marketing push choice Kirora recorded from this device, and
    /// whose it is, for `getState()`.
    static let pushConsent = "push-consent"
    /// The APNs device token iOS last gave: one per app, whichever workspace asks.
    static let apnsToken = "apns-token"
    /// The `apiUrl` the app last created a client with: one per app, for push taps heard
    /// before a client exists.
    static let apiUrl = "api-url"
    /// Who this device was last registered for push as, per workspace.
    static func pushRegistration(_ namespace: String) -> String { "push-registration:\(namespace)" }
    /// App opens waiting to be reported, per workspace.
    static func appOpens(_ namespace: String) -> String { "app-opens:\(namespace)" }
}

/// Where the SDK's files live: `Application Support/io.kirora.sdk/`, left out of iCloud
/// and iTunes backups so a restored phone gets a `device.id` of its own.
enum StorageLocation {
    /// Where the files go. Only works out the path: the directory is made, and kept out of
    /// backups, by the first write, off the app's thread.
    static func directory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("io.kirora.sdk", isDirectory: true)
    }
}

/// A file read and written in the background, the latest state winning: many changes in a
/// row cost one write, and the state is encoded there too, off the caller's thread.
///
/// Every client in the process uses one serial queue per file, so a client created after
/// another reads everything that one wrote, with no client waiting for its writes.
final class PersistentFile: @unchecked Sendable {
    /// Encodes the state to write, or nil to remove the file. Throws if it can't be
    /// encoded: the file is then left as it was, never removed.
    typealias Contents = @Sendable () throws -> Data?

    let url: URL
    private let queue: DispatchQueue
    private let pending = Locked<Contents?>(nil)
    private let onError: @Sendable (Error) -> Void
    private let failures = Locked((read: false, write: false, io: false))

    /// The file is there but couldn't be read, or what it holds couldn't be decoded.
    var readFailed: Bool { failures.current.read }
    /// The last write, or removal, failed.
    var writeFailed: Bool { failures.current.write }
    /// The last read failed with an I/O error (protected data before the first unlock):
    /// nothing is written until it's read again, so what it holds survives.
    var unreadable: Bool { failures.current.io }

    /// Told, on the file's queue, what the file holds once it can be read again. Set once,
    /// by the file's owner.
    private let recovered = Locked<(@Sendable (Data?) -> Void)?>(nil)
    /// When the file was last tried again, so a busy app doesn't try it on every call.
    private let lastRetry = Locked<Date?>(nil)
    private static let retryEvery: Double = 2

    /// Each path's queue, and every instance of it alive: a read or wait on one writes what
    /// any of them holds back first (a client released with a write still spaced out, say).
    private static let paths = Locked<[String: (queue: DispatchQueue, files: [Weak<PersistentFile>])]>([:])

    /// The least time between two writes. Zero writes as soon as the queue gets to it; the
    /// event queue spaces them, as each rewrites every event waiting. Whatever is held back
    /// is written before the file is read, and by ``waitForWrites()``.
    private let writeSpacing: Double
    /// When the last write ran (uptime), for the spacing.
    private let lastWrite = Locked<Double>(0)

    init(url: URL, writeSpacing: Double = 0, onError: @escaping @Sendable (Error) -> Void) {
        self.url = url
        self.writeSpacing = writeSpacing
        self.onError = onError
        queue = Self.paths.withLock { paths in
            if let queue = paths[url.path]?.queue { return queue }
            let queue = DispatchQueue(label: "io.kirora.sdk.file.\(url.lastPathComponent)", qos: .utility)
            paths[url.path] = (queue, [])
            return queue
        }
        let weak = Weak(self)
        Self.paths.withLock { paths in
            paths[url.path]?.files.removeAll { $0.value == nil }
            paths[url.path]?.files.append(weak)
        }
    }

    /// Runs `body` on the file's queue with the file as it stands after every write asked
    /// for so far, by any client, and waits for it. `body` may call ``writeNow(_:)``.
    func readNow<Result>(_ body: (Data?) -> Result) -> Result {
        queue.sync {
            Self.writeHeldBack(url.path)
            return body(read())
        }
    }

    /// As ``readNow(_:)``, without waiting.
    func readSoon(_ body: @escaping @Sendable (Data?) -> Void) {
        queue.async { [self] in
            Self.writeHeldBack(url.path)
            body(read())
        }
    }

    /// On the path's queue: writes now what every instance of it holds back.
    private static func writeHeldBack(_ path: String) {
        let files = paths.withLock { $0[path]?.files.compactMap(\.value) ?? [] }
        for file in files { file.writePending() }
    }

    /// The file's contents, or nil if there's none or it can't be read (noted).
    private func read() -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            // Perhaps for now only (protected data before the first unlock): never written
            // over in this run, so what it holds is there for the next.
            failures.withLock { $0.read = true; $0.io = true }
            onError(error)
            return nil
        }
    }

    /// Called with what the file holds once it can be read after an I/O error, on the
    /// file's queue, before any write: the owner merges it with what changed meanwhile.
    func onRecovered(_ body: @escaping @Sendable (Data?) -> Void) {
        recovered.withLock { $0 = body }
    }

    /// Tries again to read a file that failed with an I/O error, at most every 2 seconds,
    /// off the caller's thread. Once it can be read, its owner is told and writes resume.
    func retryIfUnreadable() {
        guard failures.current.io else { return }
        let due = lastRetry.withLock { last -> Bool in
            let now = Date()
            if let last, now.timeIntervalSince(last) < Self.retryEvery { return false }
            last = now
            return true
        }
        guard due else { return }
        queue.async { [self] in readAgain() }
    }

    /// As ``retryIfUnreadable()``, now, waiting for it. Never on the app's own thread.
    func retryNowIfUnreadable() {
        guard failures.current.io else { return }
        queue.sync { readAgain() }
    }

    /// On the queue.
    private func readAgain() {
        guard failures.current.io else { return }
        let data: Data?
        if FileManager.default.fileExists(atPath: url.path) {
            guard let read = try? Data(contentsOf: url) else { return }
            data = read
        } else {
            data = nil
        }
        if let recovered = recovered.current {
            // The owner merges, then marks it readable under its own lock.
            recovered(data)
        } else {
            markReadable()
        }
    }

    /// Writes resume. Called by the owner as it merges what the file holds, under the lock
    /// its changes take, so no change falls between the merge and this.
    func markReadable() {
        failures.withLock { $0 = (read: false, write: $0.write, io: false) }
    }

    /// The contents read couldn't be decoded.
    func noteUnreadable() {
        failures.withLock { $0.read = true }
    }

    /// Writes at once. Only from a `readNow` or `readSoon` body, which runs on the queue, so
    /// it lands before anything read or written after.
    func writeNow(_ data: Data) {
        do {
            try Self.prepareDirectory(url.deletingLastPathComponent())
            try data.write(to: url, options: [.atomic])
            failures.withLock { $0.write = false }
        } catch {
            failures.withLock { $0.write = true }
            onError(error)
        }
    }

    /// Writes what `contents` encodes, soon. Call it with a snapshot of the state.
    func write(_ contents: @escaping Contents) {
        if failures.current.io {
            failures.withLock { $0.write = true }
            retryIfUnreadable()
            return
        }
        let scheduled = pending.withLock { pending -> Bool in
            defer { pending = contents }
            return pending != nil
        }
        if scheduled { return }
        let wait = lastWrite.current + writeSpacing - ProcessInfo.processInfo.systemUptime
        if wait > 0 {
            queue.asyncAfter(deadline: .now() + wait) { [self] in writePending() }
        } else {
            queue.async { [self] in writePending() }
        }
    }

    /// On the queue: writes the latest state asked for, if a write is pending.
    private func writePending() {
        guard let latest = pending.take() else { return }
        lastWrite.withLock { $0 = ProcessInfo.processInfo.systemUptime }
        let data: Data?
        do {
            data = try latest()
        } catch {
            // The change isn't saved: the file keeps the state before it.
            failures.withLock { $0.write = true }
            onError(error)
            return
        }
        if let data {
            writeNow(data)
        } else if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
                failures.withLock { $0.write = false }
            } catch {
                failures.withLock { $0.write = true }
                onError(error)
            }
        }
    }

    /// Waits for writes already asked for. Never on the app's own thread.
    func waitForWrites() {
        queue.sync { Self.writeHeldBack(url.path) }
    }

    /// As ``waitForWrites()``, from async code (before the app is suspended, say): no thread
    /// is held while the writes run.
    func writesDone() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                Self.writeHeldBack(url.path)
                done.resume()
            }
        }
    }

    /// Makes the directory, left out of iCloud and iTunes backups so a restored phone gets
    /// a `device.id` of its own.
    private static func prepareDirectory(_ directory: URL) throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = directory
        try directory.setResourceValues(values)
    }
}

/// A reference that doesn't keep its object alive.
private final class Weak<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?
    init(_ value: Value) { self.value = value }
}

/// One instance per file in the process, while any client holds it: each instance keeps the
/// whole file in memory and writes it whole, so two would overwrite each other's changes.
final class SharedPerFile<Value: AnyObject>: @unchecked Sendable {
    private let instances = Locked<[String: Weak<Value>]>([:])

    func instance(for url: URL, make: () -> Value) -> Value {
        instances.withLock { instances in
            if let existing = instances[url.path]?.value { return existing }
            let made = make()
            instances[url.path] = Weak(made)
            return made
        }
    }
}

/// The SDK's small values, kept in memory and written to one JSON file. The file is read in
/// the background as the client starts; a value asked for before that has finished waits for
/// it (a few hundred bytes).
final class FileKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let file: PersistentFile
    private let values = Locked<[String: String]?>(nil)
    /// Keys changed while the file couldn't be read, with their latest values (nil when
    /// removed), to merge with what it holds once it can be.
    private let changedWhileUnreadable = Locked<[String: String?]>([:])

    private static let shared = SharedPerFile<FileKeyValueStore>()

    /// The store for `file`, shared by every client in the process.
    static func shared(file: PersistentFile) -> FileKeyValueStore {
        shared.instance(for: file.url) { FileKeyValueStore(file: file) }
    }

    init(file: PersistentFile) {
        self.file = file
        file.onRecovered { [weak self] data in self?.recover(data) }
        file.readSoon { data in self.load(data) }
    }

    func string(_ key: String) -> String? {
        loadIfNeeded()
        file.retryIfUnreadable()
        return values.withLock { $0?[key] }
    }

    func set(_ value: String?, for key: String) {
        loadIfNeeded()
        values.withLock { values in
            guard values?[key] != value else { return }
            store(value, for: key, in: &values)
        }
    }

    func string(_ key: String, orSet make: () -> String) -> String {
        loadIfNeeded()
        file.retryIfUnreadable()
        return values.withLock { values in
            if let existing = values?[key] { return existing }
            let value = make()
            store(value, for: key, in: &values)
            return value
        }
    }

    /// Under `values`' lock: changes `key`, notes it if the file can't be read yet, and
    /// writes soon.
    private func store(_ value: String?, for key: String, in values: inout [String: String]?) {
        values?[key] = value
        if file.unreadable { changedWhileUnreadable.withLock { $0[key] = .some(value) } }
        persist()
    }

    private func loadIfNeeded() {
        if values.withLock({ $0 == nil }) { file.readNow { load($0) } }
    }

    var writeFailed: Bool { file.writeFailed }
    func isReadable() -> Bool {
        file.retryNowIfUnreadable()
        return !file.unreadable
    }

    /// On the file's queue, once a file that couldn't be read (before the first unlock) can
    /// be: what it holds is the base, as nothing was written over it. The user's own choices
    /// made meanwhile, and a newer APNs token, win over it; anything else the SDK made
    /// meanwhile (a device id, a visit) gives way to what was saved, so the device keeps its
    /// id. The "couldn't be read" marker goes, unless the file itself has it.
    private func recover(_ data: Data?) {
        var saved: [String: String] = [:]
        if let data {
            guard let decoded = try? JSONDecoder().decode([String: String].self, from: data) else {
                // Not a passing problem: as a file that can't be decoded at launch.
                values.withLock { _ in
                    changedWhileUnreadable.withLock { $0 = [:] }
                    file.markReadable()
                    file.noteUnreadable()
                }
                persist()
                return
            }
            saved = decoded
        }
        values.withLock { values in
            // Taken under the lock `set` records changes under, so none is missed.
            let changes = changedWhileUnreadable.withLock { changes in
                defer { changes = [:] }
                return changes
            }
            var merged = saved
            // A removal always stands (a device id forgotten at a refusal, say); a value set
            // stands over a saved one only for the user's own choices.
            for (key, value) in changes
            where value == nil || StorageKeys.userChoices.contains(StorageKeys.base(of: key)) || merged[key] == nil {
                merged[key] = value
            }
            values = merged
            file.markReadable()
        }
        persist()
    }

    /// Encoded as they stand when the write runs, so a burst of changes is one write.
    private func persist() {
        file.write { try JSONEncoder().encode(self.values.withLock { $0 } ?? [:]) }
    }

    /// On the file's queue. What can't be read is marked, so a consent answer it may have
    /// held is asked for again rather than assumed.
    private func load(_ data: Data?) {
        var decoded: [String: String] = [:]
        if let data {
            if let values = try? JSONDecoder().decode([String: String].self, from: data) {
                decoded = values
            } else {
                file.noteUnreadable()
            }
        }
        if file.readFailed { decoded = [StorageKeys.stateUnreadable: "1"] }
        values.withLock { values in
            if values == nil { values = decoded }
        }
    }
}

/// One workspace's view of the app's store: the keys in ``StorageKeys/scoped`` are kept
/// apart per workspace and API deployment, the rest are shared.
final class WorkspaceStore: KeyValueStore, @unchecked Sendable {
    private let base: KeyValueStore
    /// Each scoped key as kept for this workspace, made once.
    private let scopedKeys: [String: String]

    init(base: KeyValueStore, namespace: String) {
        self.base = base
        scopedKeys = Dictionary(uniqueKeysWithValues: StorageKeys.scoped.map { ($0, StorageKeys.scoped($0, namespace)) })
    }

    func string(_ key: String) -> String? {
        base.string(self.key(key))
    }

    func set(_ value: String?, for key: String) {
        base.set(value, for: self.key(key))
    }

    func string(_ key: String, orSet make: () -> String) -> String {
        base.string(self.key(key), orSet: make)
    }

    private func key(_ key: String) -> String {
        scopedKeys[key] ?? key
    }

    var writeFailed: Bool { base.writeFailed }
    func isReadable() -> Bool { base.isReadable() }
}

/// For tests, and for a client whose storage failed.
final class MemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let values = Locked<[String: String]>([:])

    init() {}

    /// For tests of storage that fails to save.
    let failures = Locked(false)
    /// For tests of storage that can't be read yet.
    let unreadableNow = Locked(false)
    func isReadable() -> Bool { !unreadableNow.current }

    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    func string(_ key: String, orSet make: () -> String) -> String {
        values.withLock { values in
            if let existing = values[key] { return existing }
            let value = make()
            values[key] = value
            return value
        }
    }
    var writeFailed: Bool { failures.current }
    /// Every key stored, for tests that check what the SDK keeps.
    var keys: Set<String> { values.withLock { Set($0.keys) } }
}

/// A marketing push choice Kirora accepted, and the user (token subject) who made it.
struct RecordedPushConsent: Codable, Equatable {
    var user: String
    var granted: Bool
}
