import Foundation

/// How a ``Kirora`` client is set up. Only ``clientKey`` is required.
///
/// The same options, with the same names and defaults, exist in every Kirora client SDK.
public struct KiroraOptions: Sendable {
    /// The workspace's public key, `kirora_pk_…`, from Developer → SDK in the dashboard.
    /// Safe to ship in the app.
    public var clientKey: String

    /// Asks your server for a signed user token. Called by ``Kirora/identify(_:)`` without a
    /// token, and again when Kirora refuses an expired one. Throw if it fails: queued
    /// events are kept. No token (`nil` or empty), or none after 30 seconds, counts as a
    /// failure too.
    public var fetchUserToken: (@Sendable () async throws -> String?)?

    /// Called on the main thread when the user's token fails in the background, where
    /// nothing else would tell your app: sending events, or registering for push. Once per
    /// failure, not per retry: again only after a request succeeds, or another
    /// ``Kirora/identify(_:)``. Never for a failure `identify(_:)` or
    /// ``Kirora/setPushConsent(_:)`` throws, or while the user is signing out. Sign the user
    /// out, or ask them to sign in again.
    public var onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)?

    /// Registers this device for push notifications. Off (`nil`) by default; pass
    /// ``KiroraPushOptions/enabled`` for the defaults.
    public var push: KiroraPushOptions?

    /// Track and store nothing until ``Kirora/setTrackingConsent(_:)`` is called with
    /// `true`, e.g. for users in the EU or UK.
    public var requireTrackingConsent: Bool

    /// Tracks `Session Started` when a visit begins and adds `context.sessionId` to every
    /// event. On by default. A visit ends after 30 minutes without activity; time in the
    /// foreground never ends one.
    public var trackSessions: Bool

    /// Tracks `Application Installed`, `Application Opened`, `Application Updated` and
    /// `Application Backgrounded`. Off by default.
    public var trackAppLifecycle: Bool

    /// What the SDK logs. Defaults to ``LogLevel/error``; ``LogLevel/debug`` also logs
    /// what is sent.
    public var logLevel: LogLevel

    /// Called on the main thread with a push's link when the user taps it. Return `true` if
    /// your app opened it itself. Otherwise the SDK opens it: a universal link in your app
    /// (through your scene or app delegate), anything else with `UIApplication.open`.
    public var handleDeepLink: (@MainActor @Sendable (URL) -> Bool)?

    /// Redacts or drops an event before it's stored or sent. Called once per event,
    /// automatic ones included (`Session Started`, screen views, lifecycle events), on the
    /// thread that tracked it, with a copy of its name, properties and context. Return the
    /// event with fields changed or removed, or `nil` to drop it. Throwing, or answering
    /// values JSON can't hold, drops the event too. The name, time and idempotency key stay
    /// the SDK's. Tracking from inside it is refused.
    public var beforeSend: (@Sendable (BeforeSendEvent) throws -> BeforeSendEvent?)?

    /// Kirora's address, for staging or a private deployment, without a path: the SDK
    /// adds its own. Defaults to `https://api.kirora.io`.
    public var apiUrl: String

    public init(
        clientKey: String,
        fetchUserToken: (@Sendable () async throws -> String?)? = nil,
        onAuthenticationFailed: (@MainActor @Sendable (AuthenticationFailureReason) -> Void)? = nil,
        push: KiroraPushOptions? = nil,
        requireTrackingConsent: Bool = false,
        trackSessions: Bool = true,
        trackAppLifecycle: Bool = false,
        logLevel: LogLevel = .error,
        handleDeepLink: (@MainActor @Sendable (URL) -> Bool)? = nil,
        apiUrl: String = "https://api.kirora.io",
        beforeSend: (@Sendable (BeforeSendEvent) throws -> BeforeSendEvent?)? = nil
    ) {
        self.beforeSend = beforeSend
        self.handleDeepLink = handleDeepLink
        self.clientKey = clientKey
        self.fetchUserToken = fetchUserToken
        self.onAuthenticationFailed = onAuthenticationFailed
        self.push = push
        self.requireTrackingConsent = requireTrackingConsent
        self.trackSessions = trackSessions
        self.trackAppLifecycle = trackAppLifecycle
        self.logLevel = logLevel
        self.apiUrl = apiUrl
    }
}

