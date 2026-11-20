import Foundation
import React
@_spi(Wrapper) import Kirora

/// Hands the JavaScript `Kirora` class to the native Kirora iOS SDK, with the same methods and
/// events as the Android module, so `NativeBackend` drives both. The SDK does the work; this
/// only forwards calls and carries the app's answers back:
///
/// - `fetchUserToken`: the SDK asks with a `KiroraTokenRequest` event; the answer comes back
///   through `resolveToken`. Late or stale answers are discarded by the SDK.
/// - `handleDeepLink` and `onForegroundNotification`: asked with an event and answered through
///   `resolveAnswer`. With no answer in 1.5 s the SDK acts as if there
///   were no callback.
/// - Taps: the SDK reports them itself, then hands them to the tap listener, which sends
///   `KiroraNotificationClicked` while JavaScript listens. Taps from before that are held by
///   the SDK (the latest ten) and delivered when it does.
///
/// `beforeSend` runs in JavaScript before `track` is called; the APNs token and the push
/// callbacks reach the SDK by themselves (see `KiroraSdkLaunch`).
@objc(KiroraSdk)
final class KiroraSdkModule: RCTEventEmitter, @unchecked Sendable {
    static let tokenRequestEvent = "KiroraTokenRequest"
    static let foregroundEvent = "KiroraForegroundNotification"
    static let deepLinkEvent = "KiroraDeepLink"
    static let clickedEvent = "KiroraNotificationClicked"
    static let receivedEvent = "KiroraNotificationReceived"
    static let authenticationFailedEvent = "KiroraAuthenticationFailed"
    /// The SDK stops waiting after this too; answers after it are dropped.
    static let callbackTimeout: TimeInterval = 1.5

    private let lock = NSLock()
    private var kirora: Kirora?
    private var listening = false
    private var clicksOn = false
    /// Asks waiting for JavaScript's answer: whether a link was opened, or a push is shown.
    private var pending: [String: (answer: CheckedContinuation<Bool, Never>, fallback: Bool)] = [:]

    /// One for the module's life, so a token request survives a new `configure`.
    private lazy var tokenRequests = KiroraWrapper.TokenRequests { [weak self] requestId in
        self?.requestToken(requestId)
    }

    @objc static func requiresMainQueueSetup() -> Bool { false }

    override func supportedEvents() -> [String]! {
        [Self.tokenRequestEvent, Self.foregroundEvent, Self.deepLinkEvent, Self.clickedEvent, Self.receivedEvent,
         Self.authenticationFailedEvent]
    }

    override func startObserving() { locked { listening = true } }
    override func stopObserving() { locked { listening = false } }

    override func invalidate() {
        takeKirora()?.destroy()
        // Not "set up with no handler": the next JavaScript context may set one, so taps are held
        // and a tap's link waits for it again (10 s at most) instead of opening at once.
        KiroraWrapper.wrapperDetached()
        locked { clicksOn = false }
        locked { () -> [(answer: CheckedContinuation<Bool, Never>, fallback: Bool)] in
            defer { pending = [:] }
            return Array(pending.values)
        }.forEach { $0.answer.resume(returning: $0.fallback) }
        super.invalidate()
    }

    // MARK: - Setup

    @objc(configure:resolver:rejecter:)
    func configure(_ options: NSDictionary, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        let string = { (key: String) in options[key] as? String }
        let flag = { (key: String) in (options[key] as? Bool) ?? false }

        if let version = string("sdkVersion") {
            KiroraWrapper.setSDK(name: "kirora-react-native", version: version)
        }
        let requests = tokenRequests
        let push: PushOptions? = flag("push") ? PushOptions(pushAppId: string("pushAppId")) : nil
        var fetchUserToken: (@Sendable () async throws -> String)?
        if flag("hasTokenProvider") {
            fetchUserToken = { try await requests.fetchUserToken() }
        }
        var onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)?
        if flag("hasAuthenticationFailedHandler") {
            onAuthenticationFailed = { [weak self] reason in self?.authenticationFailed(reason) }
        }
        let kiroraOptions = KiroraOptions(
            clientKey: string("clientKey") ?? "",
            fetchUserToken: fetchUserToken,
            onAuthenticationFailed: onAuthenticationFailed,
            push: push,
            requireTrackingConsent: flag("requireTrackingConsent"),
            trackSessions: (options["trackSessions"] as? Bool) ?? true,
            trackAppLifecycle: flag("trackAppLifecycle"),
            logLevel: LogLevel(rawValue: string("logLevel") ?? "error") ?? .error,
            apiUrl: string("apiUrl") ?? "https://api.kirora.io"
        )
        // Process-wide in the SDK, like taps: they reach it through iOS, not a client.
        var deepLink: (@Sendable (URL) async -> Bool)?
        if flag("hasDeepLinkHandler") {
            deepLink = { [weak self] url in
                await self?.ask(Self.deepLinkEvent, ["url": url.absoluteString], fallback: false) ?? false
            }
        }
        KiroraWrapper.setDeepLinkHandler(deepLink)
        var foreground: (@Sendable ([String: Any]) async -> Bool)?
        if flag("hasForegroundHandler") {
            foreground = { [weak self] data in
                await self?.ask(Self.foregroundEvent, ["data": Self.notificationData(data)], fallback: true) ?? true
            }
        }
        KiroraWrapper.setForegroundPresentationHandler(foreground)

