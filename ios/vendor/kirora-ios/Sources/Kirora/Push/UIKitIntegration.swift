#if canImport(UIKit) && !os(watchOS)
import Network
@preconcurrency import ObjectiveC
import UIKit
@preconcurrency import UserNotifications

// MARK: - Lifecycle

/// The app's lifecycle from UIKit's notifications, the network from `NWPathMonitor`.
final class UIKitLifecycle: AppLifecycleSource, @unchecked Sendable {
    private var observers: [NSObjectProtocol] = []
    private var keepAliveTimer: Timer?
    private var monitor: NWPathMonitor?
    private var launched = false
    /// Stopped, possibly before the main thread got to starting (a client made off the main
    /// thread and destroyed at once): starting then does nothing.
    private var stopped = false
    private var handler: (@Sendable (LifecycleEvent) -> Void)?

    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) {
        // Handled off the main thread, in order: handling may wait for the files' first read,
        // and UIKit calls from the main thread, at launch too. Going to the background, with
        // time from iOS to finish.
        let deliver: @Sendable (LifecycleEvent) -> Void = { event in
            guard event == .background else { return lifecycleQueue.async { handler(event) } }
            runWithBackgroundTime("Kirora background") {
                await withCheckedContinuation { done in
                    lifecycleQueue.async {
                        handler(event)
                        done.resume()
                    }
                }
            }
        }
        onMain { [self] in
            guard !stopped else { return }
            self.handler = deliver
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.enteredForeground() })
            observers.append(center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.enteredBackground() })
            // A scene-based app is still in the background while it finishes launching: its
            // first trip to the foreground is the launch.
            if UIApplication.shared.applicationState != .background { enteredForeground() }
            let monitor = NWPathMonitor()
            let wasOffline = Locked(false)
            monitor.pathUpdateHandler = { [weak self] path in
                let online = path.status == .satisfied
                let cameBack = wasOffline.withLock { wasOffline -> Bool in
                    defer { wasOffline = !online }
                    return online && wasOffline
                }
                // `handler` is only touched on the main thread.
                if cameBack { onMain { [weak self] in self?.handler?(.online) } }
            }
            monitor.start(queue: DispatchQueue(label: "io.kirora.sdk.network", qos: .utility))
            self.monitor = monitor
        }
    }

    func stop() {
        onMain { [self] in
            stopped = true
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            keepAliveTimer?.invalidate()
            keepAliveTimer = nil
            monitor?.cancel()
            monitor = nil
            handler = nil
        }
    }

    func runInBackground(_ name: String, _ work: @escaping @Sendable () async -> Void) {
        runWithBackgroundTime(name, work)
    }

    private func enteredForeground() {
        handler?(launched ? .foreground : .launched)
        launched = true
        keepAliveTimer?.invalidate()
        keepAliveTimer = Timer.scheduledTimer(withTimeInterval: sessionKeepAlive, repeats: true) { [weak self] _ in
            self?.handler?(.keepAlive)
        }
    }

    private func enteredBackground() {
        // Never seen in the foreground: launched in the background (e.g. for a silent push).
        guard launched else { return }
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
        handler?(.background)
    }
}

/// Reads the screen for event context, once, on the main thread: its portrait size in
/// points, which rotation doesn't change, and its scale.
func readDeviceScreen() {
    onMain {
        guard deviceScreen.current == nil else { return }
        let screen = UIScreen.main
        let bounds = screen.fixedCoordinateSpace.bounds
        deviceScreen.withLock {
            $0 = DeviceInfo.Screen(width: Int(bounds.width), height: Int(bounds.height), density: Double(screen.scale))
        }
    }
}

/// Where every client's lifecycle events are handled: one at a time, in order.
private let lifecycleQueue = DispatchQueue(label: "io.kirora.sdk.lifecycle", qos: .utility)

/// Runs `work`, asking iOS for time to finish it if the app goes to the background.
func runWithBackgroundTime(_ name: String, _ work: @escaping @Sendable () async -> Void) {
    onMain {
        let application = UIApplication.shared
        let task = Locked<UIBackgroundTaskIdentifier?>(nil)
        let ended = Locked(false)
        // Ended once, whichever comes first: the work finishing, or iOS's time running out.
        let end: @Sendable () -> Void = {
            onMain {
                ended.withLock { $0 = true }
                if let identifier = task.take() { application.endBackgroundTask(identifier) }
            }
        }
        // Begun outside the lock: iOS may call `end` before it returns, with no time left.
        let identifier = application.beginBackgroundTask(withName: name, expirationHandler: end)
        task.withLock { $0 = identifier }
        if ended.current, let identifier = task.take() { application.endBackgroundTask(identifier) }
        Task {
            await work()
            end()
        }
    }
}

