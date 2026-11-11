import AppKit
import Foundation
import Testing
@testable import CmuxTerminalCore

/// Non-color settings must not opt an otherwise default-themed terminal out
/// of the managed default appearance. Since Issue #71 the managed default
/// theme is GitHub Dark Default in both light and dark appearance.
@Suite struct GhosttyConfigAdaptiveAppearanceRegressionTests {
    @Test(arguments: [
        "font-size = 17",
        "font-family = Menlo",
        "keybind = ctrl+shift+r=reload_config",
        "background-opacity = 0.9",
        "working-directory = /tmp",
    ])
    func unrelatedSettingsPreserveDefaultAppearance(setting: String) throws {
        try withFixture(setting) { path, resources in
            let dark = load(path, resources: resources, scheme: .dark)
            let light = load(path, resources: resources, scheme: .light)

            #expect(dark.backgroundColor.hexString() == "#101112")
            #expect(dark.foregroundColor.hexString() == "#F0F1F2")
            // The default theme is the same in both appearances (Issue #71).
            #expect(light.backgroundColor.hexString() == "#101112")
            #expect(light.foregroundColor.hexString() == "#F0F1F2")
            if setting.hasPrefix("font-size") {
                #expect(dark.fontSize == 17)
                #expect(light.fontSize == 17)
            }
        }
    }

    @Test func includedNonColorSettingsPreserveDefaultAppearance() throws {
        try withFixture("config-file = fonts.conf") { path, resources in
            let included = URL(fileURLWithPath: path).deletingLastPathComponent()
                .appendingPathComponent("fonts.conf")
            try "font-size = 17\n".write(to: included, atomically: true, encoding: .utf8)
            let light = load(path, resources: resources, scheme: .light)
            #expect(light.backgroundColor.hexString() == "#101112")
            #expect(light.foregroundColor.hexString() == "#F0F1F2")
            #expect(light.fontSize == 17)
        }
    }

    @Test(arguments: ["background = #123456", "theme = Deliberate Dark"])
    func authoredAppearanceStillOwnsColors(setting: String) throws {
        try withFixture(setting) { path, resources in
            let light = load(path, resources: resources, scheme: .light)
            let dark = load(path, resources: resources, scheme: .dark)
            #expect(light.backgroundColor == dark.backgroundColor)
            #expect(light.foregroundColor == dark.foregroundColor)
            #expect(light.backgroundColor.hexString() == (setting.hasPrefix("theme") ? "#334455" : "#123456"))
        }
    }

    private func load(
        _ path: String,
        resources: URL,
        scheme: GhosttyConfig.ColorSchemePreference
    ) -> GhosttyConfig {
        var config = GhosttyConfig()
        config.loadResolvedUserConfig(
            configPaths: [path],
            preferredColorScheme: scheme,
            adaptiveDefaultThemeEnabled: true,
            // Point the user theme directory into the fixture so a real
            // ~/.config/cmux/themes cannot shadow the bundled fixture files
            // (the user directory is searched first since Issue #71).
            environment: ["CFFIXED_USER_HOME": resources.path],
            bundleResourceURL: resources
        )
        return config
    }

    private func withFixture(
        _ contents: String,
        body: (String, URL) throws -> Void
    ) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-12797-\(UUID().uuidString)")
        let themes = root.appendingPathComponent("ghostty/themes")
        try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Both default theme name constants resolve to the same name since
        // Issue #71, so one theme file covers both appearances.
        for (name, contents) in [
            (GhosttyConfig.cmuxDefaultDarkThemeName, "background = #101112\nforeground = #f0f1f2\n"),
        ] {
            try contents.write(to: themes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let path = root.appendingPathComponent("config.ghostty")
        let authoredTheme = root.appendingPathComponent("Deliberate Dark")
        try "background = #334455\nforeground = #ddeeff\n".write(
            to: authoredTheme, atomically: true, encoding: .utf8
        )
        try contents.replacingOccurrences(of: "Deliberate Dark", with: authoredTheme.path)
            .write(to: path, atomically: true, encoding: .utf8)
        try body(path.path, root)
    }
}
