import Foundation
import os.log

/// The version sent in `Kirora-SDK`. Bumped on release.
let sdkVersion = "0.1.0"
/// What `Kirora-SDK` says: this SDK, or a wrapper that set its own (``KiroraWrapper/setSDK(name:version:)``).
var sdkName: String { sdkHeader.current }

/// A value guarded by a lock, for state shared across threads.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

extension Locked where Value == Bool {
    /// Sets the flag; true only for the first caller. For "once" and "the first answer wins".
    func claimOnce() -> Bool {
        withLock { claimed in
            defer { claimed = true }
            return !claimed
        }
    }
}

extension Locked {
    /// Takes the optional value out, leaving nil.
    func take<Wrapped>() -> Wrapped? where Value == Wrapped? {
        withLock { value in
            defer { value = nil }
            return value
        }
    }
}

/// Doubling retry delays, as every Kirora SDK retries: from the first gap up to the most,
/// with ±10% jitter so clients don't all retry at once, and never sooner than the server's
/// `Retry-After`. The SDK's own delay may be waived (a manual flush, coming back online);
/// the server's never is.
struct Backoff: Sendable {
    private let timing: DeliveryTiming
    private var delay: Double
    private var ownUntil = Date.distantPast
    private var serverUntil = Date.distantPast

    init(_ timing: DeliveryTiming) {
        self.timing = timing
        delay = timing.flushInterval
    }

    /// After a failure: returns when to try again.
    @discardableResult
    mutating func failed(_ error: Error?) -> Date {
        let now = Date()
        ownUntil = now.addingTimeInterval(delay * (1 - retryJitter + Double.random(in: 0..<(2 * retryJitter))))
        let retryAfter = error?.retryAfterSeconds ?? 0
        // Jitter only ever adds to the server's delay, so throttled clients spread out.
        serverUntil = retryAfter > 0
            ? now.addingTimeInterval(retryAfter * (1 + Double.random(in: 0..<retryJitter)))
            : .distantPast
        delay = min(delay * 2, timing.maxRetryDelay)
        return notBefore()
    }

    mutating func succeeded() {
        self = Backoff(timing)
    }

    /// No try before this. Waiving the SDK's own delay leaves only the server's.
    func notBefore(waivingOwnDelay: Bool = false) -> Date {
        waivingOwnDelay ? serverUntil : max(ownUntil, serverUntil)
    }
}

/// Retry delays vary by this fraction.
private let retryJitter = 0.1

extension Error {
    /// The server's `Retry-After`, in seconds, or 0.
    var retryAfterSeconds: Double {
        Double((self as? KiroraApiError)?.retryAfterMs ?? 0) / 1000
    }
}

/// Logs to the unified log under `io.kirora.sdk`, at or below the app's chosen level.
struct Log: Sendable {
    let level: LogLevel
    private static let osLog = OSLog(subsystem: "io.kirora.sdk", category: "Kirora")

    // Messages are built only if they'll be written: `debug` is off by default, and some
    // are built on the app's thread.
    func error(_ message: @autoclosure () -> String, _ error: Error? = nil) {
        write(.error, message, error)
    }

    func debug(_ message: @autoclosure () -> String) {
        write(.debug, message, nil)
    }

    private func write(_ messageLevel: LogLevel, _ message: () -> String, _ error: Error?) {
        guard messageLevel <= level else { return }
        let text = error.map { "Kirora: \(message()): \($0)" } ?? "Kirora: \(message())"
        os_log("%{public}@", log: Self.osLog, type: messageLevel == .error ? .error : .debug, text)
    }
}

/// What a hung callback or call counts as after its time is up.
struct TimeoutError: Error, CustomStringConvertible {
    var description: String { "timed out" }
}

/// Runs `operation`, giving up after `seconds`. Unlike a task group, it doesn't wait for
/// an operation that ignores cancellation: it answers at the timeout and lets it go.
func withTimeout<Value: Sendable>(
    seconds: Double,
    _ operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        let answered = Locked(false)
        let answer: @Sendable (Result<Value, Error>) -> Bool = { result in
            let first = answered.claimOnce()
            if first { continuation.resume(with: result) }
            return first
        }
        let timer = Locked<Task<Void, Never>?>(nil)
        let work = Task {
            let result: Result<Value, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            // Answered in time: the timer has nothing left to do.
            if answer(result) { timer.take()?.cancel() }
        }
        timer.withLock { stored in
            stored = Task {
                await sleep(seconds: seconds)
                if answer(.failure(TimeoutError())) { work.cancel() }
            }
        }
        // Answered while the timer was being set: it has nothing left to do.
        if answered.current { timer.take()?.cancel() }
    }
}