/// Runs `work` on the main thread: at once if already there, as installing the push
/// integration must happen before `didFinishLaunching` returns to hear a launching tap.
func onMain(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated(work)
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated(work) }
    }
}

// MARK: - Push platform

struct UIKitPushPlatform: PushPlatform {
    var isSupported: Bool { true }

    func authorization() async -> PushAuthorization {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .notDetermined: continuation.resume(returning: .notDetermined)
                case .denied: continuation.resume(returning: .denied)
                // Authorized, provisional and ephemeral all deliver.
                default: continuation.resume(returning: .authorized)
                }
            }
        }
    }

    func requestAuthorization() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
    }

    func registerForRemoteNotifications() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onMain {
                UIApplication.shared.registerForRemoteNotifications()
                continuation.resume()
            }
        }
    }

    func firebaseTarget() async -> PushTarget? {
        await FirebaseMessagingBridge.target()
    }
}

/// Reads what Firebase registers the device as from FirebaseMessaging when the app includes
/// it, through the Objective-C runtime, so the SDK never links Firebase itself.
enum FirebaseMessagingBridge {
    /// Posted by FirebaseMessaging when its token, or in installation-id mode its
    /// registration, is made or changes (`FIRMessagingRegistrationTokenRefreshedNotification`).
    static let tokenRefreshed = Notification.Name("com.firebase.messaging.notif.fcm-token-refreshed")

    /// How long to wait for each Firebase answer.
    private static let wait: Double = 10

    /// The token, or the installation id in installation-id mode.
    @MainActor
    static func target() async -> PushTarget? {
        guard let messaging = shared("FIRMessaging", "messaging") else { return nil }
        guard installationIdEnabled(messaging) else {
            if let token = messaging.value(forKey: "FCMToken") as? String, !token.isEmpty {
                return PushTarget(kind: fcmTokenKind, token: token)
            }
            return await string(from: messaging, "tokenWithCompletion:").map { PushTarget(kind: fcmTokenKind, token: $0) }
        }
        guard await registered(messaging), let installations = shared("FIRInstallations", "installations") else { return nil }
        return await string(from: installations, "installationIDWithCompletion:")
            .map { PushTarget(kind: firebaseInstallationIdKind, token: $0) }
    }

    /// Firebase's installation-id mode (FirebaseMessaging 12.16 and later, with
    /// `FirebaseMessagingInstallationIdEnabled` in the app's Info.plist): Firebase makes no
    /// token, and the device registers with FCM as its Firebase installation id.
    @MainActor
    private static func installationIdEnabled(_ messaging: NSObject) -> Bool {
        messaging.responds(to: NSSelectorFromString("isInstallationIdEnabled"))
            && (messaging.value(forKey: "installationIdEnabled") as? Bool) == true
    }

    /// The registration below, shared by every read until it fails.
    private static let registration = Locked<Task<Bool, Never>?>(nil)

    /// Whether Firebase registered the installation id with FCM, which reading the id
    /// doesn't (an app with Firebase's auto-init off relies on this). Asked once a run, and
    /// again after a failure, not on every read: Firebase answers each request by posting
    /// `tokenRefreshed`, which reads again.
    @MainActor
    private static func registered(_ messaging: NSObject) async -> Bool {
        let register = NSSelectorFromString("registerWithCompletion:")
        guard messaging.responds(to: register) else { return false }
        let shared = UncheckedSendable(messaging)
        let task = registration.withLock { task in
            if let task { return task }
            let started = Task { @MainActor () -> Bool in
                let done = (try? await withTimeout(seconds: wait) {
                    await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                        let completion: @convention(block) (NSError?) -> Void = { continuation.resume(returning: $0 == nil) }
                        _ = shared.value.perform(register, with: completion)
                    }
                }) ?? false
                if !done { registration.withLock { $0 = nil } }
                return done
            }
            task = started
            return started
        }
        return await task.value
    }

    /// A Firebase object reached through a class method, such as `FIRMessaging.messaging`.
    private static func shared(_ className: String, _ selectorName: String) -> NSObject? {
        let selector = NSSelectorFromString(selectorName)
        guard let type = NSClassFromString(className) as? NSObject.Type, type.responds(to: selector) else { return nil }
        return type.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    /// The string a Firebase method gives its `(NSString?, NSError?)` completion; nil for an
    /// error, an empty string or no answer in time.
    @MainActor
    private static func string(from object: NSObject, _ selectorName: String) async -> String? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else { return nil }
        // Firebase's objects are thread-safe; they're only handed over to be called back.
        let shared = UncheckedSendable(object)
        let value = try? await withTimeout(seconds: wait) {
            await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                let completion: @convention(block) (NSString?, NSError?) -> Void = { value, _ in
                    continuation.resume(returning: value as String?)
                }
                _ = shared.value.perform(selector, with: completion)
            }
        }
        return value.flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - Automatic integration

