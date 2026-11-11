import Foundation
import CmuxFoundation

struct ConfigSourceEnvironment {
    let homeDirectoryURL: URL
    let fileManager: FileManager

    init(
        homeDirectoryURL: URL,
        fileManager: FileManager = .default
    ) {
        let standardizedHome = homeDirectoryURL.standardizedFileURL
        self.homeDirectoryURL = standardizedHome
        self.fileManager = fileManager
    }

    static func live(fileManager: FileManager = .default) -> Self {
        Self(
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser,
            fileManager: fileManager
        )
    }

    /// The process environment with the fixed home pinned to this
    /// environment's `homeDirectoryURL`, so every path resolver call and every
    /// resolver-based read/write agree on one home directory.
    private var resolverEnvironment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = homeDirectoryURL.path
        return environment
    }

    /// cmux's config file at the fixed `~/.config/cmux/config.ghostty` path
    /// (or the legacy `config` name when it is the one on disk).
    var cmuxConfigURL: URL {
        CmuxGhosttyConfigPathResolver().activeOrEditableConfigURL(
            environment: resolverEnvironment,
            fileManager: fileManager
        )
    }

    func materializeCmuxConfigFileIfNeeded() throws -> URL {
        let url = cmuxConfigURL
        guard !fileManager.fileExists(atPath: url.path) else { return url }
        try writeCmuxConfigContents("", to: url)
        return url
    }

    func materializedGhosttySettingsEditorURLs() throws -> [URL] {
        let cmuxURL = try materializeCmuxConfigFileIfNeeded()

        var collector = GhosttySettingsConfigFileCollector(
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL
        )
        collector.append(cmuxURL)

        for url in CmuxGhosttyConfigPathResolver().loadConfigURLs(
            environment: resolverEnvironment,
            fileManager: fileManager
        ) {
            collector.append(url)
        }

        collector.appendRecursiveConfigFileIncludes()
        return collector.urls
    }

    func writeCmuxConfigContents(_ contents: String) throws {
        let url = cmuxConfigURL
        try writeCmuxConfigContents(contents, to: url)
    }

    func writeCmuxConfigSetting(key: String, value: String) throws {
        let url = try materializeCmuxConfigFileIfNeeded()
        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: key,
            value: value,
            to: url,
            fileManager: fileManager
        )
    }

    /// Writes one `key = value` line per value, replacing every existing
    /// assignment to `key`. See `CmuxGhosttyConfigSettingEditor.updatedContents(_:setting:values:)`.
    func writeCmuxConfigSetting(key: String, values: [String]) throws {
        let url = try materializeCmuxConfigFileIfNeeded()
        try CmuxGhosttyConfigSettingEditor().writeSetting(
            key: key,
            values: values,
            to: url,
            fileManager: fileManager
        )
    }

    private func writeCmuxConfigContents(_ contents: String, to url: URL) throws {
        let writeURL = configWriteURL(for: url)
        try fileManager.createDirectory(
            at: writeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        try contents.write(to: writeURL, atomically: true, encoding: .utf8)
    }

    func abbreviatedPath(for url: URL) -> String {
        let path = url.path
        let homePath = homeDirectoryURL.path
        if path == homePath {
            return "~"
        }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    func isRegularFile(at url: URL) -> Bool {
        if isDirectRegularFile(at: url) {
            return true
        }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return isDirectRegularFile(at: destinationURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    private func isDirectRegularFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func configWriteURL(for url: URL) -> URL {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return destinationURL.standardizedFileURL.resolvingSymlinksInPath()
    }
}

struct ConfigSourceSnapshot {
    let source: ConfigSource
    let primaryURL: URL
    let displayPaths: [String]
    let contents: String
    let isEditable: Bool
    let hasBackingFile: Bool
}

enum ConfigSource: String, CaseIterable, Identifiable {
    case cmux

    var id: Self { self }

    var isEditable: Bool {
        self == .cmux
    }

    func snapshot(environment: ConfigSourceEnvironment = .live()) -> ConfigSourceSnapshot {
        switch self {
        case .cmux:
            let url = environment.cmuxConfigURL
            return ConfigSourceSnapshot(
                source: self,
                primaryURL: url,
                displayPaths: [url.path],
                contents: Self.readContents(at: url),
                isEditable: true,
                hasBackingFile: environment.isRegularFile(at: url)
            )
        }
    }

    private static func readContents(at url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents
    }
}

private struct GhosttySettingsConfigFileCollector {
    let fileManager: FileManager
    let homeDirectoryURL: URL
    private(set) var urls: [URL] = []
    private var seenCanonicalPaths: Set<String> = []

    init(fileManager: FileManager, homeDirectoryURL: URL) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
    }

    mutating func append(_ url: URL) {
        let standardized = url.standardizedFileURL
        let canonicalPath = standardized.resolvingSymlinksInPath().path
        guard seenCanonicalPaths.insert(canonicalPath).inserted else { return }
        urls.append(standardized)
    }

    mutating func appendRecursiveConfigFileIncludes() {
        var queue = urls
        var scannedCanonicalPaths: Set<String> = []

        while !queue.isEmpty {
            let url = queue.removeFirst()
            let canonicalPath = url.resolvingSymlinksInPath().path
            guard scannedCanonicalPaths.insert(canonicalPath).inserted else { continue }
            guard isRegularFile(at: url),
                  let contents = try? String(contentsOf: url, encoding: .utf8) else {
                continue
            }

            for includeURL in Self.configFileIncludeURLs(
                in: contents,
                parentDirectoryURL: url.deletingLastPathComponent(),
                homeDirectoryURL: homeDirectoryURL
            ) where isRegularFile(at: includeURL) {
                let beforeCount = urls.count
                append(includeURL)
                if urls.count > beforeCount {
                    queue.append(includeURL)
                }
            }
        }
    }

    private func isRegularFile(at url: URL) -> Bool {
        if isDirectRegularFile(at: url) {
            return true
        }
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return false
        }
        let destinationURL: URL
        if destination.hasPrefix("/") {
            destinationURL = URL(fileURLWithPath: destination)
        } else {
            destinationURL = url.deletingLastPathComponent().appendingPathComponent(destination)
        }
        return isDirectRegularFile(at: destinationURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    private func isDirectRegularFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private static func configFileIncludeURLs(
        in contents: String,
        parentDirectoryURL: URL,
        homeDirectoryURL: URL
    ) -> [URL] {
        var urls: [URL] = []
        for line in contents.components(separatedBy: .newlines) {
            guard let entry = parsedGhosttyConfigEntry(from: line),
                  entry.key == "config-file",
                  var value = entry.value else {
                continue
            }
            if !entry.valueWasQuoted {
                value = strippingInlineComment(from: value)
            }

            if value.isEmpty {
                urls.removeAll()
                continue
            }
            if !entry.valueWasQuoted, value.hasPrefix("?") {
                value.removeFirst()
            }
            guard !value.isEmpty else { continue }

            let expandedPath = expandTilde(in: value, homeDirectoryURL: homeDirectoryURL)
            let includeURL: URL
            if (expandedPath as NSString).isAbsolutePath {
                includeURL = URL(fileURLWithPath: expandedPath, isDirectory: false)
            } else {
                includeURL = parentDirectoryURL.appendingPathComponent(expandedPath, isDirectory: false)
            }
            urls.append(includeURL.standardizedFileURL)
        }
        return urls
    }

    private static func strippingInlineComment(from value: String) -> String {
        var result = ""
        var isEscaped = false

        for character in value {
            if isEscaped {
                result.append(character)
                isEscaped = false
                continue
            }
            if character == "\\" {
                result.append(character)
                isEscaped = true
                continue
            }
            if character == "#" {
                break
            }
            result.append(character)
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parsedGhosttyConfigEntry(
        from rawLine: String
    ) -> (key: String, value: String?, valueWasQuoted: Bool)? {
        var trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") {
            trimmed.removeFirst()
        }
        if trimmed.isEmpty || trimmed.hasPrefix("#") { return nil }

        guard let separatorIndex = trimmed.firstIndex(of: "=") else {
            return (trimmed.trimmingCharacters(in: .whitespacesAndNewlines), nil, false)
        }

        let key = trimmed[..<separatorIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = trimmed[trimmed.index(after: separatorIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let valueWasQuoted = value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\"")

        if valueWasQuoted {
            value.removeFirst()
            value.removeLast()
        }

        return (String(key), String(value), valueWasQuoted)
    }

    private static func expandTilde(in path: String, homeDirectoryURL: URL) -> String {
        guard path == "~" || path.hasPrefix("~/") else {
            return NSString(string: path).expandingTildeInPath
        }
        let homePath = homeDirectoryURL.path
        if path == "~" {
            return homePath
        }
        return (homePath as NSString).appendingPathComponent(String(path.dropFirst(2)))
    }
}
