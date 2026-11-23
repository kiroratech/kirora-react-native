import Foundation

/// What the device says of itself, read when needed: the user may change language or time
/// zone while the app runs. Never a hardware or advertising id, or a device model.
struct DeviceInfo {
    /// The screen in points, portrait, and its scale.
    struct Screen: Sendable, Equatable {
        var width: Int
        var height: Int
        var density: Double
    }

    var appName: () -> String? = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName")) as? String
    }
    var bundleId: () -> String? = { Bundle.main.bundleIdentifier }
    var screen: () -> Screen? = { deviceScreen.current }
    var appVersion: () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
    var appBuild: () -> String? = { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String }
    var osVersion: () -> String? = { DeviceInfo.systemVersion() }
    /// The user's preferred language as BCP 47 (`en-GB`), as the platform gives it.
    var locale: () -> String? = { Locale.preferredLanguages.first }
    var timezone: () -> String? = { TimeZone.current.identifier }

    /// As `UIDevice.systemVersion` writes it (`17.4`, `17.4.1`), without needing the main
    /// thread.
    static func systemVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// An event's `context`, in the fields Kirora accepts (Segment's names): the app, the OS,
    /// the screen, the device (the SDK's own random id, never a hardware one, and no model),
    /// the visit, language and time zone. What the device can't read is left out.
    func eventContext(deviceId: String, sessionId: String?) -> [String: JSONValue] {
        func object(_ fields: [(String, String?)]) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: fields.compactMap { key, value in
                value.flatMap { $0.isEmpty ? nil : (key, JSONValue.string($0)) }
            }))
        }
        var context: [String: JSONValue] = [
            "app": object([("name", appName()), ("version", appVersion()), ("build", appBuild()), ("namespace", bundleId())]),
            "os": object([("name", "iOS"), ("version", osVersion())]),
            "device": .object(["id": .string(deviceId), "manufacturer": .string("Apple"), "type": .string("ios")]),
        ]
        if let screen = screen() {
            context["screen"] = .object([
                "width": .int(Int64(screen.width)), "height": .int(Int64(screen.height)),
                "density": .double(screen.density),
            ])
        }
        for (key, value) in [("sessionId", sessionId), ("locale", locale()), ("timezone", timezone())] {
            if let value, !value.isEmpty { context[key] = .string(value) }
        }
        return context
    }

    /// The four device fields a push registration carries, leaving out what the device
    /// can't read and never sending an empty string.
    func registrationDetails() -> [String: JSONValue] {
        var details: [String: JSONValue] = [:]
        for (key, value) in [
            ("appVersion", appVersion()), ("osVersion", osVersion()),
            ("locale", locale()), ("timezone", timezone()),
        ] {
            if let value, !value.isEmpty { details[key] = .string(value) }
        }
        return details
    }
}

// Closures read only immutable globals (`Bundle.main`, `ProcessInfo`, `Locale`).
extension DeviceInfo: @unchecked Sendable {}

/// `device.id`: a random id made on first use and kept in the app's own storage. It is
/// also the device's `externalInstallationId` for push.
struct DeviceId: Sendable {
    let store: KeyValueStore

    func value() -> String {
        store.string(StorageKeys.deviceId, orSet: newId)
    }

    /// The id if one exists, without making one.
    var existing: String? { store.string(StorageKeys.deviceId) }

    /// The installation's `deviceSecret`, made on first use and kept as long as the id: sent
    /// with every `PUT /devices`, it lets a sign-out detach the device with no user token
    /// held (after a relaunch, before identify()). It can only detach.
    func secret() -> String {
        store.string(StorageKeys.deviceSecret, orSet: newDeviceSecret)
    }

    func remove() {
        store.set(nil, for: StorageKeys.deviceId)
        store.set(nil, for: StorageKeys.deviceSecret)
    }
}

/// 32 random bytes, base64url without padding (43 characters).
func newDeviceSecret() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// The screen, read once on the main thread as the client starts (UIKit's own only answers
/// there); nil where there's no UIKit.
let deviceScreen = Locked<DeviceInfo.Screen?>(nil)
