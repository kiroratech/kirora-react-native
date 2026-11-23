import Foundation

/// What the React Native and Flutter SDKs need from this one, as `sdk-interface.md`, "Wrapper
/// SDKs", lists it. Not for apps: a wrapper's native module opts in with
/// `@_spi(Wrapper) import Kirora`.
///
/// Everything else a wrapper exposes is the public interface (``Kirora``, ``KiroraOptions``),
/// with two differences the wrapper handles itself:
///
/// - `beforeSend` runs in the wrapper's language, on the events the app tracks, before they
///   are forwarded here. The SDK's automatic events (`Session Started`, the `Application …`
///   events) carry no app-supplied values and don't pass through it.
/// - `fetchUserToken` is answered across the bridge: use ``TokenRequests``.
@_spi(Wrapper)
public enum KiroraWrapper {
    /// Sends `Kirora-SDK: <name>/<version>` (`kirora-react-native/1.0.0`) instead of this
    /// SDK's own name, so Kirora knows which SDK the app uses. Call it once, before creating
    /// the client. A name Kirora doesn't know, or a version it would refuse (other than 1 to
    /// 40 of `0-9 A-Z a-z . + -`), is ignored and logged: Kirora would refuse every call.
    public static func setSDK(name: String, version: String) {
        guard let header = sdkHeaderValue(name: name, version: version) else {
            Log(level: .error).error("setSDK ignored: expected kirora-react-native or kirora-flutter, and a version of 1 to 40 of 0-9 A-Z a-z . + -")
            return
        }
        sdkHeader.withLock { $0 = header }
    }

    /// Hooks the SDK into the app's push callbacks (the APNs token, taps, foreground display)
    /// before any client exists, as creating a client otherwise does. A wrapper's client is
    /// created from JavaScript or Dart, after launch, too late for the tap that launched the
    /// app: iOS hands it to the notification center's delegate as launching finishes, once.
    ///
    /// Call it at launch from the wrapper's native code: a Flutter plugin's `register(with:)`,
    /// or, for React Native, an Objective-C `+load` that calls the module's Swift. Safe from
    /// `+load`, before the app exists, from any thread, and more than once; creating the
    /// client afterwards installs nothing twice. Does nothing if the app set
    /// `KiroraAppDelegateProxyEnabled` to `NO`: it then forwards the callbacks itself.
    ///
    /// A tap heard before the client exists is reported to Kirora at once (the report needs
    /// no client) and held for the tap listener.
    public static func installPushIntegration() {
        launchLinks.arm()
        #if canImport(UIKit) && !os(watchOS)
        PushIntegration.installAtLaunch(log: Log(level: .error))
        #endif
    }

    /// The wrapper's language went away while the app goes on (a Flutter engine torn down,
    /// a React Native bridge invalidated): its tap listener, deep-link and foreground
    /// handlers are forgotten, taps are held again, and a tap's link waits again, up to 10
    /// seconds, for the next ``setDeepLinkHandler(_:)``, as at launch. Unlike
    /// `setDeepLinkHandler(nil)`, which means "set up, with no handler", so links open at
    /// once.
    public static func wrapperDetached() {
        pushTapEvents.setListener(nil)
        wrapperCallbacks.withLock { $0 = WrapperCallbacks() }
        launchLinks.unsettle()
    }

    /// Hears taps on Kirora pushes and their buttons, after the SDK has reported the tap and
    /// opened its link. Taps from before a listener is attached (one that launched the app),
    /// the latest ten, are delivered to it at once, in order. Called on any thread. `nil`
    /// detaches it; taps are then held again.
    public static func setTapListener(_ listener: (@Sendable (KiroraPushTap) -> Void)?) {
        pushTapEvents.setListener(listener)
    }

    /// Asks the app, across the bridge, whether it opened a tapped push's link itself, as
    /// ``KiroraOptions/handleDeepLink`` does natively. Answered within 1.5 seconds, or the
    /// SDK opens the link as if there were no handler. The native `handleDeepLink`, if set,
    /// is asked first.
    ///
    /// After ``installPushIntegration()``, the link of a tap heard before the first call
    /// (the tap that launched the app) waits for it, with a handler or with nil, up to 10
    /// seconds, so the app's own routing is listening when the link is opened. Call it once
    /// the wrapper's language is ready, with nil if the app has no handler.
    public static func setDeepLinkHandler(_ handler: (@Sendable (URL) async -> Bool)?) {
        wrapperCallbacks.withLock { $0.deepLink = handler }
        launchLinks.settle()
    }

