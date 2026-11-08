import Foundation

/// Whether the markdown viewer loads safe remote images without a per-image
/// click.
///
/// The shell still owns the safety decision: only HTTPS URLs with no
/// credentials, an optional port of 443 and a public host are eligible, and the
/// host still records the approval behind the `cmux-remote-image://` scheme
/// handler before it fetches anything. Turning this on only removes the
/// "Load this image" click that upstream requires for every image, so a README
/// renders its shields.io badges like GitHub and VS Code previews do.
enum MarkdownRemoteImageSettings {
    /// UserDefaults / cmux.json key (`markdown.loadRemoteImages`).
    static let key = "markdown.loadRemoteImages"
    /// cmux fork (xhqing): defaults to `true` so remote images (badges in
    /// READMEs) render out of the box; turn it off to restore the upstream
    /// per-image consent flow.
    static let builtInDefault = true

    /// The persistent default, honoring `markdown.loadRemoteImages` from
    /// UserDefaults / cmux.json and falling back to ``builtInDefault``.
    static func resolvedDefault(defaults: UserDefaults = .standard) -> Bool {
        guard let raw = defaults.object(forKey: key) as? NSNumber else {
            return builtInDefault
        }
        return raw.boolValue
    }

    /// Persists `enabled` as the default `markdown.loadRemoteImages` value.
    static func setDefault(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }

    /// Removes the persisted value so new viewers fall back to the built-in
    /// default again.
    static func resetDefault(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
