import Foundation

/// A tap on a Kirora push or one of its buttons, as ``Kirora/addNotificationClickListener(_:)``
/// hears it.
public struct KiroraPushTap: @unchecked Sendable {
    /// The push's own keys (`kirora`, `trackingUrl`, `actionUrl`, `buttons`, the sender's
    /// data, `aps`), as JSON values: strings, numbers, booleans, `NSNull`, arrays and
    /// dictionaries.
    public let data: [String: Any]
    /// The tapped button's position, or nil for a tap on the notification itself.
    public let buttonIndex: Int?
    /// The notification action's identifier: `com.apple.UNNotificationDefaultActionIdentifier`
    /// for a tap on the notification, or the action's identifier for a button.
    public let actionIdentifier: String
    /// The tap's link, if it had one: by the time the listener hears the tap, the SDK has
    /// opened it or handed it to `handleDeepLink`, unless a later launch tap took its place.
    public let link: URL?
}

/// A listener added with ``Kirora/addNotificationClickListener(_:)``. Keep it while you want
/// to hear taps; ``remove()`` stops them. Releasing it doesn't.
public final class KiroraListenerRegistration: Sendable {
    private let onRemove: @Sendable () -> Void

    init(onRemove: @escaping @Sendable () -> Void) {
        self.onRemove = onRemove
    }

    /// Stops the listener hearing taps. Safe to call more than once.
    public func remove() { onRemove() }
}

extension Kirora {
    /// Hears taps on Kirora pushes and their buttons, with the push's data, on the main
    /// thread, after the SDK has reported the tap and opened its link.
    ///
    /// Taps are heard by the SDK, not a client, so this may be called before a client exists,
    /// and a listener outlives the client. A tap heard before any listener (the tap that
    /// launched the app) is held, the latest ten, and given to the first listener added, in
    /// order. Add it at launch, as early as the client.
    ///
    /// Only for Kirora's pushes; anyone else's go to your notification delegate as usual.
    @discardableResult
    public static func addNotificationClickListener(
        _ listener: @escaping @MainActor @Sendable (KiroraPushTap) -> Void
    ) -> KiroraListenerRegistration {
        // One stream, read by one task on the main actor: taps reach the listener in the order
        // they were heard, held ones first.
        let (taps, continuation) = AsyncStream<KiroraPushTap>.makeStream()
        // Checked before each tap: one already queued when it's removed isn't heard.
        let removed = Locked(false)
        Task { @MainActor in
            for await tap in taps {
                if removed.current { break }
                listener(tap)
            }
        }
        let id = pushTapEvents.addAppListener { tap in continuation.yield(tap) }
        return KiroraListenerRegistration {
            removed.withLock { $0 = true }
            pushTapEvents.removeAppListener(id)
            continuation.finish()
        }
    }
}

/// Taps for the listeners: the app's native ones, and a wrapper's. Each side holds the taps
/// it hasn't heard yet, the latest ten, until it has a listener: a wrapper detached (a
/// Flutter engine torn down) holds them again whatever the app listens to natively.
final class PushTapEvents: @unchecked Sendable {
    static let held = 10

    typealias Listener = @Sendable (KiroraPushTap) -> Void

    private struct State {
        var wrapper: Listener?
        var app: [(id: Int, listener: Listener)] = []
        var nextId = 0
        var heldForWrapper: [KiroraPushTap] = []
        var heldForApp: [KiroraPushTap] = []
    }

    private let state = Locked(State())

    func deliver(_ tap: KiroraPushTap) {
        // The app's listeners only enqueue, so they're called under the lock: one being added
        // gets the held taps before newer ones. The wrapper's is its own code: outside it.
        let wrapper = state.withLock { state -> Listener? in
            if state.wrapper == nil { Self.hold(tap, in: &state.heldForWrapper) }
            if state.app.isEmpty { Self.hold(tap, in: &state.heldForApp) }
            for (_, listener) in state.app { listener(tap) }
            return state.wrapper
        }
        wrapper?(tap)
    }

    /// The wrapper's listener (``KiroraWrapper/setTapListener(_:)``), or nil to detach it.
    func setListener(_ listener: Listener?) {
        let waiting = state.withLock { state -> [KiroraPushTap] in
            state.wrapper = listener
            guard listener != nil else { return [] }
            defer { state.heldForWrapper = [] }
            return state.heldForWrapper
        }
        // Outside the lock: the wrapper's listener is the wrapper's code. A tap arriving
        // meanwhile may reach it first; wrappers take taps from any thread, in any case.
        if let listener { waiting.forEach(listener) }
    }

    /// `listener` must only enqueue (it's called under the lock, to keep taps in order).
    func addAppListener(_ listener: @escaping Listener) -> Int {
        state.withLock { state in
            state.nextId += 1
            state.app.append((state.nextId, listener))
            state.heldForApp.forEach(listener)
            state.heldForApp = []
            return state.nextId
        }
    }

    func removeAppListener(_ id: Int) {
        state.withLock { $0.app.removeAll { $0.id == id } }
    }

    private static func hold(_ tap: KiroraPushTap, in held: inout [KiroraPushTap]) {
        held.append(tap)
        if held.count > Self.held { held.removeFirst(held.count - Self.held) }
    }
}

let pushTapEvents = PushTapEvents()
