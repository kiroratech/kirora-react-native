import Foundation

/// Reports a push tapped to its own `trackingUrl`, which names the device and delivery, so
/// it needs no credentials and no signed-in user. A best-effort count: a network error,
/// 429 or 5xx is tried once more, then dropped. A repeat changes nothing on Kirora's side.
enum TrackingReport {
    static func post(
        _ event: String,
        to trackingUrl: URL,
        transport: HTTPTransport = URLSessionTransport()
    ) async {
        var request = URLRequest(url: trackingUrl, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["event": event])
        for _ in 0..<2 {
            guard let (_, response) = try? await transport.send(request) else { continue }
            // Any other 4xx (an expired or altered token) would be refused again.
            if response.statusCode < 500, response.statusCode != 429 { return }
        }
    }
}

/// A Kirora push's own keys, beside `aps`, whether it came through APNs or Firebase.
///
/// A push is Kirora's only if it carries the `kirora` marker. `trackingUrl`, `actionUrl` and
/// `imageUrl` are names any provider might use, so they alone never make a push Kirora's.
struct KiroraPushPayload: Equatable, Sendable {
    /// Where to report the tap. Missing on test sends from the dashboard, which report
    /// nothing.
    var trackingUrl: URL?
    /// What a tap on the notification opens: a web link or an app link (`myapp://…`).
    var actionUrl: URL?
    /// The push's buttons, in order. iOS shows them only for a notification category the
    /// app registers; an action's identifier names its button by position (`"0"`, `"1"`)
    /// or by title.
    var buttons: [Button] = []

    struct Button: Equatable, Sendable {
        var title: String
        var url: URL?
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["kirora"] != nil else { return nil }
        // Checked against the API's address when it's reported (`trustedTrackingUrl`).
        trackingUrl = (userInfo["trackingUrl"] as? String).flatMap(URL.init(string:))
        actionUrl = safeLink(userInfo["actionUrl"] as? String)
        buttons = Self.buttons(userInfo["buttons"])
    }

    /// The button an action identifier names, by its position or its title.
    func buttonIndex(for actionIdentifier: String) -> Int? {
        if let index = Int(actionIdentifier), buttons.indices.contains(index) { return index }
        return buttons.firstIndex { $0.title == actionIdentifier }
    }

    /// The link of the button an action identifier names, if any.
    func buttonLink(for actionIdentifier: String) -> URL? {
        buttonIndex(for: actionIdentifier).flatMap { buttons[$0].url }
    }

    /// `buttons` as Kirora sends it: JSON text (native pushes carry string data), or an array.
    /// The same rule as the extension's `buttonTitles`, which shows them: positions must
    /// agree, as an action names its button by position. So a button without a title means
    /// none are shown, or read.
    private static func buttons(_ value: Any?) -> [Button] {
        var list: Any? = value
        if let text = value as? String, let data = text.data(using: .utf8) {
            list = try? JSONSerialization.jsonObject(with: data)
        }
        guard let items = list as? [[String: Any]] else { return [] }
        let buttons = items.compactMap { item -> Button? in
            guard let title = item["title"] as? String, !title.isEmpty else { return nil }
            return Button(title: title, url: safeLink(item["url"] as? String))
        }
        guard buttons.count == items.count else { return [] }
        return Array(buttons.prefix(4))
    }
}

/// A link Kirora would send: any scheme but those it refuses when a push is made.
private func safeLink(_ text: String?) -> URL? {
    guard let url = text.flatMap(URL.init(string:)), let scheme = url.scheme?.lowercased(),
          !["javascript", "data", "file", "vbscript"].contains(scheme) else { return nil }
    return url
}

/// What to do when the user taps a notification: report it, and open its link.
struct PushTapHandler: Sendable {
    /// Whether the tap was on the notification itself, on one of its buttons (by the
    /// action's identifier), or dismissed it.
    enum Action: Sendable, Equatable { case open, dismiss, button(String) }

    var transport: HTTPTransport = URLSessionTransport()
    /// The API's address, which taps are reported under (`/t/p/…`) and nowhere else: the
    /// app's `apiUrl`, waiting for a client if none exists yet. A fixed one in tests.
    var apiBase: @Sendable () async -> URL = { await reportingApiBase(waitingUpTo: launchTapApiUrlWait) }
    /// Opens a link on the main thread. UIKit in the app; a fake in tests.
    var openURL: @Sendable (URL) async -> Void

