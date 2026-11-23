import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends one HTTP request. URLSession in the app; a fake in tests.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// A request still unanswered after this is abandoned and treated as a network failure.
let requestTimeoutSeconds: Double = 30

struct URLSessionTransport: HTTPTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        // Both: idle and in total, so a body that stops arriving can't hold a call open.
        configuration.timeoutIntervalForRequest = requestTimeoutSeconds
        configuration.timeoutIntervalForResource = requestTimeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    /// Cancelling the calling task cancels the request.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // `data(for:)` is iOS 15; this works back to iOS 13.
        let task = Locked<URLSessionDataTask?>(nil)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let dataTask = Self.session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let response = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), response))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                task.withLock { $0 = dataTask }
                dataTask.resume()
                // Cancelled before the task existed: the handler below found nothing to cancel.
                if Task.isCancelled { dataTask.cancel() }
            }
        } onCancel: {
            task.current?.cancel()
        }
    }
}

/// Transport for `/client/v1`: headers, errors and the user's token. On a 401 it asks
/// `identity` for a fresh token once and repeats the call.
final class ClientAPI: Sendable {
    static let defaultApiUrl = "https://api.kirora.io"

    /// `apiUrl`, without a trailing slash, if it's an address. Nil: every request fails with
    /// `urlProblem`.
    let apiUrl: URL?
    /// `/client/v1` under `apiUrl`.
    private let baseURL: URL?
    private let clientKey: String
    private let identity: Identity
    private let transport: HTTPTransport
    /// Keeps one workspace's stored state apart from another's in the same app.
    let namespace: String
    /// Why `apiUrl` can't be used, if it can't. Creating the client never throws.
    let urlProblem: String?
    /// `Kirora-SDK`, as it was when the client was created.
    private let sdk: String
    /// Told when Kirora refuses a user's token for good, even after a refresh.
    let onTokenRefused = Locked<(@Sendable (SignedInUser) -> Void)?>(nil)

    init(clientKey: String, apiUrl: String, identity: Identity, transport: HTTPTransport, sdk: String = sdkName) {
        self.sdk = sdk
        self.clientKey = clientKey
        self.identity = identity
        self.transport = transport
        var trimmed = apiUrl
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let url = URL(string: trimmed)
        if let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
           let host = url.host, !host.isEmpty {
            self.apiUrl = url
            urlProblem = nil
            namespace = "\(clientKey)@\(host)\(url.port.map { ":\($0)" } ?? "")"
        } else {
            self.apiUrl = nil
            urlProblem = "apiUrl must be an address like \(Self.defaultApiUrl)"
            // A malformed apiUrl still gets a namespace of its own, never a real workspace's.
            namespace = "\(clientKey)@\(apiUrl)"
        }
        baseURL = self.apiUrl?.appendingPathComponent("client/v1")
    }

    /// Sends as `user`, or whoever is signed in now. On a 401 it asks for a fresh token
    /// once and repeats the call, but never as a different user. Returns the answer's
    /// `data`, or nil for 204.
    @discardableResult
    func request(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        body: (any Encodable & Sendable)? = nil,
        as requestedUser: SignedInUser? = nil,
        refreshing: Bool = true
    ) async throws -> JSONValue? {
        guard let baseURL else { throw KiroraError(urlProblem ?? "apiUrl is not an address") }
        guard let user = requestedUser ?? identity.user else {
            throw KiroraError("call identify() with a user token first")
        }
        // Refused with nothing to replace it: nothing goes as them again, app opens and
        // device registration included, until identify() signs in with a new token. A
        // detachment goes on with the device's secret instead.
        if user.tokenRefused {
            throw KiroraApiError(
                status: 401, code: "UNAUTHORIZED",
                message: "Kirora refused the user's token; call identify() with a new one"
            )
        }
        let request = try makeRequest(baseURL, method, path, query, body)
        let sentToken = user.token
        do {
            return try await send(request, token: sentToken, as: user)
        } catch let refused as KiroraApiError where refused.status == 401 && refreshing {
            // Kirora refused the token: get a fresh one, once, and try again with it. (A
            // detachment doesn't: it uses the outgoing user's token as captured.)
            let freshToken: String?
            do {
                freshToken = try await identity.refresh(user, refusedToken: sentToken)
            } catch let failed as UserTokenError {
                identity.reportFailure(.fetchFailed, as: user)
                throw failed
            }
            guard let freshToken else {
                // No fresh token to try: no fetchUserToken, or it named someone else.
                throw tokenRefused(refused, as: user)
            }
            do {
                return try await send(request, token: freshToken, as: user)
            } catch let again as KiroraApiError where again.status == 401 {
                throw tokenRefused(again, as: user)
            }
        }
    }

