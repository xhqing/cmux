import XCTest
import Foundation
import CmuxFoundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class GhosttyConfigPathResolverTests: XCTestCase {
    // MARK: - Fixed config location

    func testActiveOrEditableConfigURLTargetsFixedConfigLocation() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let expectedURL = homeDirectory
                .appendingPathComponent(".config/cmux/config.ghostty", isDirectory: false)

            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver().activeOrEditableConfigURL(
                    environment: environment
                ),
                expectedURL
            )
        }
    }

    func testLoadConfigURLsIgnoreBundleIdentifierDifferences() throws {
        // The same config is shared by every build: resolving with different
        // environment homes is the only thing that changes the location.
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let configURL = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: "font-size = 13\n"
            )
            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]

            let resolver = CmuxGhosttyConfigPathResolver()
            XCTAssertEqual(
                resolver.loadConfigURLs(environment: environment, fileManager: fileManager),
                [configURL]
            )
            XCTAssertEqual(
                resolver.loadConfigURLs(environment: environment, fileManager: fileManager),
                [configURL]
            )
        }
    }

    func testCmuxConfigPathResolverOpensLegacyConfigWhenConfigGhosttyIsEmpty() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let legacyConfigURL = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config",
                contents: "background = #000000\n"
            )
            _ = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: ""
            )
            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver().activeOrEditableConfigURL(
                    environment: environment,
                    fileManager: fileManager
                ),
                legacyConfigURL
            )
        }
    }

    func testLoadConfigURLsPreferConfigGhosttyOverLegacyConfigWhenBothExist() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            _ = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config",
                contents: "background = #000000\n"
            )
            let preferredConfigURL = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: "theme = light:3024 Day,dark:3024 Night\n"
            )
            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver().loadConfigURLs(
                    environment: environment,
                    fileManager: fileManager
                ),
                [preferredConfigURL]
            )
        }
    }

    func testLoadConfigURLsIgnoreMissingOrEmptyFiles() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            _ = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: ""
            )
            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]

            XCTAssertTrue(
                CmuxGhosttyConfigPathResolver().loadConfigURLs(
                    environment: environment,
                    fileManager: fileManager
                ).isEmpty
            )
        }
    }

    func testLoadConfigURLsPreserveSymlinkedConfigURL() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let cmuxDirectory = homeDirectory.appendingPathComponent(".config/cmux", isDirectory: true)
            try fileManager.createDirectory(at: cmuxDirectory, withIntermediateDirectories: true)

            let dotfilesDirectory = homeDirectory
                .appendingPathComponent("dotfiles", isDirectory: true)
                .appendingPathComponent("cmux", isDirectory: true)
            try fileManager.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)
            let targetConfigURL = dotfilesDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            try "font-size = 16\n".write(to: targetConfigURL, atomically: true, encoding: .utf8)

            let symlinkedConfigURL = cmuxDirectory.appendingPathComponent("config.ghostty", isDirectory: false)
            try fileManager.createSymbolicLink(
                atPath: symlinkedConfigURL.path,
                withDestinationPath: targetConfigURL.path
            )
            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]

            XCTAssertEqual(
                CmuxGhosttyConfigPathResolver().loadConfigURLs(
                    environment: environment,
                    fileManager: fileManager
                ),
                [symlinkedConfigURL]
            )
        }
    }

    // MARK: - Settings editor URLs

    func testGhosttySettingsEditorURLsMaterializeCmuxConfigWhenNoConfigExists() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let environment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory
            )

            let urls = try environment.materializedGhosttySettingsEditorURLs()
            let expectedConfigURL = homeDirectory
                .appendingPathComponent(".config/cmux/config.ghostty", isDirectory: false)

            XCTAssertEqual(urls.map(\.path), [expectedConfigURL.path])
            XCTAssertTrue(FileManager.default.fileExists(atPath: expectedConfigURL.path))
        }
    }

    func testGhosttySettingsEditorURLsIncludeRecursiveConfigFiles() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let cmuxConfigURL = try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: "theme = cmux\nconfig-file = cmux-include.conf\n"
            )
            let cmuxIncludeURL = cmuxConfigURL
                .deletingLastPathComponent()
                .appendingPathComponent("cmux-include.conf", isDirectory: false)
            try "font-size = 16\n".write(to: cmuxIncludeURL, atomically: true, encoding: .utf8)

            let environment = ConfigSourceEnvironment(
                homeDirectoryURL: homeDirectory
            )

            let urls = try environment.materializedGhosttySettingsEditorURLs()
            XCTAssertEqual(
                urls.map(\.path),
                [
                    cmuxConfigURL.path,
                    cmuxIncludeURL.path,
                ]
            )
        }
    }

    // MARK: - Legacy Application Support migration

    func testMigrationCopiesLegacyAppSupportConfigWhenNewLocationIsMissing() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            let legacyBundleDirectory = appSupportDirectory
                .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            try fileManager.createDirectory(at: legacyBundleDirectory, withIntermediateDirectories: true)
            let legacyConfigURL = legacyBundleDirectory
                .appendingPathComponent("config.ghostty", isDirectory: false)
            try "background = #ff0000\n".write(to: legacyConfigURL, atomically: true, encoding: .utf8)

            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]
            CmuxGhosttyConfigPathResolver().migrateLegacyAppSupportConfigIfNeeded(
                bundleIdentifiers: ["com.cmuxterm.app"],
                appSupportDirectory: appSupportDirectory,
                environment: environment,
                fileManager: fileManager
            )

            let migratedURL = homeDirectory
                .appendingPathComponent(".config/cmux/config.ghostty", isDirectory: false)
            XCTAssertTrue(fileManager.fileExists(atPath: migratedURL.path))
            XCTAssertEqual(
                try String(contentsOf: migratedURL, encoding: .utf8),
                "background = #ff0000\n"
            )
            // The legacy file is left in place.
            XCTAssertTrue(fileManager.fileExists(atPath: legacyConfigURL.path))
        }
    }

    func testMigrationIsIdempotentAndNeverOverwritesExistingConfig() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            let legacyBundleDirectory = appSupportDirectory
                .appendingPathComponent("com.cmuxterm.app", isDirectory: true)
            try fileManager.createDirectory(at: legacyBundleDirectory, withIntermediateDirectories: true)
            try "background = #ff0000\n".write(
                to: legacyBundleDirectory.appendingPathComponent("config.ghostty", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
            let targetURL = homeDirectory
                .appendingPathComponent(".config/cmux/config.ghostty", isDirectory: false)
            try writeConfig(
                homeDirectory: homeDirectory,
                filename: "config.ghostty",
                contents: "background = #0000ff\n"
            )

            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]
            let resolver = CmuxGhosttyConfigPathResolver()
            resolver.migrateLegacyAppSupportConfigIfNeeded(
                bundleIdentifiers: ["com.cmuxterm.app"],
                appSupportDirectory: appSupportDirectory,
                environment: environment,
                fileManager: fileManager
            )

            XCTAssertEqual(
                try String(contentsOf: targetURL, encoding: .utf8),
                "background = #0000ff\n"
            )
        }
    }

    func testMigrationUsesCurrentBundleIdentifierBeforeReleaseFallback() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
            for bundleIdentifier in ["com.cmuxterm.app", "com.xhqing.cmux"] {
                let bundleDirectory = appSupportDirectory
                    .appendingPathComponent(bundleIdentifier, isDirectory: true)
                try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)
                try "background = #\(bundleIdentifier == "com.cmuxterm.app" ? "112233" : "445566")\n".write(
                    to: bundleDirectory.appendingPathComponent("config.ghostty", isDirectory: false),
                    atomically: true,
                    encoding: .utf8
                )
            }

            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]
            CmuxGhosttyConfigPathResolver().migrateLegacyAppSupportConfigIfNeeded(
                bundleIdentifiers: ["com.xhqing.cmux", "com.cmuxterm.app"],
                appSupportDirectory: appSupportDirectory,
                environment: environment,
                fileManager: fileManager
            )

            let migratedURL = homeDirectory
                .appendingPathComponent(".config/cmux/config.ghostty", isDirectory: false)
            XCTAssertEqual(
                try String(contentsOf: migratedURL, encoding: .utf8),
                "background = #445566\n"
            )
        }
    }

    func testMigrationDoesNothingWhenLegacyConfigIsMissing() throws {
        try withTemporaryHomeDirectory { homeDirectory in
            let fileManager = FileManager.default
            let appSupportDirectory = homeDirectory
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)

            let environment = [
                "CFFIXED_USER_HOME": homeDirectory.path,
            ]
            CmuxGhosttyConfigPathResolver().migrateLegacyAppSupportConfigIfNeeded(
                bundleIdentifiers: ["com.cmuxterm.app"],
                appSupportDirectory: appSupportDirectory,
                environment: environment,
                fileManager: fileManager
            )

            let targetURL = homeDirectory
                .appendingPathComponent(".config/cmux/config.ghostty", isDirectory: false)
            XCTAssertFalse(fileManager.fileExists(atPath: targetURL.path))
        }
    }

    // MARK: - Helpers

    func withTemporaryAppSupportDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-app-support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    func withTemporaryHomeDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-home-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        try body(directory)
    }

    func writeConfig(
        homeDirectory: URL,
        filename: String,
        contents: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let cmuxDirectory = homeDirectory.appendingPathComponent(".config/cmux", isDirectory: true)
        try fileManager.createDirectory(at: cmuxDirectory, withIntermediateDirectories: true)

        let configURL = cmuxDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    func writeAppSupportConfig(
        appSupportDirectory: URL,
        bundleIdentifier: String,
        filename: String,
        contents: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let bundleDirectory = appSupportDirectory
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
        try fileManager.createDirectory(at: bundleDirectory, withIntermediateDirectories: true)

        let configURL = bundleDirectory.appendingPathComponent(filename, isDirectory: false)
        try contents.write(to: configURL, atomically: true, encoding: .utf8)
        return configURL
    }

    private final class RaceCreatingFileManager: FileManager {
        var onFirstMissingPlainExistenceCheck: ((String) throws -> Void)?
        var creationError: Error?
        private var hasRunPlainExistenceHook = false

        override func fileExists(atPath path: String) -> Bool {
            let exists = super.fileExists(atPath: path)
            guard !exists, !hasRunPlainExistenceHook else {
                return exists
            }
            hasRunPlainExistenceHook = true
            do {
                try onFirstMissingPlainExistenceCheck?(path)
            } catch {
                creationError = error
            }
            return exists
        }
    }
}
