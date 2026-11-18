public import Foundation

/// Persistent Force Dark state, stored in `UserDefaults` so the site
/// exceptions survive relaunches.
public enum BrowserForceDarkSettings {
    /// `UserDefaults` key holding the hosts that keep their own appearance.
    public static let excludedHostsKey = "browserForceDarkExcludedHosts"

    /// Posted after the exception list changes, so open pages can re-apply
    /// the theme without waiting for the next navigation.
    public static let excludedHostsDidChangeNotification = Notification.Name(
        "cmux.browserForceDarkExcludedHostsDidChange"
    )

    /// The excluded hosts, normalized and de-duplicated.
    public static func excludedHosts(defaults: UserDefaults = .standard) -> [String] {
        BrowserForceDarkPolicy.normalizedHosts(defaults.stringArray(forKey: excludedHostsKey) ?? [])
    }

    /// Replaces the exception list; entries are normalized and de-duplicated.
    public static func setExcludedHosts(_ hosts: [String], defaults: UserDefaults = .standard) {
        defaults.set(BrowserForceDarkPolicy.normalizedHosts(hosts), forKey: excludedHostsKey)
        NotificationCenter.default.post(name: excludedHostsDidChangeNotification, object: nil)
    }

    /// Whether `host` is covered by an exception, directly or as a subdomain.
    public static func isHostExcluded(_ host: String, defaults: UserDefaults = .standard) -> Bool {
        BrowserForceDarkPolicy.isExcluded(host: host, in: excludedHosts(defaults: defaults))
    }

    /// Adds or removes one host exception.
    /// - Parameters:
    ///   - host: The site's host; normalized before it is stored.
    ///   - excluded: `true` to stop Force Dark on the site, `false` to re-enable it.
    public static func setHostExcluded(
        _ host: String,
        excluded: Bool,
        defaults: UserDefaults = .standard
    ) {
        let normalized = BrowserForceDarkPolicy.normalizeHost(host)
        guard !normalized.isEmpty else { return }
        var hosts = excludedHosts(defaults: defaults)
        if excluded {
            guard !hosts.contains(normalized) else { return }
            hosts.append(normalized)
        } else {
            guard hosts.contains(normalized) else { return }
            hosts.removeAll { $0 == normalized }
        }
        setExcludedHosts(hosts, defaults: defaults)
    }
}