/// Wires push into the app without app code, as Firebase and Customer.io do: the APNs token
/// from the app delegate, and taps from `UNUserNotificationCenter`'s delegate, which the SDK
/// wraps so the app's own delegate still gets every call.
///
/// An app turns it off with `KiroraAppDelegateProxyEnabled` set to `NO` in its Info.plist,
/// then calls ``Kirora``'s `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)`
/// and `userNotificationCenter(_:didReceive:withCompletionHandler:)` itself.
enum PushIntegration {
    static var automatic: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "KiroraAppDelegateProxyEnabled") as? Bool) ?? true
    }

    private static let installed = Locked(false)

    fileprivate static let firebaseObserved = Locked(false)

    static func install(log: Log) {
        observeFirebaseTokens()
        guard automatic else {
            log.debug("KiroraAppDelegateProxyEnabled is NO: the app forwards push callbacks itself")
            return
        }
        guard installed.claimOnce() else { return }
        onMain {
            NotificationCenterProxy.shared.install()
            if let delegate = UIApplication.shared.delegate {
                AppDelegateProxy.install(on: delegate)
            } else {
                // Created before the app delegate (e.g. in a SwiftUI App's init): wait for it.
                let observer = Locked<NSObjectProtocol?>(nil)
                observer.withLock { stored in
                    stored = NotificationCenter.default.addObserver(
                        forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main
                    ) { _ in
                        if let token = observer.take() { NotificationCenter.default.removeObserver(token) }
                        onMain {
                            if let delegate = UIApplication.shared.delegate { AppDelegateProxy.install(on: delegate) }
                        }
                    }
                }
            }
        }
    }
}

extension PushIntegration {
    /// Installs the integration at launch, before any client exists, for a wrapper whose
    /// client is created late, from JavaScript or Dart. iOS hands a tap that launched the app
    /// to the notification center's delegate as the launch finishes, and only then.
    ///
    /// Safe from `+load` (before `UIApplicationMain`), from `didFinishLaunching`, or later: it
    /// installs now if the app exists, else when it does, at the latest as launching finishes,
    /// as React Native Firebase's messaging module does. Once, however often it's called.
    static func installAtLaunch(log: Log) {
        if Thread.isMainThread, applicationExists() {
            install(log: log)
            return
        }
        let observer = Locked<NSObjectProtocol?>(nil)
        observer.withLock { stored in
            stored = NotificationCenter.default.addObserver(
                forName: UIApplication.didFinishLaunchingNotification, object: nil, queue: .main
            ) { _ in
                if let token = observer.take() { NotificationCenter.default.removeObserver(token) }
                install(log: log)
            }
        }
        // The main queue first runs inside `UIApplicationMain`, once the app exists: often
        // before the app's `didFinishLaunching`, never after the notification above.
        DispatchQueue.main.async {
            guard applicationExists() else { return }
            if let token = observer.take() { NotificationCenter.default.removeObserver(token) }
            install(log: log)
        }
    }

    /// Whether `UIApplication.shared` exists yet. Read through the runtime: before
    /// `UIApplicationMain`, Swift's non-optional `shared` would crash.
    private static func applicationExists() -> Bool {
        (UIApplication.self as AnyObject).value(forKey: "sharedApplication") != nil
    }