    /// Kirora refused `user`'s token for good, even after a refresh: tells whoever listens,
    /// and returns the refusal to throw.
    private func tokenRefused(_ refusal: KiroraApiError, as user: SignedInUser) -> KiroraApiError {
        onTokenRefused.current?(user)
        identity.reportFailure(.refused, as: user)
        return refusal
    }

    /// One call; Kirora's answer to it is `user`'s token accepted. A 401 is thrown like any
    /// other refusal, with Kirora's own code and message.
    private func send(_ template: URLRequest, token: String, as user: SignedInUser) async throws -> JSONValue? {
        let answer = try await send(template, authorization: "Bearer \(token)")
        user.confirm()
        return answer
    }

    /// A call made with the device's secret (`Authorization: Device`), for detaching a
    /// registration with no user token held: no user, so no refresh.
    @discardableResult
    func request(
        _ method: String, _ path: String, query: [URLQueryItem] = [], deviceSecret: String
    ) async throws -> JSONValue? {
        guard let baseURL else { throw KiroraError(urlProblem ?? "apiUrl is not an address") }
        let request = try makeRequest(baseURL, method, path, query, nil)
        return try await send(request, authorization: "Device \(deviceSecret)")
    }

    private func send(_ template: URLRequest, authorization: String) async throws -> JSONValue? {
        var request = template
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw apiError(response, data)
        }
        if response.statusCode == 204 || data.isEmpty { return nil }
        return (try? JSONDecoder().decode(JSONValue.self, from: data))?["data"]
    }

    private func makeRequest(
        _ baseURL: URL, _ method: String, _ path: String, _ query: [URLQueryItem], _ body: (any Encodable & Sendable)?
    ) throws -> URLRequest {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath += path
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw KiroraError("can't make an address for \(path)") }
        var request = URLRequest(url: url, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = method
        request.setValue(clientKey, forHTTPHeaderField: "Kirora-Client-Key")
        request.setValue(sdk, forHTTPHeaderField: "Kirora-SDK")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return request
    }
}

private func apiError(_ response: HTTPURLResponse, _ data: Data) -> KiroraApiError {
    let error = (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"]
    // `errors`: `{ in?, field, code, message }` for each field a 400 refused.
    var fields: [(part: String?, field: String)] = []
    if case .array(let fieldErrors)? = error?["errors"] {
        for fieldError in fieldErrors {
            guard let field = fieldError["field"]?.stringValue else { continue }
            fields.append((fieldError["in"]?.stringValue, field))
        }
    }
    return KiroraApiError(
        status: response.statusCode,
        code: error?["code"]?.stringValue,
        message: error?["message"]?.stringValue ?? "Kirora answered \(response.statusCode)",
        retryAfterMs: retryAfterMs(response.value(forHTTPHeaderField: "Retry-After")),
        fields: fields
    )
}

/// `Retry-After` as seconds or an HTTP date (RFC 9110), in milliseconds from now.
func retryAfterMs(_ header: String?, now: Date = Date()) -> Int? {
    guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
    let delayMs: Double
    if let seconds = Double(header) {
        delayMs = seconds * 1000
    } else {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: header) else { return nil }
        delayMs = date.timeIntervalSince(now) * 1000
    }
    // `Double` takes "1e30", "inf" and "nan" too: only a finite, positive delay counts, and
    // one past a week is cut to a week rather than overflowing `Int`.
    guard delayMs.isFinite, delayMs > 0 else { return nil }
    return Int(min(delayMs, maxWaitSeconds * 1000))
}
