import AppKit
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7161
/// and https://github.com/manaflow-ai/cmux/issues/10199.
///
/// cmux's managed default terminal theme (GitHub Dark Default since
/// Issue #71) applies whenever the user has no authored theme or terminal
/// colors; the "Adapt Default Theme to Appearance" preference no longer
/// gates it. Other settings keep that base; explicit appearance preserves
/// Ghostty's colors.
@Suite(.serialized) struct GhosttyConfigManagedDefaultAppearanceTests {
    private func withTempConfigDir(
        body: (_ dir: URL) throws -> Void
    ) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-7161-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func withTempConfig(
        _ contents: String,
        body: (_ path: String) throws -> Void
    ) throws {
        try withTempConfigDir { dir in
            let file = dir.appendingPathComponent("config", isDirectory: false)
            try contents.write(to: file, atomically: true, encoding: .utf8)
            try body(file.path)
        }
    }

    // MARK: Managed-default-theme gate (issue #7161)

    @Test func managedDefaultThemeGateIgnoresAdaptivePreference() throws {
        try withTempConfig("# no settings\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(configPaths: [path]))
        }
    }

    @Test func loadCacheSeparatesAdaptiveDefaultThemeChoices() {
        GhosttyConfig.invalidateLoadCache()
        defer { GhosttyConfig.invalidateLoadCache() }

        var loadCount = 0
        let loadFromDisk: (
            GhosttyConfig.ColorSchemePreference,
            Bool
        ) -> GhosttyConfig = { _, adaptiveDefaultThemeEnabled in
            loadCount += 1
            var config = GhosttyConfig()
            config.fontFamily = adaptiveDefaultThemeEnabled ? "adaptive" : "ghostty"
            return config
        }

        let ghosttyDefault = GhosttyConfig.load(
            preferredColorScheme: .dark,
            adaptiveDefaultThemeEnabled: false,
            loadFromDisk: loadFromDisk
        )
        let adaptiveFirst = GhosttyConfig.load(
            preferredColorScheme: .dark,
            adaptiveDefaultThemeEnabled: true,
            loadFromDisk: loadFromDisk
        )
        let adaptiveSecond = GhosttyConfig.load(
            preferredColorScheme: .dark,
            adaptiveDefaultThemeEnabled: true,
            loadFromDisk: loadFromDisk
        )

        #expect(loadCount == 2)
        #expect(ghosttyDefault.fontFamily == "ghostty")
        #expect(adaptiveFirst.fontFamily == "adaptive")
        #expect(adaptiveSecond.fontFamily == "adaptive")
    }