/// Asks someone who should call `answer` once, such as an app's delegate, which may never
/// call it: if it hasn't within `timeout`, `fallback` answers instead. Whichever is first
/// reaches `answer`; the other is ignored. No wait if `ask` answers at once. The callback
/// form of ``withTimeout(seconds:_:)``, for APIs that answer through a handler.
func askWithFallback<Value: Sendable>(
    timeout: Double,
    answer: @escaping @Sendable (Value) -> Void,
    ask: (@escaping @Sendable (Value) -> Void) -> Void,
    fallback: @escaping @Sendable (@escaping @Sendable (Value) -> Void) -> Void
) {
    let answered = Locked(false)
    let timer = Locked<Task<Void, Never>?>(nil)
    let once: @Sendable (Value) -> Void = { value in
        guard answered.claimOnce() else { return }
        timer.take()?.cancel()
        answer(value)
    }
    ask(once)
    if answered.current { return }
    timer.withLock { stored in
        stored = Task {
            await sleep(seconds: timeout)
            if !Task.isCancelled { fallback(once) }
        }
    }
    // Answered while the timer was being set: it has nothing left to do.
    if answered.current { timer.take()?.cancel() }
}

/// Opened once; until then, callers wait for it, each up to its own limit.
/// Runs operations one at a time, each after the one before it has finished (or failed).
final class InTurn: @unchecked Sendable {
    private let last = Locked<Task<Void, Never>?>(nil)

    func run(_ operation: @escaping @Sendable () async throws -> Void) async throws {
        let mine: Task<Void, Error> = last.withLock { last in
            let previous = last
            let task = Task {
                await previous?.value
                try await operation()
            }
            last = Task { _ = try? await task.value }
            return task
        }
        try await mine.value
    }

    /// Waits for the operations asked for so far.
    func done() async { await last.current?.value }
}

final class Gate: @unchecked Sendable {
    private let state = Locked<(open: Bool, waiting: [UUID: CheckedContinuation<Void, Never>])>((false, [:]))

    /// Lets every waiter go, and any later one through at once.
    func open() {
        let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.open = true
            defer { state.waiting = [:] }
            return Array(state.waiting.values)
        }
        waiting.forEach { $0.resume() }
    }

    /// Returns once open, or after `seconds`, whichever is first.
    func wait(upTo seconds: Double) async {
        let id = UUID()
        let timer = Locked<Task<Void, Never>?>(nil)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waits = state.withLock { state -> Bool in
                guard !state.open else { return false }
                state.waiting[id] = continuation
                return true
            }
            guard waits else { return continuation.resume() }
            timer.withLock { stored in
                stored = Task {
                    await sleep(seconds: seconds)
                    // Still waiting: resumed here, unless open() just took it.
                    self.state.withLock { $0.waiting.removeValue(forKey: id) }?.resume()
                }
            }
        }
        timer.take()?.cancel()
    }
}

/// The longest the SDK ever waits in one go: a week. A longer wait, such as an absurd
/// `Retry-After`, is cut to it; a retry is then tried, and refused again if still too early.
let maxWaitSeconds: Double = 7 * 24 * 60 * 60

/// Sleeps for `seconds`, whatever the value: negative or NaN is no wait, and anything past
/// ``maxWaitSeconds`` (infinity included) is cut to it, so converting it never traps.
func sleep(seconds: Double) async {
    let wait = seconds.isNaN ? 0 : min(max(seconds, 0), maxWaitSeconds)
    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
}

/// ISO 8601 with milliseconds, in UTC, as Kirora's API takes times.
func isoTimestamp(_ date: Date) -> String {
    isoFormatter.withLock { $0.string(from: date) }
}

func parseIsoTimestamp(_ value: String) -> Date? {
    isoFormatter.withLock { $0.date(from: value) }
}

private let isoFormatter: Locked<ISO8601DateFormatter> = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return Locked(formatter)
}()

/// Milliseconds since 1970, as stored timestamps are kept.
func epochMs(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }

/// The lowercase UUID string the web SDK uses too, so ids look alike across platforms.
func newId() -> String { UUID().uuidString.lowercased() }
