public import Foundation

/// ``GhosttyConfigLiveReloadSnapshotReading`` that resolves cmux's Ghostty
/// config files through ``GhosttyConfigDiscovery`` and reads them from disk.
///
/// Every input is a `Sendable` value captured at construction, and the
/// discovery value (with its non-`Sendable` file reader) is built inside each
/// call, so ``snapshot()`` is safe to call from any thread.
///
/// ```swift
/// let reader = DiscoveryGhosttyConfigLiveReloadSnapshotReader(
///     configHomeDirectory: DiscoveryGhosttyConfigLiveReloadSnapshotReader
///         .configHomeDirectory(environment: ProcessInfo.processInfo.environment)
/// )
/// ```
public struct DiscoveryGhosttyConfigLiveReloadSnapshotReader: GhosttyConfigLiveReloadSnapshotReading {
    private let configHomeDirectory: String
    private let makeDiscovery: @Sendable () -> GhosttyConfigDiscovery

    /// Creates a reader.
    ///
    /// - Parameters:
    ///   - configHomeDirectory: The config home that holds cmux's
    ///     `cmux/config` files and `cmux/themes`.
    ///   - makeDiscovery: Builds the discovery value for one read. Defaults to
    ///     a `FileManager`-backed discovery; tests inject an in-memory reader.
    public init(
        configHomeDirectory: String,
        makeDiscovery: @escaping @Sendable () -> GhosttyConfigDiscovery = { GhosttyConfigDiscovery() }
    ) {
        self.configHomeDirectory = configHomeDirectory
        self.makeDiscovery = makeDiscovery
    }

    /// The config home cmux uses: `$XDG_CONFIG_HOME` when set to a non-empty
    /// value, otherwise `~/.config`.
    ///
    /// - Parameter environment: The process environment.
    /// - Returns: An absolute or `~`-prefixed directory path.
    public static func configHomeDirectory(environment: [String: String]) -> String {
        if let xdgConfigHome = environment["XDG_CONFIG_HOME"],
           !xdgConfigHome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return xdgConfigHome
        }
        return "~/.config"
    }

    public func snapshot() -> GhosttyConfigLiveReloadSnapshot {
        let discovery = makeDiscovery()
        return discovery.liveReloadSnapshot(
            topLevelPaths: discovery.liveReloadTopLevelPaths(
                configHomeDirectory: configHomeDirectory
            ),
            configHomeDirectory: configHomeDirectory
        )
    }
}
