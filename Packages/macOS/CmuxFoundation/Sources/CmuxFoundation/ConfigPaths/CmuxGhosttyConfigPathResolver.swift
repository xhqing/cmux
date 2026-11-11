public import Foundation

/// Resolves cmux's own Ghostty-format config file. Since the Ghostty-config
/// decoupling patch, the config lives at one fixed location —
/// `<home>/.config/cmux/config.ghostty` — regardless of the running bundle
/// identifier or release channel, so the same config is shared by every cmux
/// build installed on the machine.
///
/// `home` resolves from `CFFIXED_USER_HOME` (test override), then
/// `XDG_CONFIG_HOME`, then `$HOME`; when none is usable it falls back to the
/// current user's `~/.config`.
public struct CmuxGhosttyConfigPathResolver {
    /// The bundle identifier of the released cmux app. Kept as the canonical
    /// identifier for IPC targets (theme reload notifications) and as a legacy
    /// App Support migration source; it no longer selects a config directory.
    public static let releaseBundleIdentifier = "com.cmuxterm.app"

    public init() {}

    /// The config home directory (`<home>/.config`), honoring
    /// `CFFIXED_USER_HOME` for tests, then `XDG_CONFIG_HOME`, then `$HOME`.
    public static func configHomeDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let fixedHome = environment["CFFIXED_USER_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !fixedHome.isEmpty {
            return URL(fileURLWithPath: fixedHome, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
        }
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgConfigHome.isEmpty {
            return URL(fileURLWithPath: xdgConfigHome, isDirectory: true)
        }
        if let home = environment["HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(".config", isDirectory: true)
        }
        return URL(
            fileURLWithPath: NSString(string: "~/.config").expandingTildeInPath,
            isDirectory: true
        )
    }

    /// The directory that holds cmux's config files, fixed at
    /// `<home>/.config/cmux`.
    public func configDirectoryURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        Self.configHomeDirectory(environment: environment)
            .appendingPathComponent("cmux", isDirectory: true)
    }

    /// The path cmux writes edits to: always `config.ghostty` under the fixed
    /// `~/.config/cmux` directory.
    public func editableConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configDirectoryURL(environment: environment)
            .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    /// The currently active config URL if one exists on disk, otherwise the
    /// editable target that a first write should create.
    public func activeOrEditableConfigURL(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL {
        loadConfigURLs(environment: environment, fileManager: fileManager).first
            ?? editableConfigURL(environment: environment)
    }

    /// The ordered list of cmux config files to load from the fixed
    /// `~/.config/cmux` directory. A non-empty `config.ghostty` wins over a
    /// legacy `config`; empty or missing files are skipped.
    public func loadConfigURLs(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> [URL] {
        preferredExistingConfigURLs(
            in: configDirectoryURL(environment: environment),
            fileManager: fileManager
        )
    }

    /// Idempotently migrates the pre-decoupling config from Application
    /// Support: when `~/Library/Application Support/<bundle-id>/config.ghostty`
    /// exists and `~/.config/cmux/config.ghostty` does not, the file is copied
    /// to the new location. Runs once per launch; a config already present at
    /// the new path is never overwritten.
    ///
    /// - Parameters:
    ///   - bundleIdentifiers: The legacy bundle identifiers to check, most
    ///     specific first (typically the running build's identifier followed
    ///     by the release identifier).
    ///   - appSupportDirectory: The user's Application Support directory.
    public func migrateLegacyAppSupportConfigIfNeeded(
        bundleIdentifiers: [String],
        appSupportDirectory: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) {
        let targetURL = editableConfigURL(environment: environment)
        guard !fileManager.fileExists(atPath: targetURL.path) else { return }

        for bundleIdentifier in bundleIdentifiers where !bundleIdentifier.isEmpty {
            let sourceURL = appSupportDirectory
                .appendingPathComponent(bundleIdentifier, isDirectory: true)
                .appendingPathComponent("config.ghostty", isDirectory: false)
            guard fileManager.fileExists(atPath: sourceURL.path),
                  let contents = try? Data(contentsOf: sourceURL) else {
                continue
            }
            do {
                try fileManager.createDirectory(
                    at: targetURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try contents.write(to: targetURL, options: .atomic)
            } catch {
                // Best-effort: never block loading on a failed migration.
            }
            return
        }
    }

    private func preferredExistingConfigURLs(
        in directory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let legacyConfig = directory.appendingPathComponent("config", isDirectory: false)
        let configGhostty = directory.appendingPathComponent("config.ghostty", isDirectory: false)
        if isNonEmptyConfigFile(configGhostty, fileManager: fileManager) {
            // Do not layer legacy config under config.ghostty. Older builds wrote
            // explicit dark colors there, which blocks appearance-driven themes.
            return [configGhostty]
        }
        if isNonEmptyConfigFile(legacyConfig, fileManager: fileManager) {
            return [legacyConfig]
        }
        return []
    }

    private func isNonEmptyConfigFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }

        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return isNonEmptySymlinkTarget(url, fileManager: fileManager)
        }

        return isNonEmptyRegularFile(url, fileManager: fileManager)
    }

    private func isNonEmptySymlinkTarget(_ url: URL, fileManager: FileManager) -> Bool {
        isNonEmptyRegularFile(url.resolvingSymlinksInPath(), fileManager: fileManager)
    }

    private func isNonEmptyRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }
}
