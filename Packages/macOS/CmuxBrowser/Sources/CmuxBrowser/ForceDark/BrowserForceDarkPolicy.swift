public import Foundation

/// Decides whether the Force Dark engine may run on a page.
///
/// Force Dark only touches web pages (`http` / `https` with a host). A page
/// whose host is on the exception list keeps the plain `darkAqua` appearance,
/// so a site that already ships its own dark theme is not darkened twice.
public struct BrowserForceDarkPolicy: Sendable {
    /// Whether the Force Dark browser theme is the selected theme.
    public let isEnabled: Bool
    /// Normalized hosts, and their subdomains, that Force Dark must skip.
    public let excludedHosts: [String]

    /// Creates a policy.
    /// - Parameters:
    ///   - isEnabled: `true` when the browser theme is Force Dark.
    ///   - excludedHosts: Hosts that keep their own appearance; entries are
    ///     normalized, de-duplicated, and empty entries are dropped.
    public init(isEnabled: Bool, excludedHosts: [String] = []) {
        self.isEnabled = isEnabled
        self.excludedHosts = Self.normalizedHosts(excludedHosts)
    }

    /// Whether the engine should be injected into `url`.
    /// - Parameter url: The page's top-level URL.
    /// - Returns: `true` only for `http` / `https` pages whose host is not excluded.
    public func shouldApply(to url: URL?) -> Bool {
        guard isEnabled, let url else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return false
        }
        let host = Self.normalizeHost(url.host ?? "")
        guard !host.isEmpty else { return false }
        return !Self.isExcluded(host: host, in: excludedHosts)
    }

    /// Reduces a host name, or a whole URL, to the form exceptions are stored in:
    /// lowercase, no scheme, no user info, no port, no path, no trailing dot.
    /// - Parameter raw: A host name such as `Example.com.` or a URL.
    /// - Returns: The normalized host, or an empty string when none remains.
    public static func normalizeHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeRange = value.range(of: "://") {
            value = String(value[schemeRange.upperBound...])
        }
        if let cut = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            value = String(value[..<cut])
        }
        if let userInfoEnd = value.lastIndex(of: "@") {
            value = String(value[value.index(after: userInfoEnd)...])
        }
        if value.hasPrefix("[") {
            // IPv6 literal: keep the brackets and drop an optional port.
            if let literalEnd = value.firstIndex(of: "]") {
                value = String(value[...literalEnd])
            }
        } else if let portStart = value.firstIndex(of: ":") {
            value = String(value[..<portStart])
        }
        while value.hasSuffix(".") {
            value.removeLast()
        }
        return value
    }

    /// Whether `host` is an excluded entry or one of its subdomains.
    /// - Parameters:
    ///   - host: The page host; normalized before comparing.
    ///   - excludedHosts: Candidate entries; normalized before comparing.
    public static func isExcluded(host: String, in excludedHosts: [String]) -> Bool {
        let normalized = normalizeHost(host)
        guard !normalized.isEmpty else { return false }
        return excludedHosts.contains { entry in
            let candidate = normalizeHost(entry)
            guard !candidate.isEmpty else { return false }
            return normalized == candidate || normalized.hasSuffix(".\(candidate)")
        }
    }

    /// Normalized, de-duplicated, empty-free copy of `hosts`, in input order.
    static func normalizedHosts(_ hosts: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for host in hosts {
            let normalized = normalizeHost(host)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            result.append(normalized)
        }
        return result
    }
}
