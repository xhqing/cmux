import Darwin
import Foundation
import os

enum StartupBreadcrumbLog {
    private static let maxFieldLength = 240
    private nonisolated static let logger = Logger(subsystem: "com.cmuxterm.app", category: "StartupBreadcrumbLog")
    private static let reservedFieldKeys: Set<String> = [
        "timestamp",
        "timestampMs",
        "uptimeMs",
        "event",
        "pid",
        "bundleIdentifier",
        "appVersion",
        "build"
    ]

    static func append(_ event: String, fields: [String: String] = [:]) {
        guard isEnabled else { return }

        let now = Date()
        var payload: [String: Any] = [
            // `timestamp` keeps its original second-resolution ISO 8601 form for
            // existing readers; `timestampMs` and `uptimeMs` carry millisecond
            // timing so gaps between breadcrumbs inside one second are visible.
            "timestamp": ISO8601DateFormatter().string(from: now),
            "timestampMs": milliseconds(sinceEpochOf: now),
            "event": event,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "bundleIdentifier": Bundle.main.bundleIdentifier ?? "unknown",
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        ]

        if let uptime = processUptimeMilliseconds(at: now) {
            payload["uptimeMs"] = uptime
        }

        for (key, value) in fields {
            let payloadKey = reservedFieldKeys.contains(key) ? "custom_\(key)" : key
            payload[payloadKey] = sanitized(value)
        }

        do {
            let url = logURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let line = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            guard flock(handle.fileDescriptor, LOCK_EX) == 0 else {
                let code = POSIXErrorCode(rawValue: errno) ?? .EIO
                throw POSIXError(code)
            }
            defer { flock(handle.fileDescriptor, LOCK_UN) }
            // Startup breadcrumbs are synchronous so the last edge survives immediate launch aborts.
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
            try handle.write(contentsOf: Data([0x0A]))
        } catch {
            logger.fault("cmux startup breadcrumb failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Wall-clock time the kernel recorded for this process's launch, so
    /// `uptimeMs` includes dyld and pre-`main` work, not just time since the
    /// first breadcrumb.
    private nonisolated static let processStartDate: Date? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let start = info.kp_proc.p_un.__p_starttime
        guard start.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }()

    private static func milliseconds(sinceEpochOf date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    private static func processUptimeMilliseconds(at date: Date) -> Int64? {
        guard let processStartDate else { return nil }
        return Int64((date.timeIntervalSince(processStartDate) * 1000).rounded())
    }

    private static var isEnabled: Bool {
        isEnabled(
            bundleIdentifier: Bundle.main.bundleIdentifier,
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Whether the file-backed startup log is on for `bundleIdentifier`.
    ///
    /// Nightly / RC / DEV channel builds have always carried it. This fork's
    /// own release identity (`com.xhqing.cmux`, see `scripts/reloads.sh` and
    /// `build.yml`) is added here because an ad-hoc-signed release build has no
    /// telemetry and no visible stderr: without this log a launch-time failure
    /// leaves nothing behind. Issue #43 was exactly that — the control-socket
    /// listener never bound and there was no record of why.
    ///
    /// `CMUX_DISABLE_STARTUP_BREADCRUMBS=1` still wins, and
    /// `CMUX_STARTUP_BREADCRUMBS=1` turns it on for any identity.
    static func isEnabled(bundleIdentifier: String?, environment: [String: String]) -> Bool {
        if environment["CMUX_DISABLE_STARTUP_BREADCRUMBS"] == "1" {
            return false
        }
        if environment["CMUX_STARTUP_BREADCRUMBS"] == "1" {
            return true
        }
        let identifier = bundleIdentifier ?? ""
        return identifier == "com.cmuxterm.app.nightly"
            || identifier.hasPrefix("com.cmuxterm.app.nightly.")
            || identifier == "com.cmuxterm.app.rc"
            || identifier.hasPrefix("com.cmuxterm.app.rc.")
            || identifier == "com.cmuxterm.app.debug"
            || identifier.hasPrefix("com.cmuxterm.app.debug.")
            || identifier == "com.xhqing.cmux"
            || identifier.hasPrefix("com.xhqing.cmux.")
    }

    private static var logURL: URL {
        let logsDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs/cmux", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("cmux-logs", isDirectory: true)
        let sanitizedBundleIdentifier = logFileComponent(Bundle.main.bundleIdentifier ?? "unknown")
        return logsDirectory.appendingPathComponent("startup-\(sanitizedBundleIdentifier).log")
    }

    private static func logFileComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        return sanitized(value, maxLength: 160).unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
    }

    private static func sanitized(_ value: String, maxLength: Int = maxFieldLength) -> String {
        let flattened = value
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        if flattened.count <= maxLength {
            return flattened
        }
        return String(flattened.prefix(maxLength)) + "...<truncated>"
    }
}

/// Release-safe diagnostics for the control-socket startup chain.
///
/// Why this exists: the socket listener is the only way the `cmux` CLI can talk
/// to the app, and a listener that never comes up fails *silently*. `start()`
/// prints to stderr (discarded when LaunchServices launches the app) and the
/// breadcrumbs go to Sentry, which this fork does not configure. Issue #43 cost
/// hours because nothing recorded why no socket appeared.
///
/// Two sinks, both available in Release:
/// - `StartupBreadcrumbLog` — one JSON line per event in
///   `~/Library/Logs/cmux/startup-<bundle-id>.log`.
/// - `os.Logger` — unified logging, queryable with
///   `log show --predicate 'subsystem == "com.cmuxterm.app" AND category == "ControlSocket"' --last 10m`.
///
/// Only listener lifecycle events are recorded; per-client chatter repeats per
/// connection and would drown the launch trace.
enum SocketStartupLog {
    private nonisolated static let logger = Logger(
        subsystem: "com.cmuxterm.app",
        category: "ControlSocket"
    )

    /// Records one listener lifecycle event (`socket.listener.*`).
    static func record(_ event: String, data: [String: any Sendable]) {
        StartupBreadcrumbLog.append(event, fields: stringFields(data))
    }

    /// Records the configuration resolved for one start attempt, including
    /// whether the socket directory is even usable. A listener that never
    /// binds still leaves the path, mode, source and parent-directory state.
    static func startAttempt(
        mode: String,
        path: String,
        source: String,
        failureSignals: [String] = []
    ) {
        var fields: [String: String] = [
            "mode": mode,
            "path": path,
            "source": source,
            "socketDirectory": socketDirectoryStatus(path: path),
        ]
        if !failureSignals.isEmpty {
            fields["failureSignals"] = failureSignals.joined(separator: ",")
        }
        StartupBreadcrumbLog.append("socket.listener.startAttempt", fields: fields)
    }

    /// Records that the resolved access mode turned the listener off, together
    /// with the value the user actually configured.
    static func listenerDisabled(source: String, configuredMode: String) {
        StartupBreadcrumbLog.append(
            "socket.listener.disabled",
            fields: ["source": source, "configuredMode": configuredMode]
        )
    }

    /// Records a successful bind + listen, right before the accept source arms.
    static func listenerDidStart(path: String, generation: UInt64) {
        StartupBreadcrumbLog.append(
            "socket.listener.didStart",
            fields: ["path": path, "generation": String(generation)]
        )
        logger.notice(
            "control socket listening at \(path, privacy: .public) generation=\(generation)"
        )
    }

    /// Records a listener start/rebind failure — always, and always at error
    /// level in unified logging, because this failure silently takes the whole
    /// CLI down.
    static func listenerFailure(
        message: String,
        stage: String,
        errnoCode: Int32?,
        data: [String: any Sendable]
    ) {
        var fields = stringFields(data)
        fields["failure"] = message
        fields["stage"] = stage
        let path = fields["path"] ?? ""
        let hint = socketPathHint(path: path)
        if let hint {
            fields["hint"] = hint
        }
        StartupBreadcrumbLog.append("socket.listener.failed", fields: fields)

        let errnoText = errnoCode.map { code in
            "\(code) (\(String(cString: strerror(code))))"
        } ?? "none"
        let hintText = hint.map { " hint=\($0)" } ?? ""
        logger.error(
            "control socket failed: \(message, privacy: .public) stage=\(stage, privacy: .public) errno=\(errnoText, privacy: .public) path=\(path, privacy: .public)\(hintText, privacy: .public)"
        )
    }

    /// Human-readable state of the directory the socket would be created in.
    /// `missing` on a path that is supposed to exist on this machine is the
    /// fingerprint of an override baked on another machine (Issue #43).
    static func socketDirectoryStatus(path: String) -> String {
        guard path.hasPrefix("/") else { return "not_absolute" }
        let directory = (path as NSString).deletingLastPathComponent
        guard !directory.isEmpty else { return "not_absolute" }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory) else {
            return "missing"
        }
        guard isDirectory.boolValue else { return "not_a_directory" }
        return FileManager.default.isWritableFile(atPath: directory) ? "writable" : "read_only"
    }

    /// One-line hint for the failure modes that present as "no socket at all".
    private static func socketPathHint(path: String) -> String? {
        switch socketDirectoryStatus(path: path) {
        case "missing":
            let directory = (path as NSString).deletingLastPathComponent
            return "socket directory \(directory) does not exist; check that CMUX_SOCKET_PATH in Info.plist LSEnvironment was not baked on another machine"
        case "not_a_directory":
            let directory = (path as NSString).deletingLastPathComponent
            return "socket directory \(directory) is not a directory"
        case "read_only":
            let directory = (path as NSString).deletingLastPathComponent
            return "socket directory \(directory) is not writable"
        default:
            return nil
        }
    }

    private static func stringFields(_ data: [String: any Sendable]) -> [String: String] {
        data.mapValues { value in
            if let string = value as? String {
                return string
            }
            return String(describing: value)
        }
    }
}
