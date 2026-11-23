#if canImport(UserNotifications)
import Foundation
import UserNotifications

/// Reports Kirora pushes delivered, and shows their images and buttons, from your app's
/// Notification Service Extension. Kirora sets `mutable-content` on every iOS push, so the
/// extension always runs. Without one, iOS reports no deliveries and shows no images or
/// buttons.
///
/// A push's buttons become a notification category, added to the app's own (never
/// replacing them). If your app sets its categories with `setNotificationCategories` at
/// launch, iOS replaces Kirora's then, and buttons of pushes already delivered disappear.
///
/// Deliveries are reported only to Kirora's API, `https://api.kirora.io`. If the app sets
/// another `apiUrl`, set the extension's `KiroraApiUrl` Info.plist key to the same.
///
/// The simplest extension is a subclass:
///
/// ```swift
/// import KiroraNotificationService
///
/// class NotificationService: KiroraNotificationServiceExtension {}
/// ```
///
/// Or call it from your own extension, which handles everyone else's pushes:
///
/// ```swift
/// override func didReceive(_ request: UNNotificationRequest,
///                          withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
///     if KiroraNotificationService.didReceive(request, withContentHandler: contentHandler) { return }
///     // Not a Kirora push: your own handling, then contentHandler(…)
/// }
///
/// override func serviceExtensionTimeWillExpire() {
///     // The request this extension instance was given in didReceive.
///     KiroraNotificationService.serviceExtensionTimeWillExpire(for: request)
/// }
/// ```
public enum KiroraNotificationService {
    /// Handles a Kirora push: reports it delivered, attaches its image, then hands it to
    /// `contentHandler`, whatever Kirora answered. Returns false, without calling
    /// `contentHandler`, for anyone else's push.
    @discardableResult
    public static func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) -> Bool {
        let userInfo = request.content.userInfo
        guard let (trackingUrl, imageUrl) = kiroraPush(userInfo) else { return false }
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        // The sender's own category, if it set one, wins.
        let category = content.categoryIdentifier.isEmpty ? buttonCategory(buttonTitles(userInfo)) : nil
        if let category { content.categoryIdentifier = category.identifier }
        let delivery = PendingDelivery(content: content, contentHandler: contentHandler)
        let id = request.identifier
        active.withLock { $0[id, default: []].append(delivery) }
        let reportTo = trackingUrl.flatMap { trustedTrackingUrl($0, apiBase: apiBase) }
        let buttonCategory = category.map { Unchecked($0) }
        Task {
            // Together: iOS gives an extension about 30 seconds in all.
            let reporting = Task { await report(reportTo) }
            let buttons = Task { if let buttonCategory { await register(buttonCategory) } }
            if let imageUrl, let attachment = await downloadAttachment(imageUrl) { delivery.attach(attachment) }
            await buttons.value
            // The report isn't worth holding the notification back long for: it goes on
            // after, while iOS keeps the extension running.
            await wait(for: reporting, upTo: reportWait)
            delivery.finish()
            // Only this one: a later push with the same id (a collapse id) may be under way.
            active.withLock { active in
                active[id]?.removeAll { $0 === delivery }
                if active[id]?.isEmpty == true { active[id] = nil }
            }
        }
        return true
    }

    /// iOS is about to stop the extension instance that was given `request`: shows that push
    /// as it stands. Other pushes the process is working on go on.
    public static func serviceExtensionTimeWillExpire(for request: UNNotificationRequest) {
        active.withLock { $0.removeValue(forKey: request.identifier) }?.forEach { $0.finish() }
    }

    /// iOS is about to stop the extension: shows every Kirora push still being worked on
    /// as it stands, including other instances' in the same process. Prefer
    /// ``serviceExtensionTimeWillExpire(for:)`` when the extension keeps its request.
    public static func serviceExtensionTimeWillExpire() {
        let deliveries = active.withLock { active -> [PendingDelivery] in
            defer { active.removeAll() }
            return active.values.flatMap { $0 }
        }
        deliveries.forEach { $0.finish() }
    }

    /// A Kirora push's tracking and image addresses, or nil for anyone else's push. Kirora's
    /// carries the `kirora` marker; `trackingUrl` and `imageUrl` are names any provider might
    /// use, so they alone never count.
    static func kiroraPush(_ userInfo: [AnyHashable: Any]) -> (trackingUrl: URL?, imageUrl: URL?)? {
        guard userInfo["kirora"] != nil else { return nil }
        let trackingUrl = (userInfo["trackingUrl"] as? String).flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let imageUrl = (userInfo["imageUrl"] as? String).flatMap(URL.init(string:))
            .flatMap { $0.scheme?.lowercased() == "https" ? $0 : nil }
        return (trackingUrl, imageUrl)
    }

    // MARK: Buttons

    /// Kirora's button categories start with this; the app's own are left alone.
    static let categoryPrefix = "kirora.buttons."
    /// Kirora categories kept at most, so they don't pile up across campaigns. The least
    /// recently used go first.
    static let maxCategories = 32

    /// The push's button titles, in order: `buttons` as Kirora sends it, JSON text (native
    /// pushes carry string data) or an array of `{ title, url }`. iOS shows four at most.
    static func buttonTitles(_ userInfo: [AnyHashable: Any]) -> [String] {
        var list: Any? = userInfo["buttons"]
        if let text = list as? String, let data = text.data(using: .utf8) {
            list = try? JSONSerialization.jsonObject(with: data)
        }
        guard let items = list as? [[String: Any]] else { return [] }
        let titles = items.compactMap { $0["title"] as? String }.filter { !$0.isEmpty }
        // A button without a title would shift the others' positions: show none.
        guard titles.count == items.count else { return [] }
        return Array(titles.prefix(4))
    }

    /// A category showing `titles` as buttons, or nil for none. Each action's identifier is
    /// the button's position (`"0"`, `"1"`), which the app's SDK maps back to its link and
    /// reports as a click; each opens the app, so it can. The same titles always make the
    /// same category.
    static func buttonCategory(_ titles: [String]) -> UNNotificationCategory? {
        guard !titles.isEmpty else { return nil }
        let actions = titles.enumerated().map { index, title in
            UNNotificationAction(identifier: String(index), title: title, options: [.foreground])
        }
        return UNNotificationCategory(
            identifier: categoryPrefix + stableHash(titles.joined(separator: "\u{1F}")),
            actions: actions, intentIdentifiers: [], options: []
        )
    }

    /// The registration under way: each waits for the one before, as each reads the
    /// categories, then replaces them all. Two at once would each drop the other's.
    private static let registering = Locked<Task<Void, Never>?>(nil)

    /// Adds `category` to the app's categories, keeping the app's own, and waits (a second
    /// at most) until iOS has it, as it applies them in the background. One at a time.
    private static func register(_ category: Unchecked<UNNotificationCategory>) async {
        let turn = registering.withLock { last -> Task<Void, Never> in
            let previous = last
            let next = Task {
                await previous?.value
                await registerNow(category.value)
            }
            last = next
            return next
        }
        await turn.value
    }

    private static func registerNow(_ category: UNNotificationCategory) async {
        let center = UNUserNotificationCenter.current()
        let existing = await categories(center)
        let order = registrationOrder(adding: category.identifier)
        if existing.contains(where: { $0.identifier == category.identifier }) { return }
        let kirora = existing.filter { $0.identifier.hasPrefix(categoryPrefix) }
        let keep = Set(categoriesToKeep(order: order, registered: kirora.map(\.identifier)))
        var kept = existing.filter { !$0.identifier.hasPrefix(categoryPrefix) || keep.contains($0.identifier) }
        kept.insert(category)
        center.setNotificationCategories(kept)
        for _ in 0..<10 {
            if await categories(center).contains(where: { $0.identifier == category.identifier }) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Kirora's categories in the order pushes last used them, oldest first, kept in the
    /// extension's own defaults. Moves `identifier` to the end and returns the list.
    private static func registrationOrder(adding identifier: String) -> [String] {
        let defaults = UserDefaults.standard
        var order = (defaults.stringArray(forKey: categoryOrderKey) ?? []).filter { $0 != identifier }
        order.append(identifier)
        if order.count > maxCategories * 2 { order.removeFirst(order.count - maxCategories * 2) }
        defaults.set(order, forKey: categoryOrderKey)
        return order
    }

    private static let categoryOrderKey = "io.kirora.buttonCategories"

    /// Which of the Kirora categories registered now to keep beside the newest (the last in
    /// `order`): the most recently used, up to ``maxCategories`` in all. One the record
    /// doesn't know (older than it) goes first.
    static func categoriesToKeep(order: [String], registered: [String]) -> [String] {
        let newest = order.last
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: max)
        let others = registered.filter { $0 != newest }
            .sorted { (rank[$0] ?? -1) > (rank[$1] ?? -1) }
        return Array(others.prefix(maxCategories - 1))
    }

    private static func categories(_ center: UNUserNotificationCenter) async -> Set<UNNotificationCategory> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Unchecked<Set<UNNotificationCategory>>, Never>) in
            center.getNotificationCategories { continuation.resume(returning: Unchecked($0)) }
        }.value
    }

    // MARK: Reports

    /// The API deliveries are reported to: the extension's `KiroraApiUrl` Info.plist key, if
    /// the app uses another `apiUrl` than Kirora's.
    static var apiBase: URL {
        (Bundle.main.object(forInfoDictionaryKey: "KiroraApiUrl") as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://api.kirora.io")!
    }

    /// `trackingUrl`, if it's a `/t/p/…` address on the API's own scheme, host and port (under
    /// its path, if `apiUrl` has one), as every Kirora SDK checks; nil for anywhere else. The
    /// same as the app's `trustedTrackingUrl`, word for word.
    static func trustedTrackingUrl(_ trackingUrl: URL, apiBase: URL) -> URL? {
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

    /// The pushes being worked on, by request id: more than one for pushes that share a
    /// collapse id, which iOS uses as their request id.
    private static let active = Locked<[String: [PendingDelivery]]>([:])

    /// How long a finished push waits for its delivery report before it's shown.
    static let reportWait: Double = 5

    /// Waits for `task` up to `seconds`, then goes on without it; it keeps running.
    static func wait(for task: Task<Void, Never>, upTo seconds: Double) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = Locked(false)
            let resume: @Sendable () -> Void = {
                let first = resumed.withLock { resumed -> Bool in
                    defer { resumed = true }
                    return !resumed
                }
                if first { continuation.resume() }
            }
            let timer = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                resume()
            }
            Task {
                await task.value
                timer.cancel()
                resume()
            }
        }
    }

    /// Posts `delivered` to the push's own `trackingUrl`, which names the device and needs
    /// no credentials. A best-effort count: a network error, 429 or 5xx is tried once more,
    /// then dropped. A push without one (a test send) reports nothing.
    static func report(_ trackingUrl: URL?, session: URLSession = .shared) async {
        guard let trackingUrl else { return }
        var request = URLRequest(url: trackingUrl, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"event":"delivered"}"#.utf8)
        for _ in 0..<2 {
            let status = await send(request, session: session)
            // Any other 4xx (an expired or altered token) would be refused again.
            if let status, status < 500, status != 429 { return }
        }
    }

    private static func send(_ request: URLRequest, session: URLSession) async -> Int? {
        await withCheckedContinuation { continuation in
            session.dataTask(with: request) { _, response, _ in
                continuation.resume(returning: (response as? HTTPURLResponse)?.statusCode)
            }.resume()
        }
    }

    /// Downloads the push's image as an attachment, or nil if it can't be had in time.
    static func downloadAttachment(_ url: URL, session: URLSession = .shared) async -> UNNotificationAttachment? {
        guard url.scheme?.lowercased() == "https" else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 20)
        return await withCheckedContinuation { continuation in
            session.downloadTask(with: request) { location, response, _ in
                guard let location, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    continuation.resume(returning: nil)
                    return
                }
                // iOS reads the image's type from its file extension.
                let fileExtension = imageExtension(mimeType: http.mimeType, url: url)
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("kirora-\(UUID().uuidString)", isDirectory: true)
                let file = directory.appendingPathComponent("image.\(fileExtension)")
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: location, to: file)
                    continuation.resume(returning: try UNNotificationAttachment(identifier: "kirora-image", url: file))
                } catch {
                    continuation.resume(returning: nil)
                }
            }.resume()
        }
    }

    static func imageExtension(mimeType: String?, url: URL) -> String {
        switch mimeType?.lowercased() {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        default:
            let fromUrl = url.pathExtension.lowercased()
            return ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(fromUrl) ? fromUrl : "jpg"
        }
    }
}

