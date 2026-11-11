import CoreText
import Foundation
import Testing
@testable import CmuxTerminalCore

/// In-memory config files keyed by absolute path.
private struct InMemoryConfigFiles: GhosttyConfigFileReading {
    var contentsByPath: [String: String]

    func fileSize(atPath path: String) -> Int? {
        contentsByPath[path].map { $0.lengthOfBytes(using: .utf8) }
    }

    func contents(atPath path: String) -> String? {
        contentsByPath[path]
    }
}

private struct NoFonts: GhosttyFontProbing {
    func discoveredFont(named _: String, size _: CGFloat, weightTrait _: CGFloat?) -> CTFont? { nil }
    func configuredFont(named _: String, size _: CGFloat) -> CTFont? { nil }
}

@Suite struct GhosttyConfigLiveReloadSnapshotTests {
    private func snapshot(
        _ files: [String: String],
        topLevelPaths: [String] = ["/home/.config/cmux/config", "/home/.config/cmux/config.ghostty"]
    ) -> GhosttyConfigLiveReloadSnapshot {
        GhosttyConfigDiscovery(
            fileReader: InMemoryConfigFiles(contentsByPath: files),
            fontProbe: NoFonts()
        ).liveReloadSnapshot(
            topLevelPaths: topLevelPaths,
            configHomeDirectory: "/home/.config",
            resolvesSymlinks: false
        )
    }

    @Test func watchesMissingTopLevelCandidatesSoCreatingOneIsNoticed() {
        let result = snapshot(["/home/.config/cmux/config": "font-size = 13\n"])

        #expect(result.watchedPaths == [
            "/home/.config/cmux/config",
            "/home/.config/cmux/config.ghostty",
        ])
        #expect(result.contentsByPath == ["/home/.config/cmux/config": "font-size = 13\n"])
    }

    @Test func followsRelativeOptionalAndNestedConfigFileIncludes() {
        let result = snapshot([
            "/home/.config/cmux/config": """
            config-file = colors.conf
            config-file = ?"/opt/shared/optional.conf"
            """,
            "/home/.config/cmux/colors.conf": "config-file = nested/keys.conf\n",
            "/home/.config/cmux/nested/keys.conf": "keybind = cmd+k=clear_screen\n",
        ])

        #expect(result.watchedPaths.contains("/home/.config/cmux/colors.conf"))
        #expect(result.watchedPaths.contains("/opt/shared/optional.conf"))
        #expect(result.watchedPaths.contains("/home/.config/cmux/nested/keys.conf"))
        #expect(result.contentsByPath["/home/.config/cmux/nested/keys.conf"] == "keybind = cmd+k=clear_screen\n")
        #expect(result.contentsByPath["/opt/shared/optional.conf"] == nil)
    }

    @Test func includeCycleTerminates() {
        let result = snapshot([
            "/home/.config/cmux/config": "config-file = a.conf\n",
            "/home/.config/cmux/a.conf": "config-file = config\n",
        ])

        #expect(result.watchedPaths.filter { $0 == "/home/.config/cmux/config" }.count == 1)
        #expect(result.watchedPaths.contains("/home/.config/cmux/a.conf"))
    }

    @Test func watchesUserThemeFilesForBothSidesOfAConditionalTheme() {
        let result = snapshot([
            "/home/.config/cmux/config": "theme = light:Paper,dark:Night Owl\n",
            "/home/.config/cmux/themes/Night Owl": "background = #011627\n",
        ])

        #expect(result.watchedPaths.contains("/home/.config/cmux/themes/Paper"))
        #expect(result.watchedPaths.contains("/home/.config/cmux/themes/Night Owl"))
        #expect(result.contentsByPath["/home/.config/cmux/themes/Night Owl"] == "background = #011627\n")
    }

    @Test func watchesAbsoluteThemePathAsWritten() {
        let result = snapshot([
            "/home/.config/cmux/config": "theme = /Users/me/themes/custom\n",
        ])

        #expect(result.watchedPaths.contains("/Users/me/themes/custom"))
        #expect(!result.watchedPaths.contains { $0.hasSuffix("cmux/themes//Users/me/themes/custom") })
    }

    @Test func themeEditChangesContentsButNotWatchedPaths() {
        let before = snapshot([
            "/home/.config/cmux/config": "theme = Mine\n",
            "/home/.config/cmux/themes/Mine": "background = #000000\n",
        ])
        let after = snapshot([
            "/home/.config/cmux/config": "theme = Mine\n",
            "/home/.config/cmux/themes/Mine": "background = #111111\n",
        ])

        #expect(before.watchedPaths == after.watchedPaths)
        #expect(!before.hasSameContents(as: after))
    }

    @Test func liveReloadTopLevelPathsContainOnlyCmuxCandidates() {
        let discovery = GhosttyConfigDiscovery(
            fileReader: InMemoryConfigFiles(contentsByPath: [:]),
            fontProbe: NoFonts()
        )

        let paths = discovery.liveReloadTopLevelPaths(
            configHomeDirectory: "/home/.config"
        )

        #expect(paths == [
            "/home/.config/cmux/config",
            "/home/.config/cmux/config.ghostty",
        ])
        #expect(Set(paths).count == paths.count)
    }

    /// cmux reads `<configHome>/cmux/config.ghostty` when `$XDG_CONFIG_HOME`
    /// is set, so an edit there must be watched and reloaded.
    @Test func readerWatchesTheConfigUnderXDGConfigHome() {
        let files = InMemoryConfigFiles(contentsByPath: [
            "/xdg-home/cmux/config.ghostty": "font-size = 13\n",
        ])
        let reader = DiscoveryGhosttyConfigLiveReloadSnapshotReader(
            configHomeDirectory: "/xdg-home"
        ) {
            GhosttyConfigDiscovery(fileReader: files, fontProbe: NoFonts())
        }

        let result = reader.snapshot()

        #expect(result.watchedPaths.contains("/xdg-home/cmux/config"))
        #expect(result.watchedPaths.contains("/xdg-home/cmux/config.ghostty"))
        #expect(result.contentsByPath["/xdg-home/cmux/config.ghostty"] == "font-size = 13\n")
    }

    /// Ghostty's own config locations are no longer loaded, so they are not
    /// watched either.
    @Test func readerDoesNotWatchGhosttyOwnConfigLocations() {
        let files = InMemoryConfigFiles(contentsByPath: [
            "/xdg-home/ghostty/config": "background = #ff0000\n",
            "/xdg-home/cmux/config.ghostty": "font-size = 13\n",
        ])
        let reader = DiscoveryGhosttyConfigLiveReloadSnapshotReader(
            configHomeDirectory: "/xdg-home"
        ) {
            GhosttyConfigDiscovery(fileReader: files, fontProbe: NoFonts())
        }

        let result = reader.snapshot()

        #expect(!result.watchedPaths.contains("/xdg-home/ghostty/config"))
        #expect(!result.watchedPaths.contains("/xdg-home/ghostty/config.ghostty"))
        #expect(result.watchedPaths.contains("/xdg-home/cmux/config.ghostty"))
    }
}
