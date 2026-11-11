public import Foundation

/// The directories cmux searches for Ghostty theme files, in lookup order.
///
/// Since the Ghostty-config decoupling patch these are only cmux's own
/// locations: the user theme directory `~/.config/cmux/themes` first (a user
/// file overrides a bundled theme with the same name), followed by the theme
/// library bundled inside the running cmux app (see Issue #71 for the managed
/// default theme library). Ghostty's own theme locations
/// (`$GHOSTTY_RESOURCES_DIR`, XDG data dirs, `/Applications/Ghostty.app`,
/// `~/.config/ghostty`, the Ghostty App Support directories) are no longer
/// searched.
///
/// `cmux themes` and the Settings theme gallery both list themes from this
/// one list, so they always offer the same names. Only directories that exist
/// are returned, each once.
///
/// ```swift
/// let directories = GhosttyThemeDirectories(
///     environment: ProcessInfo.processInfo.environment,
///     bundledThemeDirectories: [Bundle.main.resourceURL!.appendingPathComponent("ghostty/themes")]
/// ).urls
/// ```
public struct GhosttyThemeDirectories {
    private let environment: [String: String]
    private let bundledThemeDirectories: [URL]
    private let fileManager: FileManager

    /// Creates the resolver.
    /// - Parameters:
    ///   - environment: The process environment; reads `CFFIXED_USER_HOME`,
    ///     `XDG_CONFIG_HOME` and `HOME` for the config home directory.
    ///   - bundledThemeDirectories: Theme directories inside the running cmux
    ///     bundle or checkout, searched first.
    ///   - fileManager: Injected for tests; defaults to `FileManager.default`.
    public init(
        environment: [String: String],
        bundledThemeDirectories: [URL],
        fileManager: FileManager = .default
    ) {
        self.environment = environment
        self.bundledThemeDirectories = bundledThemeDirectories
        self.fileManager = fileManager
    }

    /// The existing theme directories, most preferred first.
    public var urls: [URL] {
        var urls: [URL] = []
        var seen: Set<String> = []

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            guard fileManager.fileExists(atPath: standardized.path) else { return }
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        // The user theme directory comes first so a user file with the same
        // name as a bundled theme wins (Issue #71 acceptance).
        append(
            CmuxGhosttyConfigPathResolver.configHomeDirectory(environment: environment)
                .appendingPathComponent("cmux/themes", isDirectory: true)
        )
        bundledThemeDirectories.forEach(append)
        return urls
    }
}
