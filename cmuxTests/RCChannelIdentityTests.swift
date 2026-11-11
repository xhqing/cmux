import CmuxSettings
import CmuxUpdater
import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The `rc` release channel (`com.cmuxterm.app.rc`, "cmux RC.app") is a fourth
/// lane next to stable, nightly, and staging. These tests pin the identity
/// surfaces that key off the channel: build flavor, socket path, icon
/// persistence, and the update feed.
final class RCChannelIdentityTests: XCTestCase {
    @MainActor
    func testBundleIconPersistenceSkipsRCBundles() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.rc",
                appBundleLastPathComponent: "cmux RC.app",
                persistenceDisabled: false
            )
        )
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.cmuxterm.app.rc.candidate1",
                appBundleLastPathComponent: "cmux RC candidate1.app",
                persistenceDisabled: false
            )
        )
    }

    func testRCReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "CMUX_SOCKET_PATH": "/tmp/cmux-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.cmuxterm.app.rc",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        XCTAssertEqual(path, "/tmp/cmux-rc.sock")
    }

    func testDefaultSocketPathForRCBundles() {
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.rc",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-rc.sock"
        )
        XCTAssertEqual(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.cmuxterm.app.rc.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ),
            "/tmp/cmux-rc-tag.sock"
        )
    }

    func testDetectsRCFromBundleIdentifier() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.rc"),
            .rc
        )
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux", bundleIdentifier: "com.cmuxterm.app.rc.candidate1"),
            .rc
        )
    }

    func testDetectsRCFromBundleName() {
        XCTAssertEqual(
            BuildFlavor.detect(bundleName: "cmux RC", bundleIdentifier: "com.cmuxterm.app"),
            .rc
        )
    }

    func testResolvedFeedDetectsRCFromInfoFeedURL() {
        let resolved = UpdateFeedResolver(hostArchitecture: .arm64).resolve(
            infoFeedURL: "https://files.cmux.com/rc/appcast.xml"
        )
        XCTAssertEqual(resolved.url, "https://files.cmux.com/rc/appcast-arm64.xml")
        XCTAssertEqual(resolved.channel, .rc)
        XCTAssertFalse(resolved.isNightly)
        XCTAssertFalse(resolved.usedFallback)
    }
}

extension GhosttyConfigPathResolverTests {
    func testCmuxConfigURLsUseFixedLocationRegardlessOfChannel() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let configURL = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver().loadConfigURLs(
                    environment: ["CFFIXED_USER_HOME": homeDirectory.path],
                    fileManager: fileManager
                ),
                [configURL]
            )
        }
    }

    func testCmuxConfigURLsIgnoreRCConfigLeftInLegacyAppSupport() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            _ = try writeAppSupportConfig(
                appSupportDirectory: appSupportDirectory,
                bundleIdentifier: "com.cmuxterm.app.rc",
                filename: "config.ghostty",
                contents: "font-size = 15\n"
            )

            // The legacy App Support location is only a migration source; it is
            // never read directly, whatever the channel of the running build.
            XCTAssertTrue(
                CmuxGhosttyConfigPathResolver().loadConfigURLs(
                    environment: ["CFFIXED_USER_HOME": homeDirectory.path],
                    fileManager: fileManager
                ).isEmpty
            )
        }
    }
}