    @Test func configuredColorsSuppressManagedDefaultTheme() throws {
        try withTempConfig(
            """
            palette = 1=#ff0000
            cursor-color = #ffcc00
            selection-background = #333333
            """
        ) { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func configuredIncludedColorSuppressesManagedDefaultTheme() throws {
        try withTempConfigDir { dir in
            let included = dir.appendingPathComponent("appearance.conf", isDirectory: false)
            try "background = #101820\n".write(to: included, atomically: true, encoding: .utf8)

            let main = dir.appendingPathComponent("config", isDirectory: false)
            try "config-file = appearance.conf\n".write(to: main, atomically: true, encoding: .utf8)

            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [main.path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func missingIncludeDoesNotChooseATerminalPalette() throws {
        try withTempConfig("config-file = missing.conf\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func explicitThemeSuppressesManagedDefaultTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func explicitThemeWithColorOverridesSuppressesManagedDefaultTheme() throws {
        try withTempConfig("theme = Catppuccin Mocha\nbackground = black\n") { path in
            #expect(!GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func nonAppearanceConfigPreservesManagedDefaultTheme() throws {
        try withTempConfig("font-family = JetBrains Mono\nbackground-opacity = 0.92\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func emptyOrCommentOnlyConfigAppliesManagedDefaultTheme() throws {
        try withTempConfig("# no Ghostty settings\n") { path in
            #expect(GhosttyConfig.shouldApplyManagedDefaultAppearance(
                configPaths: [path],
                adaptiveDefaultThemeEnabled: true
            ))
        }
    }

    @Test func summaryReportsConfiguredColorsAsIneligibleForManagedDefault() throws {
        try withTempConfig("background = black\n") { path in
            let summary = GhosttyConfig.userAppearanceConfigSummary(configPaths: [path])
            #expect(!summary.shouldApplyDefaultAppearance)
            #expect(summary.hasConfigDirective)
            #expect(summary.hasExplicitTerminalColorDirective)
        }
    }

    @Test func summaryReportsNonAppearanceConfigAsEligibleForManagedDefault() throws {
        try withTempConfig("font-family = JetBrains Mono\nbackground-opacity = 0.92\n") { path in
            let summary = GhosttyConfig.userAppearanceConfigSummary(configPaths: [path])
            #expect(summary.shouldApplyDefaultAppearance)
            #expect(summary.hasConfigDirective)
            #expect(!summary.hasExplicitTerminalColorDirective)
        }
    }

    // MARK: Managed base + user override precedence

    /// Writes a sentinel "GitHub Dark Default" theme file into a
    /// bundle-layout themes root the managed-default resolution finds via
    /// `bundleResourceURL`, keeping the resolved managed colors deterministic
    /// on machines with Ghostty installed.
    private func makeManagedThemesRoot(in dir: URL) throws -> URL {
        let root = dir.appendingPathComponent("resources", isDirectory: true)
        let themesDir = root.appendingPathComponent("ghostty/themes", isDirectory: true)
        try FileManager.default.createDirectory(at: themesDir, withIntermediateDirectories: true)

        let managedTheme = """
        palette = 1=#c0ffee
        background = #112233
        foreground = #445566
        cursor-color = #778899
        """
        // Both default theme name constants resolve to "GitHub Dark Default"
        // (Issue #71), so one file covers both appearances.
        for name in Set([GhosttyConfig.cmuxDefaultDarkThemeName, GhosttyConfig.cmuxDefaultLightThemeName]) {
            try managedTheme.write(
                to: themesDir.appendingPathComponent(name, isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        return root
    }

    private func loadResolvedConfig(
        userConfig: String,
        adaptiveDefaultThemeEnabled: Bool = false,
        body: (GhosttyConfig) throws -> Void
    ) throws {
        try withTempConfigDir { dir in
            let themesRoot = try makeManagedThemesRoot(in: dir)
            let file = dir.appendingPathComponent("config", isDirectory: false)
            try userConfig.write(to: file, atomically: true, encoding: .utf8)

            var config = GhosttyConfig()
            config.loadResolvedUserConfig(
                configPaths: [file.path],
                preferredColorScheme: .dark,
                adaptiveDefaultThemeEnabled: adaptiveDefaultThemeEnabled,
                environment: ["CFFIXED_USER_HOME": dir.path],
                bundleResourceURL: themesRoot
            )
            try body(config)
        }
    }

    @Test(arguments: [false, true])
    func managedDefaultThemeAppliedRegardlessOfAdaptivePreference(
        adaptiveDefaultThemeEnabled: Bool
    ) throws {
        try loadResolvedConfig(
            userConfig: "# no settings\n",
            adaptiveDefaultThemeEnabled: adaptiveDefaultThemeEnabled
        ) { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#112233")
            #expect(config.foregroundColor.hexString() == "#445566")
            #expect(config.palette[1]?.hexString() == "#C0FFEE")
        }
    }

    @Test func managedDefaultThemeIsIdenticalInBothAppearances() throws {
        try withTempConfigDir { dir in
            let themesRoot = dir.appendingPathComponent("resources", isDirectory: true)
            let themesDir = themesRoot.appendingPathComponent("ghostty/themes", isDirectory: true)
            try FileManager.default.createDirectory(
                at: themesDir,
                withIntermediateDirectories: true
            )
            // Both default theme name constants resolve to the same file
            // (Issue #71), so light and dark must load identical colors.
            try "background = #090A0B\nforeground = #F0F1F2\n".write(
                to: themesDir.appendingPathComponent(
                    GhosttyConfig.cmuxDefaultLightThemeName
                ),
                atomically: true,
                encoding: .utf8
            )
            let configURL = dir.appendingPathComponent("config")
            try "# no Ghostty settings\n".write(
                to: configURL,
                atomically: true,
                encoding: .utf8
            )

            func load(_ colorScheme: GhosttyConfig.ColorSchemePreference) -> GhosttyConfig {
                var config = GhosttyConfig()
                config.loadResolvedUserConfig(
                    configPaths: [configURL.path],
                    preferredColorScheme: colorScheme,
                    adaptiveDefaultThemeEnabled: true,
                    environment: ["CFFIXED_USER_HOME": dir.path],
                    bundleResourceURL: themesRoot
                )
                return config
            }

            let light = load(.light)
            let dark = load(.dark)
            #expect(light.backgroundColor.hexString() == "#090A0B")
            #expect(light.foregroundColor.hexString() == "#F0F1F2")
            #expect(dark.backgroundColor.hexString() == light.backgroundColor.hexString())
            #expect(dark.foregroundColor.hexString() == light.foregroundColor.hexString())
        }
    }

    @Test func backgroundOverrideKeepsGhosttyBase() throws {
        try loadResolvedConfig(userConfig: "background = #000000\n") { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#000000")
            #expect(config.foregroundColor.hexString() == "#FFFFFF")
            #expect(config.palette[1]?.hexString() == "#CC6666")
        }
    }

    @Test func backgroundOverrideKeepsGhosttyBaseWhenAdaptiveDefaultIsEnabled() throws {
        try loadResolvedConfig(
            userConfig: "background = #000000\n",
            adaptiveDefaultThemeEnabled: true
        ) { config in
            #expect(config.theme == nil)
            #expect(config.backgroundColor.hexString() == "#000000")
            #expect(config.foregroundColor.hexString() == "#FFFFFF")
            #expect(config.palette[1]?.hexString() == "#CC6666")
            #expect(config.cursorColor.hexString() == "#FFFFFF")
        }
    }

    @Test func explicitThemeDirectiveSkipsManagedDefaultBase() throws {
        let defaultBackgroundHex = GhosttyConfig().backgroundColor.hexString()
        try loadResolvedConfig(
            userConfig: "theme = Cmux Nonexistent Theme 7161\n",
            adaptiveDefaultThemeEnabled: true
        ) { config in
            #expect(config.theme == "Cmux Nonexistent Theme 7161")
            // The unresolvable user theme leaves the built-in defaults in place;
            // the managed base must not have been applied underneath it.
            #expect(config.backgroundColor.hexString() == defaultBackgroundHex)
            #expect(config.palette[1]?.hexString() == "#CC6666")
        }
    }

    // MARK: Issue #71 — the fallback palette pins GitHub Dark Default

    @Test func fallbackDefaultAppearanceIsGitHubDarkDefaultInBothAppearances() {
        let environment = ["CFFIXED_USER_HOME": "/nonexistent"]
        let light = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .light,
            environment: environment,
            bundleResourceURL: nil
        )
        let dark = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .dark,
            environment: environment,
            bundleResourceURL: nil
        )
        // Both appearances resolve to the same contents.
        #expect(light == dark)

        var config = GhosttyConfig()
        config.parse(light)
        #expect(config.backgroundColor.hexString() == "#0D1117")
        #expect(config.foregroundColor.hexString() == "#E6EDF3")
        #expect(config.cursorColor.hexString() == "#2F81F7")
        #expect(config.cursorTextColor.hexString() == "#6FC1FF")
        #expect(config.selectionBackground.hexString() == "#E6EDF3")
        #expect(config.selectionForeground.hexString() == "#0D1117")
        #expect(config.palette[0]?.hexString() == "#484F58")
        #expect(config.palette[1]?.hexString() == "#FF7B72")
        #expect(config.palette[11]?.hexString() == "#E3B341")
        #expect(config.palette[15]?.hexString() == "#FFFFFF")
    }

    @Test func fallbackPaletteMatchesBundledGitHubDarkDefaultThemeFile() throws {
        // The built-in fallback must stay line-for-line identical to the
        // bundled "GitHub Dark Default" theme file (Issue #71), so a fresh
        // install looks the same with or without the bundled library.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // CmuxTerminalCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // CmuxTerminalCore
            .deletingLastPathComponent() // macOS
            .deletingLastPathComponent() // Packages
        let themeFile = repoRoot.appendingPathComponent("Resources/ghostty/themes/GitHub Dark Default")
        let bundled = try String(contentsOf: themeFile, encoding: .utf8)

        let fallback = GhosttyConfig.cmuxDefaultThemeConfigContents(
            preferredColorScheme: .dark,
            environment: ["CFFIXED_USER_HOME": "/nonexistent"],
            bundleResourceURL: nil
        )

        #expect(
            fallback.trimmingCharacters(in: .whitespacesAndNewlines)
                == bundled.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
