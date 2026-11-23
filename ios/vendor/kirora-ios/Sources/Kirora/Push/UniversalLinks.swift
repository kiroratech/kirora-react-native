import Foundation

/// The hosts of the app's own universal links, from its Info.plist's
/// `KiroraUniversalLinkHosts`: `example.com`, or `*.example.com` for its subdomains, as in
/// the app's associated domains, which an app can't read at runtime.
let universalLinkHosts: [String] =
    Bundle.main.object(forInfoDictionaryKey: "KiroraUniversalLinkHosts") as? [String] ?? []

/// Whether a push's link is one of the app's own universal links, to be handed to the app
/// delegate as iOS would, rather than opened. Only for hosts the app lists: a delegate's
/// answer doesn't say. Flutter's and React Native's say they handled any web link.
func isOwnUniversalLink(_ url: URL, hosts: [String]) -> Bool {
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          let host = url.host?.lowercased() else { return false }
    return hosts.contains { listed in
        let listed = listed.lowercased()
        if listed.hasPrefix("*.") {
            let domain = listed.dropFirst(2)
            return host.hasSuffix("." + domain)
        }
        return host == listed
    }
}
