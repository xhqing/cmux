public import Foundation
public import WebKit

/// Builds the vendored Dark Reader engine and the document-start user script
/// that applies it to a browser page.
///
/// The engine only runs while the Force Dark browser theme is selected and the
/// page is not on the site exception list; see ``BrowserForceDarkPolicy``. The
/// engine source is `Resources/ForceDark/darkreader.js` (Dark Reader 4.9.135,
/// MIT), vendored so neither the page nor the network can swap it out.
public enum BrowserForceDarkRuntime {
    /// Dark Reader options for every injection path. Brightness / contrast /
    /// sepia tuning is deliberately out of scope.
    static let themeOptionsJSON = #"{"brightness":100,"contrast":100,"sepia":0}"#

    /// The bundled Dark Reader source, or `nil` when the resource is missing.
    public static var librarySource: String? { cachedLibrarySource }

    /// Enables Dark Reader in a document that already has the library loaded.
    /// Pages that never received the engine need ``bootstrapSource(policy:url:)``.
    public static let enableScript = """
    (function () {
        try {
            if (!globalThis.DarkReader || typeof globalThis.DarkReader.enable !== "function") {
                return false;
            }
            globalThis.DarkReader.enable(\(themeOptionsJSON));
            globalThis.__cmuxForceDarkApplied = true;
            return true;
        } catch (error) {
            console.warn("[cmux] Force Dark enable failed", error);
            return false;
        }
    })();
    """

    /// Restores a page that the engine has darkened.
    public static let disableScript = """
    (function () {
        try {
            if (globalThis.DarkReader && typeof globalThis.DarkReader.disable === "function") {
                globalThis.DarkReader.disable();
            }
            globalThis.__cmuxForceDarkApplied = false;
        } catch (error) {
            console.warn("[cmux] Force Dark disable failed", error);
        }
    })();
    """

    /// Builds the document-start script for one page: the engine plus a thin
    /// bootstrap that loads it, re-checks the page's own location against the
    /// excluded hosts, and enables it once per document.
    /// - Parameters:
    ///   - policy: The current Force Dark policy.
    ///   - url: The page's top-level URL.
    /// - Returns: `nil` when the policy skips the page or the engine is missing.
    public static func bootstrapSource(policy: BrowserForceDarkPolicy, url: URL?) -> String? {
        guard policy.shouldApply(to: url), let librarySource else { return nil }
        return """
        (function () {
            if (globalThis.__cmuxForceDarkApplied === true) {
                return;
            }
            var config = \(configurationJSON(policy));
            try {
                var location = globalThis.location;
                var scheme = String(location.protocol || "").toLowerCase();
                if (scheme !== "http:" && scheme !== "https:") {
                    return;
                }
                var host = String(location.hostname || "").toLowerCase();
                while (host.slice(-1) === ".") {
                    host = host.slice(0, -1);
                }
                if (!host) {
                    return;
                }
                var excludedHosts = config.excludedHosts;
                for (var index = 0; index < excludedHosts.length; index += 1) {
                    var entry = excludedHosts[index];
                    if (host === entry || host.slice(-(entry.length + 1)) === "." + entry) {
                        return;
                    }
                }
                if (!globalThis.DarkReader) {
                    var module = { exports: {} };
                    (function (exports, module, define) {
        \(librarySource)
                    })(module.exports, module, void 0);
                    globalThis.DarkReader = module.exports;
                }
            } catch (error) {
                console.warn("[cmux] Force Dark engine failed to load", error);
                return;
            }
            \(enableScript)
        })();
        """
    }

    /// Wraps ``bootstrapSource(policy:url:)`` in the user script the browsing
    /// web views register: document start, main frame only.
    /// - Parameters:
    ///   - policy: The current Force Dark policy.
    ///   - url: The page's top-level URL.
    /// - Returns: `nil` when the policy skips the page or the engine is missing.
    public static func makeUserScript(
        policy: BrowserForceDarkPolicy,
        url: URL?
    ) -> WKUserScript? {
        guard let source = bootstrapSource(policy: policy, url: url) else { return nil }
        return WKUserScript(
            source: source,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
    }

    private static func configurationJSON(_ policy: BrowserForceDarkPolicy) -> String {
        let payload = ["excludedHosts": policy.excludedHosts]
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"excludedHosts":[]}"#
        }
        return json
    }

    // MARK: - Bundled engine

    private static let resourceBundleName = "CmuxBrowser_CmuxBrowser"
    private static let libraryResourceName = "darkreader"

    private static let cachedLibrarySource: String? = loadLibrarySource()

    private static func loadLibrarySource() -> String? {
        for url in libraryResourceURLs() {
            guard let source = try? String(contentsOf: url, encoding: .utf8),
                  !source.isEmpty else { continue }
            return source
        }
        return nil
    }

    private static func libraryResourceURLs() -> [URL] {
        var urls: [URL] = []
        var resourceBundles: [Bundle] = []
        for directory in candidateResourceDirectories() {
            let bundleURL = directory.appendingPathComponent(
                resourceBundleName + ".bundle",
                isDirectory: true
            )
            if let bundle = Bundle(url: bundleURL) {
                resourceBundles.append(bundle)
            }
        }
        for bundle in resourceBundles {
            for subdirectory in ["ForceDark", nil] as [String?] {
                if let url = bundle.url(
                    forResource: libraryResourceName,
                    withExtension: "js",
                    subdirectory: subdirectory
                ) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func candidateResourceDirectories() -> [URL] {
        var directories: [URL] = []
        #if DEBUG
        // SwiftPM's test runner exposes the resource bundle through these.
        let environment = ProcessInfo.processInfo.environment
        for key in ["PACKAGE_RESOURCE_BUNDLE_PATH", "PACKAGE_RESOURCE_BUNDLE_URL"] {
            if let path = environment[key] {
                directories.append(URL(fileURLWithPath: path, isDirectory: true))
            }
        }
        #endif
        let finderBundle = Bundle(for: BrowserForceDarkRuntimeBundleFinder.self)
        directories.append(contentsOf: [
            Bundle.main.resourceURL,
            finderBundle.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            finderBundle.bundleURL.deletingLastPathComponent(),
        ].compactMap { $0 })
        return directories
    }
}

private final class BrowserForceDarkRuntimeBundleFinder {}
