import Foundation

/// What the app's lifecycle tells the SDK.
enum LifecycleEvent: Sendable, Equatable {
    /// The app launched into the foreground.
    case launched
    /// The app came back to the foreground.
    case foreground
    case background
    /// Every 5 minutes in the foreground: time in the foreground never ends a visit.
    case keepAlive
    /// The network came back.
    case online
}

/// The app's lifecycle, from UIKit in the app and driven by hand in tests.
protocol AppLifecycleSource: AnyObject, Sendable {
    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void)
    func stop()
    /// Runs `work`, asking iOS for time to finish it if the app is going to the background.
    func runInBackground(_ name: String, _ work: @escaping @Sendable () async -> Void)
}

/// For platforms without UIKit, and clients without a lifecycle (e.g. on macOS).
final class NoLifecycle: AppLifecycleSource, @unchecked Sendable {
    func start(_ handler: @escaping @Sendable (LifecycleEvent) -> Void) {}
    func stop() {}
    func runInBackground(_ name: String, _ work: @escaping @Sendable () async -> Void) {
        Task { await work() }
    }
}

let applicationInstalledEvent = "Application Installed"
let applicationOpenedEvent = "Application Opened"
let applicationUpdatedEvent = "Application Updated"
let applicationBackgroundedEvent = "Application Backgrounded"

/// The `Application …` events, for `trackAppLifecycle`.
struct LifecycleEvents {
    private struct StoredVersion: Codable, Equatable {
        var version: String?
        var build: String?
    }

    let store: KeyValueStore
    let deviceInfo: DeviceInfo

    /// The events for a launch: installed or updated, if so, then opened.
    func launch() -> [(String, [String: JSONValue])] {
        let current = currentVersion()
        let previous = store.json(StoredVersion.self, StorageKeys.appVersion)
        store.setJSON(current, for: StorageKeys.appVersion)
        var events: [(String, [String: JSONValue])] = []
        if let previous {
            if previous != current {
                var properties = versionProperties(current)
                if let version = previous.version { properties["previous_version"] = .string(version) }
                if let build = previous.build { properties["previous_build"] = .string(build) }
                events.append((applicationUpdatedEvent, properties))
            }
        } else {
            events.append((applicationInstalledEvent, versionProperties(current)))
        }
        events.append(opened(fromBackground: false))
        return events
    }

    func opened(fromBackground: Bool) -> (String, [String: JSONValue]) {
        var properties = versionProperties(currentVersion())
        properties["from_background"] = .bool(fromBackground)
        return (applicationOpenedEvent, properties)
    }

    private func currentVersion() -> StoredVersion {
        StoredVersion(version: deviceInfo.appVersion(), build: deviceInfo.appBuild())
    }

    private func versionProperties(_ version: StoredVersion) -> [String: JSONValue] {
        var properties: [String: JSONValue] = [:]
        if let value = version.version { properties["version"] = .string(value) }
        if let value = version.build { properties["build"] = .string(value) }
        return properties
    }
}
