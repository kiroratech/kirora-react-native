import Foundation

/// Every error the SDK throws, as Stripe's libraries throw `StripeError`: catch it to catch
/// them all. Thrown as itself for a setup problem (no user token to sign in with, an
/// `apiUrl` that isn't an address) or a call that couldn't reach Kirora; Kirora's refusals
/// are ``KiroraApiError``, and a failed `fetchUserToken` is ``UserTokenError``.
///
/// A class, so the two can extend it, as in every Kirora SDK. Immutable, so safe to pass
/// between threads.
public class KiroraError: Error, LocalizedError, CustomStringConvertible, @unchecked Sendable {
    public let message: String
    /// What went wrong underneath: the network's error for a call that couldn't reach
    /// Kirora, or what `fetchUserToken` threw.
    public let underlying: Error?

    init(_ message: String, underlying: Error? = nil) {
        self.message = message
        self.underlying = underlying
    }

    public var description: String { "Kirora: \(message)" }
    public var errorDescription: String? { description }
}

/// The app's `fetchUserToken` failed, returned no token, or didn't answer within 30
/// seconds. Queued events are kept and retried later. ``KiroraError/underlying`` is what
/// it threw, or the timeout.
public final class UserTokenError: KiroraError, @unchecked Sendable {
    init(_ underlying: Error) {
        super.init("fetchUserToken failed: \(underlying)", underlying: underlying)
    }

    init(message: String) {
        super.init(message)
    }
}

/// An error answer from the Kirora API.
public final class KiroraApiError: KiroraError, @unchecked Sendable {
    /// The HTTP status.
    public let status: Int
    /// Kirora's error code, such as `UNAUTHORIZED` or `RATE_LIMITED`, if it sent one.
    public let code: String?
    /// From the `Retry-After` header, if any.
    public let retryAfterMs: Int?
    /// The fields a `VALIDATION_ERROR` names, each with the part of the request it's in
    /// (`body`, `headers`…, nil if unsaid): `events.3.name` in the body, `kirora-sdk` in the
    /// headers.
    let fields: [(part: String?, field: String)]

    init(
        status: Int, code: String?, message: String, retryAfterMs: Int? = nil,
        fields: [(part: String?, field: String)] = []
    ) {
        self.status = status
        self.code = code
        self.retryAfterMs = retryAfterMs
        self.fields = fields
        super.init(message)
    }

    /// True for 408, 425, 429 and 5xx: the same call may succeed later.
    public var isRetryable: Bool { [408, 425, 429].contains(status) || status >= 500 }

    public override var description: String {
        "Kirora: \(message) (\(status)\(code.map { " \($0)" } ?? ""))"
    }
}

/// What a public method throws: the SDK's own errors as they are, and anything else (the
/// network's) as a ``KiroraError`` around it. A cancelled task stays cancelled.
func asKiroraError(_ error: Error) -> Error {
    if error is KiroraError || error is CancellationError { return error }
    if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
    return KiroraError("couldn't reach Kirora: \(error.localizedDescription)", underlying: error)
}