        // A new client starts with no notification events: its JavaScript turns on what it
        // listens for, so taps are held by the SDK until then, not sent to nobody.
        setNotificationEvents(false, received: false)
        let previous = locked { kirora }
        previous?.destroy()
        let created = Kirora(options: kiroraOptions)
        locked { kirora = created }
        // Whether tracking is allowed now, so JavaScript's beforeSend never sees an event it isn't allowed to.
        resolve(["trackingConsent": created.trackingConsent])
    }

    // MARK: - Methods

    @objc(identify:resolver:rejecter:)
    func identify(_ token: String?, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in
            try await kirora.identify(token.flatMap { $0.isEmpty ? nil : $0 })
            resolve(nil)
        }
    }

    @objc(logout:rejecter:)
    func logout(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in
            await kirora.logout()
            resolve(nil)
        }
    }

    @objc(track:propertiesJson:)
    func track(_ name: String, propertiesJson: String) {
        guard let kirora = current() else { return }
        // A JSON object from JavaScript, already through beforeSend there.
        let properties = propertiesJson.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        kirora.track(name, properties: properties ?? [:])
    }

    @objc(trackScreenView:)
    func trackScreenView(_ name: String) {
        current()?.trackScreenView(name)
    }

    @objc(setTrackingConsent:)
    func setTrackingConsent(_ granted: Bool) {
        current()?.setTrackingConsent(granted)
    }

    @objc(setPushConsent:resolver:rejecter:)
    func setPushConsent(_ granted: Bool, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in
            try await kirora.setPushConsent(granted)
            resolve(nil)
        }
    }

    @objc(requestPushPermission:rejecter:)
    func requestPushPermission(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in resolve(await kirora.requestPushPermission().rawValue) }
    }

    @objc(getPushStatus:rejecter:)
    func getPushStatus(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in resolve(await kirora.getPushStatus().rawValue) }
    }

    @objc(setPushEnabled:resolver:rejecter:)
    func setPushEnabled(_ enabled: Bool, resolver resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in
            await kirora.setPushEnabled(enabled)
            resolve(nil)
        }
    }

    @objc(flush:rejecter:)
    func flush(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        withKirora(reject) { kirora in
            await kirora.flush()
            resolve(nil)
        }
    }

    /// The SDK's snapshot, read on the device: no prompt, no network call.
    @objc(getState:rejecter:)
    func getState(_ resolve: @escaping RCTPromiseResolveBlock, rejecter reject: @escaping RCTPromiseRejectBlock) {
        // Null (the empty state, in JavaScript) before set-up or after destroy: never a rejection.
        guard let state = current()?.getState() else {
            resolve(nil)
            return
        }
        resolve([
            "isInitialized": state.isInitialized,
            "isIdentified": state.isIdentified,
            "deviceId": state.deviceId ?? NSNull(),
            "sessionId": state.sessionId ?? NSNull(),
            "pushToken": state.pushToken ?? NSNull(),
            "trackingConsent": state.trackingConsent,
            "pushConsent": state.pushConsent,
            "queuedEventCount": state.queuedEventCount,
        ] as [String: Any])
    }

    @objc func destroy() {
        takeKirora()?.destroy()
        setNotificationEvents(false, received: false)
        // Nothing to ask any more: pushes show and links open at once, as without callbacks.
        KiroraWrapper.setDeepLinkHandler(nil)
        KiroraWrapper.setForegroundPresentationHandler(nil)
    }

    /// The SDK reads the APNs token itself.
    @objc(onNewPushToken:)
    func onNewPushToken(_ token: String) {}

    // MARK: - Answers from JavaScript

    @objc(resolveToken:token:error:)
    func resolveToken(_ requestId: String, token: String?, error: String?) {
        if let token, !token.isEmpty, error == nil {
            tokenRequests.answer(requestId, token: token)
        } else {
            tokenRequests.fail(requestId, message: error ?? "fetchUserToken returned no token")
        }
    }

    /// Answers an `ask`: whether a link was opened, or a push is shown.
    @objc(resolveAnswer:answer:)
    func resolveAnswer(_ requestId: String, answer value: Bool) {
        answer(requestId, value)
    }

    /// Starts or stops `KiroraNotificationClicked`. Attaching delivers the taps the SDK held,
    /// the one that launched the app among them. iOS has no received event: a push the app
    /// shows in the foreground is asked about through `onForegroundNotification` instead.
    @objc(setNotificationEvents:received:)
    func setNotificationEvents(_ clicked: Bool, received: Bool) {
        let changed = locked { () -> Bool in
            defer { clicksOn = clicked }
            return clicksOn != clicked
        }
        guard changed else { return }
        var listener: (@Sendable (KiroraPushTap) -> Void)?
        if clicked {
            listener = { [weak self] tap in self?.tapped(tap) }
        }
        KiroraWrapper.setTapListener(listener)
    }

    // MARK: - Internals

    private func authenticationFailed(_ reason: AuthenticationFailureReason) {
        guard locked({ listening }) else { return }
        sendEvent(withName: Self.authenticationFailedEvent, body: ["reason": reason.rawValue])
    }

    private func tapped(_ tap: KiroraPushTap) {
        guard locked({ listening }) else { return }
        sendEvent(withName: Self.clickedEvent, body: Self.notificationData(tap.data))
    }

    private func requestToken(_ requestId: String) {
        guard locked({ listening }) else {
            tokenRequests.fail(requestId, message: "No fetchUserToken is listening")
            return
        }
        sendEvent(withName: Self.tokenRequestEvent, body: ["requestId": requestId])
    }

    /// Sends `event` and waits for JavaScript's answer: `fallback` without one in 1.5 s, or
    /// when nothing listens.
    private func ask(_ event: String, _ body: [String: Any], fallback: Bool) async -> Bool {
        let requestId = UUID().uuidString
        return await withCheckedContinuation { continuation in
            let waiting = locked { () -> Bool in
                guard listening else { return false }
                pending[requestId] = (continuation, fallback)
                return true
            }
            guard waiting else {
                continuation.resume(returning: fallback)
                return
            }
            var payload = body
            payload["requestId"] = requestId
            // When this ask stops waiting: JavaScript doesn't run the app's callback after it,
            // since the fallback has acted by then (a link already opened, say).
            payload["expiresAt"] = (Date().timeIntervalSince1970 + Self.callbackTimeout) * 1000
            sendEvent(withName: event, body: payload)
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.callbackTimeout) { [weak self] in
                self?.answer(requestId, fallback)
            }
        }
    }

    private func answer(_ requestId: String, _ value: Bool) {
        locked { pending.removeValue(forKey: requestId) }?.answer.resume(returning: value)
    }

    private func current() -> Kirora? { locked { kirora } }

    /// Rejects with the codes `errorFromNative` (NativeBackend.ts) maps to the SDK's errors:
    /// `USER_TOKEN_ERROR`, `KIRORA_API_ERROR` with `status`, `code` and `retryAfterMs` in
    /// `userInfo`, and `KIRORA_ERROR` for a setup or network problem.
    static func reject(_ reject: RCTPromiseRejectBlock, _ error: Error) {
        switch error {
        case let error as UserTokenError:
            reject("USER_TOKEN_ERROR", error.description, error)
        case let error as KiroraApiError:
            let info: [String: Any] = [
                "status": error.status,
                "code": error.code ?? NSNull(),
                "retryAfterMs": error.retryAfterMs ?? NSNull(),
            ]
            reject("KIRORA_API_ERROR", error.message, NSError(domain: "io.kirora", code: error.status, userInfo: info))
        case let error as KiroraError:
            reject("KIRORA_ERROR", error.message, error)
        default:
            reject("KIRORA_ERROR", error.localizedDescription, error)
        }
    }

    /// Runs `work` with the client; what it throws rejects, mapped like `reject`.
    private func withKirora(_ reject: @escaping RCTPromiseRejectBlock, _ work: @escaping (Kirora) async throws -> Void) {
        guard let kirora = current() else {
            reject("NOT_CONFIGURED", "Kirora was not set up", nil)
            return
        }
        // React Native's promise blocks may be called from any thread once.
        let unchecked = UncheckedWork(work, reject)
        Task {
            do {
                try await unchecked.work(kirora)
            } catch {
                Self.reject(unchecked.reject, error)
            }
        }
    }

    /// The client, now no longer the module's.
    private func takeKirora() -> Kirora? {
        locked { () -> Kirora? in
            defer { kirora = nil }
            return kirora
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// A push's data as JavaScript's `NotificationData`: string values as they are, anything
    /// else as JSON text. `aps` is iOS's own and left out.
    static func notificationData(_ data: [String: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in data where key != "aps" {
            if let string = value as? String {
                out[key] = string
            } else if JSONSerialization.isValidJSONObject([value]),
                      let json = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
                      let text = String(data: json, encoding: .utf8) {
                out[key] = text
            }
        }
        return out
    }
}

/// Work holding React Native's promise blocks, which are safe to call from any thread though
/// their type doesn't say so.
private struct UncheckedWork: @unchecked Sendable {
    let work: (Kirora) async throws -> Void
    let reject: RCTPromiseRejectBlock
    init(_ work: @escaping (Kirora) async throws -> Void, _ reject: @escaping RCTPromiseRejectBlock) {
        self.work = work
        self.reject = reject
    }
}

/// Called from `+load` (KiroraSdkLaunch.m) to hook the SDK into the app's push callbacks
/// before JavaScript runs. Does nothing if the app set `KiroraAppDelegateProxyEnabled` to NO.
@objc(KiroraSdkLaunch)
final class KiroraSdkLaunch: NSObject {
    @objc static func install() {
        KiroraWrapper.installPushIntegration()
    }
}