    /// Handles a tap on a Kirora push: reports it and opens its link, then tells `tapped` (a
    /// wrapper's listener) which link it opened. The report goes first: `tapped` waits for
    /// it, but no more than 1.5 seconds, so a slow network can't hold the app's tap event.
    func handle(_ payload: KiroraPushPayload, action: Action, tapped: (@Sendable (URL?) -> Void)? = nil) async {
        guard action != .dismiss else { return }
        // One of the app's own actions (its category won over Kirora's buttons): not a tap
        // on the push itself, maybe one that never opens the app, so not reported as an open.
        // A wrapper's listener still hears it.
        let isAppsOwn: Bool
        if case .button(let identifier) = action { isAppsOwn = payload.buttonIndex(for: identifier) == nil } else { isAppsOwn = false }
        // Opening a link counts as a click (Kirora counts a click as an open too).
        let link: URL?
        switch action {
        case .open: link = payload.actionUrl
        case .button(let identifier): link = payload.buttonLink(for: identifier)
        case .dismiss: link = nil
        }
        let transport = self.transport
        let apiBase = self.apiBase
        let reporting = Task {
            guard !isAppsOwn, let candidate = payload.trackingUrl else { return }
            if let trackingUrl = trustedTrackingUrl(candidate, apiBase: await apiBase()) {
                await TrackingReport.post(link == nil ? "opened" : "clicked", to: trackingUrl, transport: transport)
            }
        }
        if let link { await openURL(link) }
        if let tapped {
            _ = try? await withTimeout(seconds: wrapperCallbackTimeout) { await reporting.value }
            tapped(link)
        }
        await reporting.value
    }
}

/// The latest client's `apiUrl`, which push reports must go to.
private let currentApiUrl = Locked<URL?>(nil)
/// Opened once a client has set ``currentApiUrl``.
private let apiUrlKnown = Gate()
/// How long a tap heard before any client exists waits for one to learn the `apiUrl`.
let launchTapApiUrlWait: Double = 10

/// A client was created with `apiUrl`: taps are reported there from now on.
func useApiUrlForReports(_ apiUrl: URL) {
    currentApiUrl.withLock { $0 = apiUrl }
    apiUrlKnown.open()
}

/// The API push reports go to: the latest client's `apiUrl`, else the one the app last
/// created a client with (kept in the SDK's state file), else Kirora's. Before any client
/// exists (a tap that launched the app), waits for one, `seconds` at most: the app may use
/// another `apiUrl` than the one it remembered, as on its first launch after an update.
func reportingApiBase(waitingUpTo seconds: Double) async -> URL {
    await apiUrlKnown.wait(upTo: seconds)
    return currentApiUrl.current
        ?? KiroraEnvironment.liveStateStore().string(StorageKeys.apiUrl).flatMap(URL.init(string:))
        ?? URL(string: ClientAPI.defaultApiUrl)!
}

/// `trackingUrl`, if it's a `/t/p/…` address on the API's own scheme, host and port (under
/// its path, if `apiUrl` has one), as every Kirora SDK checks; nil for anywhere else. The
/// extension has the same, word for word, as it can't depend on this target.
func trustedTrackingUrl(_ trackingUrl: URL, apiBase: URL) -> URL? {
    func port(_ components: URLComponents, _ scheme: String) -> Int? {
        components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
    }
    // Under the API's own path, if it has one.
    func prefix(_ base: URLComponents) -> String {
        var path = base.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return path + "/t/p/"
    }
    guard let url = URLComponents(url: trackingUrl, resolvingAgainstBaseURL: false),
          let base = URLComponents(url: apiBase, resolvingAgainstBaseURL: false),
          let scheme = url.scheme?.lowercased(), scheme == base.scheme?.lowercased(),
          let host = url.host?.lowercased(), !host.isEmpty, host == base.host?.lowercased(),
          port(url, scheme) == port(base, scheme),
          url.user == nil, url.password == nil,
          url.percentEncodedPath.hasPrefix(prefix(base)),
          !url.percentEncodedPath.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    else { return nil }
    return trackingUrl
}

/// Taps the SDK has handled, so a tap passed to it twice (by its own delegate proxy and by
/// the app's manual call) is reported once.
let handledTaps = Locked(Set<String>())

/// One tap: the push's request id is shared by pushes with the same collapse id, which iOS
/// uses as it, so the delivery's date tells a later one apart.
func tapKey(_ requestId: String, delivered: Date, action: String) -> String {
    "\(requestId)|\(delivered.timeIntervalSince1970)|\(action)"
}

func firstTimeHandling(_ id: String) -> Bool {
    handledTaps.withLock { handled in
        if handled.count > 200 { handled.removeAll() }
        return handled.insert(id).inserted
    }
}
