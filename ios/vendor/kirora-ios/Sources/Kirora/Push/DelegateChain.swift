import Foundation

/// The delegates the SDK's stand-in delegate passes calls on to, oldest first: the one there
/// before the SDK's, then each set since.
///
/// A delegate set after the SDK's may keep the one it found, the SDK's stand-in, and pass
/// calls on to it (`firebase_messaging` does). The stand-in passes it on to the newest
/// delegate, which passes it back: without this, the two would call each other until the
/// stack overflows. So a call that comes back to the stand-in goes to the delegate before the
/// one that passed it back, as it would have without the SDK.
final class DelegateChain: @unchecked Sendable {
    private struct Entry { weak var value: AnyObject? }
    private let entries = Locked<[Entry]>([])

    /// The delegate is now `delegate`; nil clears them all, as setting no delegate does.
    func set(_ delegate: AnyObject?) {
        entries.withLock { list in
            guard let delegate else { return list = [] }
            list.removeAll { $0.value == nil || $0.value === delegate }
            list.append(Entry(value: delegate))
        }
    }

    /// Whether any delegate passes `handles`.
    func contains(where handles: (AnyObject) -> Bool) -> Bool {
        entries.current.contains { $0.value.map(handles) ?? false }
    }

    /// Passes a call to the newest delegate that `handles` it, or, for a call passed back to
    /// the stand-in from inside one, to the delegate before that one. False when none is left.
    func passOn(where handles: (AnyObject) -> Bool, _ call: (AnyObject) -> Void) -> Bool {
        let candidates = entries.current.compactMap(\.value).filter(handles)
        let depth = self.depth
        guard depth < candidates.count else { return false }
        self.depth = depth + 1
        defer { self.depth = depth }
        call(candidates[candidates.count - 1 - depth])
        return true
    }

    /// Whether a call is being passed on, on this thread: one that reaches the stand-in now
    /// was passed back to it.
    var isPassingOn: Bool { depth > 0 }

    // Per thread: a delegate passes a call back from inside its own, on the same thread.
    private let depthKey = "io.kirora.delegate-chain.\(UUID().uuidString)"
    private var depth: Int {
        get { Thread.current.threadDictionary[depthKey] as? Int ?? 0 }
        set { Thread.current.threadDictionary[depthKey] = newValue == 0 ? nil : newValue }
    }
}