/// One push being worked on. Hands its content over exactly once, whichever comes first:
/// the work finishing or iOS's time running out.
private final class PendingDelivery: @unchecked Sendable {
    private let state: Locked<(content: UNMutableNotificationContent, handler: ((UNNotificationContent) -> Void)?)>

    init(content: UNMutableNotificationContent, contentHandler: @escaping (UNNotificationContent) -> Void) {
        state = Locked((content, contentHandler))
    }

    func attach(_ attachment: UNNotificationAttachment) {
        state.withLock { state in
            if state.handler != nil { state.content.attachments = [attachment] }
        }
    }

    func finish() {
        let (content, handler) = state.withLock { state -> (UNNotificationContent, ((UNNotificationContent) -> Void)?) in
            defer { state.handler = nil }
            return (state.content, state.handler)
        }
        handler?(content)
    }
}

/// A Notification Service Extension that handles Kirora pushes and passes anyone else's
/// through unchanged. Subclass it as your extension's principal class; override
/// `didReceive` to handle other pushes, calling `super` for Kirora's.
open class KiroraNotificationServiceExtension: UNNotificationServiceExtension {
    /// This instance's push: iOS runs one instance per push, and may run several in one
    /// process.
    private var request: UNNotificationRequest?

    override open func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.request = request
        if !KiroraNotificationService.didReceive(request, withContentHandler: contentHandler) {
            contentHandler(request.content)
        }
    }

    override open func serviceExtensionTimeWillExpire() {
        if let request {
            KiroraNotificationService.serviceExtensionTimeWillExpire(for: request)
        } else {
            // A subclass that handled the push without calling `super.didReceive`: which push
            // was this instance's isn't known, so every one still being worked on is shown.
            KiroraNotificationService.serviceExtensionTimeWillExpire()
        }
    }
}

/// A value passed between tasks that is safe to, though its type doesn't say so:
/// UserNotifications' categories, immutable once made. This target depends on nothing, so
/// it has its own `UncheckedSendable`.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// FNV-1a, 64-bit, in hex: stable across launches and processes, unlike `hashValue`.
private func stableHash(_ text: String) -> String {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 0x100_0000_01b3
    }
    return String(hash, radix: 16)
}

/// A value guarded by a lock. This target depends on nothing, so it has its own.
fileprivate final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
#endif