/// Why the user's token failed, for ``KiroraOptions/onAuthenticationFailed``.
public enum AuthenticationFailureReason: String, Sendable, Equatable {
    /// `fetchUserToken` threw, or didn't answer within 30 seconds.
    case fetchFailed = "fetch_failed"
    /// Kirora refused the token (401) and no fresh one was accepted: refused too, or none to
    /// try (no `fetchUserToken`, or it gave another user's token).
    case refused
}

/// Push settings. Everything else about push (the APNs credential, the push app) comes
/// from Kirora, not the app.
public struct KiroraPushOptions: Sendable, Equatable {
    /// Only needed if the workspace has more than one iOS push app: the one to register
    /// with. Kirora chooses otherwise.
    public var pushAppId: String?

    public init(pushAppId: String? = nil) {
        self.pushAppId = pushAppId
    }

    /// Push on, with Kirora choosing the push app.
    public static let enabled = KiroraPushOptions()
}

/// The answer to ``Kirora/requestPushPermission()``. The same values in every Kirora SDK.
public enum PushPermission: String, Sendable, Equatable {
    case granted
    case denied
    /// The user dismissed the prompt without answering.
    case unanswered
    /// Push is off in ``KiroraOptions/push``, or the platform can't take pushes.
    case unsupported
}

/// The answer to ``Kirora/getPushStatus()``. The same values in every Kirora SDK. The
/// notification permission comes first; with it granted, ``enabled`` when this device is
/// registered for the signed-in user.
public enum PushStatus: String, Sendable, Equatable {
    /// Registered for the signed-in user's pushes.
    case enabled
    /// Permission is granted, but the device isn't registered: turned off with
    /// ``Kirora/setPushEnabled(_:)``, nobody signed in, or the registration failed.
    case disabled
    case denied
    /// The user hasn't answered the notification prompt yet.
    case unanswered
    /// Push is off in ``KiroraOptions/push``, or the platform can't take pushes.
    case unsupported
}

/// What ``Kirora/getState()`` answers: a snapshot for an app's support and debug screens.
public struct KiroraState: Sendable, Equatable {
    /// The client is set up and not destroyed.
    public let isInitialized: Bool
    /// A user is signed in.
    public let isIdentified: Bool
    /// The id sent as `context.device.id`, or nil when there is none (deleted after tracking
    /// consent was withdrawn, say, or not made yet).
    public let deviceId: String?
    /// The current visit's id, or nil when there is none.
    public let sessionId: String?
    /// The token this device is registered for push with: the APNs token as lowercase hex,
    /// or the Firebase token for an app that sends through Firebase. Nil while unregistered.
    public let pushToken: String?
    /// Whether behavioural tracking is allowed now.
    public let trackingConsent: Bool
    /// The signed-in user's last marketing push choice recorded from this device with
    /// ``Kirora/setPushConsent(_:)``; false if there is none. Cleared at logout and when
    /// another user signs in.
    public let pushConsent: Bool
    /// Events waiting on the device.
    public let queuedEventCount: Int
}

/// An event as ``KiroraOptions/beforeSend`` sees it: a copy, so changing it changes nothing
/// else. Values are Foundation's JSON values: `String`, `Int64`, `Double`, `Bool`, `NSNull`,
/// arrays and `[String: Any]`.
public struct BeforeSendEvent: @unchecked Sendable {
    public let name: String
    public var properties: [String: Any]
    /// The session, device, language and time zone the SDK collected.
    public var context: [String: Any]

    public init(name: String, properties: [String: Any], context: [String: Any]) {
        self.name = name
        self.properties = properties
        self.context = context
    }
}

/// What the SDK logs.
public enum LogLevel: String, Sendable, Comparable {
    case none
    case error
    case debug

    private var rank: Int {
        switch self {
        case .none: return 0
        case .error: return 1
        case .debug: return 2
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}