    /// A new Firebase token registers the device again, for push apps that send through
    /// Firebase. Needs no swizzling, so it's on whether or not the automatic integration is.
    static func observeFirebaseTokens() {
        guard firebaseObserved.claimOnce() else { return }
        NotificationCenter.default.addObserver(
            forName: FirebaseMessagingBridge.tokenRefreshed, object: nil, queue: nil
        ) { _ in
            PushTokens.shared.firebaseTokenChanged()
        }
    }
}

/// Adds the SDK to the app delegate's APNs token callbacks. The app's own implementation
/// runs first, unchanged; a SwiftUI app's adaptor is reached through its forwarding target.
enum AppDelegateProxy {
    private typealias Implementation = @convention(c) (AnyObject, Selector, UIApplication, AnyObject) -> Void
    private typealias Block = @convention(block) (AnyObject, UIApplication, AnyObject) -> Void

    private static let swizzled = Locked(Set<ObjectIdentifier>())

    static func install(on delegate: UIApplicationDelegate) {
        guard let delegateClass = object_getClass(delegate) else { return }
        // Once per class, including a superclass done already, or the SDK would hear twice.
        var ancestor: AnyClass? = delegateClass
        while let current = ancestor {
            if swizzled.withLock({ $0.contains(ObjectIdentifier(current)) }) { return }
            ancestor = class_getSuperclass(current)
        }
        swizzled.withLock { _ = $0.insert(ObjectIdentifier(delegateClass)) }
        let addedToken = add(
            to: delegateClass,
            #selector(UIApplicationDelegate.application(_:didRegisterForRemoteNotificationsWithDeviceToken:))
        ) { argument in
            if let token = argument as? Data { PushTokens.shared.received(token) }
        }
        let addedFailure = add(
            to: delegateClass,
            #selector(UIApplicationDelegate.application(_:didFailToRegisterForRemoteNotificationsWithError:))
        ) { _ in
            PushTokens.shared.failed()
        }
        // UIKit notes which callbacks the delegate has as it's set: one the SDK added
        // afterwards could go unseen, and the token never arrive. Setting the same delegate
        // again makes UIKit look again, as Firebase does. The app keeps owning it: `delegate`
        // holds the reference across the reset.
        guard addedToken || addedFailure,
              let application = UIApplication.value(forKey: "sharedApplication") as? UIApplication
        else { return }
        // `install` runs on the main thread (`onMain`).
        MainActor.assumeIsolated {
            guard application.delegate === delegate else { return }
            application.delegate = nil
            application.delegate = delegate
        }
    }

    /// Adds the SDK to `selector`'s implementation. True if the class had none (nor a
    /// forwarding target that answers it): a method UIKit may not know about yet.
    private static func add(to delegateClass: AnyClass, _ selector: Selector, handler: @escaping (AnyObject) -> Void) -> Bool {
        let original = class_getInstanceMethod(delegateClass, selector)
            .map { unsafeBitCast(method_getImplementation($0), to: Implementation.self) }
        let block: Block = { receiver, application, argument in
            if let original {
                original(receiver, selector, application, argument)
            } else if let target = (receiver as? NSObject)?.forwardingTarget(for: selector) as? NSObject,
                      target.responds(to: selector),
                      let targetClass = object_getClass(target) {
                let forwarded = unsafeBitCast(class_getMethodImplementation(targetClass, selector), to: Implementation.self)
                forwarded(target, selector, application, argument)
            }
            handler(argument)
        }
        class_replaceMethod(delegateClass, selector, imp_implementationWithBlock(block), "v@:@@")
        return original == nil
    }
}

/// How long the app's notification delegate has to call a Kirora tap's completion handler
/// before the SDK calls it, as for the app's other callbacks.
let appDelegateAnswerTimeout: Double = wrapperCallbackTimeout