    /// Asks the app, across the bridge, whether to show a Kirora push that arrives while the
    /// app is open, with the push's data. Answered within 1.5 seconds, or it's shown, as with
    /// no handler. An app's own notification delegate implementing `willPresent` still
    /// decides first.
    public static func setForegroundPresentationHandler(_ handler: (@Sendable ([String: Any]) async -> Bool)?) {
        wrapperCallbacks.withLock { $0.foreground = handler }
    }

    /// `fetchUserToken` answered across the bridge. Pass ``fetchUserToken()`` as the option;
    /// each request gets an id, sent to the wrapper's language by `onRequest`, which answers
    /// with ``answer(_:token:)`` or ``fail(_:message:)``. The 30-second limit covers the
    /// whole round trip: a request still unanswered then fails, and an answer for it, or for
    /// a request the SDK no longer waits for (an earlier user's), is discarded.
    public final class TokenRequests: @unchecked Sendable {
        private let onRequest: @Sendable (String) -> Void
        private let timeout: Double
        /// Each request waited for, with its timer, stopped once it's answered.
        private let pending = Locked<[String: (answer: CheckedContinuation<String?, Error>, timer: Task<Void, Never>?)]>([:])

        public convenience init(onRequest: @escaping @Sendable (_ requestId: String) -> Void) {
            self.init(timeout: 30, onRequest: onRequest)
        }

        init(timeout: Double, onRequest: @escaping @Sendable (String) -> Void) {
            self.onRequest = onRequest
            self.timeout = timeout
        }

        /// Pass as ``KiroraOptions/fetchUserToken``.
        public func fetchUserToken() async throws -> String? {
            let id = newId()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    pending.withLock { $0[id] = (continuation, nil) }
                    // Cancelled before it was waiting: the handler found nothing to end.
                    if Task.isCancelled {
                        end(id, with: .failure(CancellationError()))
                        return
                    }
                    onRequest(id)
                    let timeout = self.timeout
                    let timer = Task { [weak self] in
                        await sleep(seconds: timeout)
                        guard !Task.isCancelled else { return }
                        self?.end(id, with: .failure(WrapperError("fetchUserToken got no answer within \(Int(timeout)) seconds")))
                    }
                    pending.withLock { if $0[id] != nil { $0[id]?.timer = timer } else { timer.cancel() } }
                }
            } onCancel: {
                end(id, with: .failure(CancellationError()))
            }
        }

        /// The wrapper's answer to request `requestId`: `nil` or empty when the app gave no
        /// token, a failed fetch. Discarded if it's no longer waited for.
        public func answer(_ requestId: String, token: String?) {
            end(requestId, with: .success(token))
        }

        /// The app's `fetchUserToken` failed. Discarded if it's no longer waited for.
        public func fail(_ requestId: String, message: String) {
            end(requestId, with: .failure(WrapperError(message)))
        }

        /// Whether `requestId` is still waited for, for tests.
        func isPending(_ requestId: String) -> Bool { pending.withLock { $0[requestId] != nil } }

        private func end(_ id: String, with result: Result<String?, Error>) {
            guard let request = pending.withLock({ $0.removeValue(forKey: id) }) else { return }
            request.timer?.cancel()
            request.answer.resume(with: result)
        }
    }
}

/// An error a wrapper reported, or a bridge that didn't answer.
struct WrapperError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// What the wrapper attached. Taps and links reach the SDK through iOS, not a client, so
/// these are process-wide, as `deepLinkHandler` is.
struct WrapperCallbacks {
    var deepLink: (@Sendable (URL) async -> Bool)?
    var foreground: (@Sendable ([String: Any]) async -> Bool)?
}

let wrapperCallbacks = Locked(WrapperCallbacks())

/// The link of a tap heard before the wrapper set up its deep-link handler: in practice, the
/// tap that launched the app, heard long before JavaScript or Dart run. Opened at once, the
/// link would be lost: React Native's `Linking` isn't listening yet, and `getInitialURL`
/// only knows the launch URL. So it waits for the wrapper's `setDeepLinkHandler` (with a
/// handler or nil), then goes the usual way. Only for a wrapper that called
/// `installPushIntegration()`; a native app's links open as they always have.
///
/// The latest such link only: one tapped while another waits takes its place, and the first
/// is not opened. If the wrapper never sets up its handler, the link is opened after
/// ``limit``, as if there were no wrapper.
final class LaunchLinks: @unchecked Sendable {
    static let limit: Double = 10

    private struct State {
        /// A wrapper installed the push integration: it will set up its handler.
        var armed = false
        /// The wrapper has set up its handler, with one or nil.
        var settled = false
        var waiting: (id: Int, resume: CheckedContinuation<Bool, Never>)?
        var nextId = 0
    }

    private let state = Locked(State())

    func arm() { state.withLock { $0.armed = true } }

    /// The wrapper went away: links wait for its next `setDeepLinkHandler`, as at launch.
    func unsettle() { state.withLock { $0.settled = false } }

    /// The wrapper called `setDeepLinkHandler`: a waiting link goes on.
    func settle() {
        state.withLock { $0.settled = true }
        takeWaiting()?.resume(returning: true)
    }

    /// The link waiting, if any, taken out; only if it's the one `id` names, when given.
    private func takeWaiting(id: Int? = nil) -> CheckedContinuation<Bool, Never>? {
        state.withLock { state in
            guard let waiting = state.waiting, id == nil || waiting.id == id else { return nil }
            state.waiting = nil
            return waiting.resume
        }
    }

    /// Whether a link should be opened: at once if there's nothing to wait for; otherwise
    /// once the wrapper has set up its handler, or after `limit`. False if a later link took
    /// its place while it waited.
    func proceed(limit: Double = LaunchLinks.limit) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = state.withLock { state -> Int? in
                guard state.armed, !state.settled else { return nil }
                state.waiting?.resume.resume(returning: false)
                state.nextId += 1
                state.waiting = (state.nextId, continuation)
                return state.nextId
            }
            guard let id else { return continuation.resume(returning: true) }
            Task {
                await sleep(seconds: limit)
                self.takeWaiting(id: id)?.resume(returning: true)
            }
        }
    }
}

let launchLinks = LaunchLinks()

/// How long the SDK waits for a wrapper's answer before acting as if it had no callback.
let wrapperCallbackTimeout: Double = 1.5

/// Asks the wrapper whether it opened `url` itself. False when there's no handler, or no
/// answer in time.
func wrapperOpenedLink(_ url: URL, timeout: Double = wrapperCallbackTimeout) async -> Bool {
    guard let handler = wrapperCallbacks.current.deepLink else { return false }
    return (try? await withTimeout(seconds: timeout) { await handler(url) }) ?? false
}

/// Asks the wrapper whether to show a push in the foreground. True when there's no handler,
/// or no answer in time.
func wrapperShowsInForeground(_ data: [String: Any], timeout: Double = wrapperCallbackTimeout) async -> Bool {
    guard let handler = wrapperCallbacks.current.foreground else { return true }
    let payload = UncheckedSendable(data)
    return (try? await withTimeout(seconds: timeout) { await handler(payload.value) }) ?? true
}

/// A push's data as JSON values, for the wrapper: string keys only, anything JSON can't hold
/// left out.
func wrapperData(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
    var data: [String: Any] = [:]
    for (key, value) in userInfo {
        guard let key = key.base as? String, let json = try? JSONValue.from(value) else { continue }
        data[key] = json.foundationValue
    }
    return data
}

/// The `Kirora-SDK` header: this SDK's own, or the wrapper's.
let sdkHeader = Locked("kirora-ios/\(sdkVersion)")

/// `Kirora-SDK` for a wrapper, or nil if the name or version isn't one.
func sdkHeaderValue(name: String, version: String) -> String? {
    wrapperSDKNames.contains(name) && isValidVersion(version) ? "\(name)/\(version)" : nil
}

/// The SDK names Kirora accepts in `Kirora-SDK` from a wrapper.
private let wrapperSDKNames: Set<String> = ["kirora-react-native", "kirora-flutter"]

/// Kirora's own rule for the version (`[0-9A-Za-z.+-]{1,40}`): anything else is refused with
/// a 400 on every call.
func isValidVersion(_ version: String) -> Bool {
    (1...40).contains(version.utf8.count)
        && version.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "0"..."9", "A"..."Z", "a"..."z", ".", "+", "-": return true
            default: return false
            }
        }
}

/// A value passed across threads that is safe to, though its type doesn't say so: one the
/// SDK copied and won't touch again, or one documented as thread-safe.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