/// The notification center's delegate: the SDK's, passing every call on to the app's own.
/// When the app (or another SDK) sets a delegate later, that one becomes the one passed to,
/// and this stays installed.
final class NotificationCenterProxy: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationCenterProxy()

    /// The app's delegates, weakly, as the notification center holds its own.
    let delegates = DelegateChain()

    private typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
    private typealias SetterBlock = @convention(block) (AnyObject, AnyObject?) -> Void

    func install() {
        let center = UNUserNotificationCenter.current()
        let selector = #selector(setter: UNUserNotificationCenter.delegate)
        guard let centerClass = object_getClass(center),
              let method = class_getInstanceMethod(centerClass, selector) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: SetterBlock = { receiver, newDelegate in
            let proxy = NotificationCenterProxy.shared
            if newDelegate !== proxy { proxy.delegates.set(newDelegate) }
            original(receiver, selector, proxy)
        }
        if let existing = center.delegate, existing !== self { delegates.set(existing) }
        class_replaceMethod(centerClass, selector, imp_implementationWithBlock(block), method_getTypeEncoding(method))
        center.delegate = self
    }

    /// Passes a call to the app's delegate that implements `selector` (see ``DelegateChain``).
    private func passOn(_ selector: Selector, _ call: (UNUserNotificationCenterDelegate) -> Void) -> Bool {
        delegates.passOn(where: { Self.implements($0, selector) }) { call($0 as! UNUserNotificationCenterDelegate) }
    }

    private static func implements(_ delegate: AnyObject, _ selector: Selector) -> Bool {
        (delegate as? UNUserNotificationCenterDelegate)?.responds(to: selector) == true
    }

    /// The SDK decides whether a Kirora push shows in the foreground, before the app's delegate
    /// is asked (an app decides through the wrapper's foreground handler). A delegate can't be
    /// trusted to: in Flutter, `FlutterAppDelegate` asks every plugin, and the first to answer,
    /// often with `[]` for a push it didn't make (`firebase_messaging` does), decides for all.
    /// Anyone else's push is the app's alone.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        if Kirora.userNotificationCenter(center, willPresent: notification, withCompletionHandler: completionHandler) { return }
        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))
        let passed = passOn(selector) { $0.userNotificationCenter?(center, willPresent: notification, withCompletionHandler: completionHandler) }
        // Passed back with no delegate left: the one that passed it back still has the call, and
        // in Flutter, other plugins may answer after it. Only with no delegate at all, iOS's default.
        if !passed, !delegates.isPassingOn { completionHandler([]) }
    }

    /// Kirora's taps are handled by the SDK first, then passed on. A delegate that leaves a
    /// Kirora tap unanswered has it answered for it after 1.5 seconds, as iOS expects.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let isKiroras = Kirora.handleTap(response)
        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
        let passOn: (@escaping @Sendable () -> Void) -> Bool = { done in
            self.passOn(selector) { $0.userNotificationCenter?(center, didReceive: response, withCompletionHandler: done) }
        }
        guard isKiroras else {
            if !passOn(completionHandler) { completionHandler() }
            return
        }
        askWithFallback(
            timeout: appDelegateAnswerTimeout,
            answer: { (_: Void) in completionHandler() },
            ask: { answer in
                if !passOn({ answer(()) }) { answer(()) }
            },
            fallback: { answer in answer(()) }
        )
    }

    @available(iOS 12.0, *)
    func userNotificationCenter(_ center: UNUserNotificationCenter, openSettingsFor notification: UNNotification?) {
        let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:))
        _ = passOn(selector) { $0.userNotificationCenter?(center, openSettingsFor: notification) }
    }

    override func responds(to selector: Selector!) -> Bool {
        // Only claim "open settings" if the app handles it: iOS shows a button for it then.
        if selector == #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:openSettingsFor:)) {
            return delegates.contains { Self.implements($0, selector) }
        }
        return super.responds(to: selector)
    }
}

/// Opens a push's link: first the app's `handleDeepLink`, if it opens the link itself. One of
/// the app's own universal links (a host it lists in `KiroraUniversalLinkHosts`) then goes to
/// the app delegate, as iOS hands it one. Anything else, or one the delegate doesn't take,
/// opens with `UIApplication.open`: the browser, or the app that owns the link.
@MainActor
func openPushLink(_ url: URL, handleDeepLink: (@MainActor @Sendable (URL) -> Bool)?) {
    if handleDeepLink?(url) == true { return }
    let application = UIApplication.shared
    // Only for listed hosts: Flutter's and React Native's app delegates say they handled any
    // web link, which would swallow every other one. A scene delegate is never handed one:
    // its `scene(_:continue:)` can't say whether it did, so a scene-based app claims its own
    // universal links in `handleDeepLink`.
    if isOwnUniversalLink(url, hosts: universalLinkHosts) {
        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        if application.delegate?.application?(application, continue: activity, restorationHandler: { _ in }) == true {
            return
        }
    }
    application.open(url, options: [:], completionHandler: nil)
}
#endif
