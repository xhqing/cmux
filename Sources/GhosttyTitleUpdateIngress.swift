import CmuxFoundation
import CmuxTerminalCore
import AppKit
import Foundation

/// Release-safe key-latency probe. Off by default; enable with
/// `CMUX_KEY_LATENCY_PROBE=1` or `defaults write <bundle-id> cmuxKeyLatencyProbe -bool true`.
/// Appends one line per key event to `~/.local/state/cmux/key-latency.log`:
/// `<unixTime> <phase> <delayMs> <keyCode> <isRepeat>`, where delayMs is the gap
/// between the system event timestamp and the moment the terminal handles it.
/// This is the segment an out-of-process CLI probe cannot measure (physical key /
/// IME / event routing -> app). When disabled it costs one static check.
///
/// The same log also receives two kinds of correlation lines while the probe is
/// enabled: `<unixTime> <activity> <durationMs> [detail]` for background phases
/// (`recordActivity`) and for long main-thread turns (`mainTurn`). Key lines say
/// how long an input waited; those lines say what was running at that instant,
/// which is what turns "a spike happened" into "a spike happened while X ran".
///
/// Phases written for keystrokes: `keyEquivalent` (window-level key-equivalent
/// routing entered), `keyDown` (the terminal handler entered), `keyDown.end`
/// (that handler returned, plus the segments it measured) and
/// `warmKeyboardLayout` (the one-time input-source warm-up). A slow key defers
/// the *next* one, so `keyDown.end` is what attributes a first-keystroke spike.
enum KeyLatencyProbe {
    static let isEnabled: Bool = {
        ProcessInfo.processInfo.environment["CMUX_KEY_LATENCY_PROBE"] == "1"
            || UserDefaults.standard.bool(forKey: "cmuxKeyLatencyProbe")
    }()

    private static let queue = DispatchQueue(label: "com.cmuxterm.key-latency-probe")
    private static let logPath: String = {
        let dir = ("~/.local/state/cmux" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return (dir as NSString).appendingPathComponent("key-latency.log")
    }()

    /// Appends one line. Always runs on `queue`, so callers never touch the file.
    private static func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = FileHandle(forWritingAtPath: logPath) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            _ = FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }

    @inline(__always)
    static func record(event: NSEvent, phase: String) {
        guard isEnabled, event.timestamp > 0 else { return }
        let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
        let line = String(format: "%.3f", Date().timeIntervalSince1970)
            + " " + phase
            + " " + String(format: "%.2f", delayMs)
            + " " + String(event.keyCode)
            + " " + (event.isARepeat ? "1" : "0") + "\n"
        queue.async { Self.append(line) }
    }

    /// Records how long one keystroke handler took, plus the segments measured
    /// inside it. A slow key shows up as the *next* key's `delayMs` — the main
    /// thread is busy until this handler returns — so attributing the handler
    /// is what tells a cold first keystroke apart from an idle-queue delay.
    static func recordPhases(
        event: NSEvent,
        phase: String,
        totalMs: Double,
        parts: [(String, Double)]
    ) {
        guard isEnabled, event.timestamp > 0 else { return }
        let delayMs = max(0, (ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000)
        var line = String(format: "%.3f", Date().timeIntervalSince1970)
            + " " + phase
            + " " + String(format: "%.2f", delayMs)
            + " " + String(event.keyCode)
            + " " + (event.isARepeat ? "1" : "0")
            + " total=" + String(format: "%.2f", totalMs)
        for (name, value) in parts {
            line += " " + name + "=" + String(format: "%.2f", value)
        }
        line += "\n"
        queue.async { Self.append(line) }
    }

    /// Records a one-off cost (a warm-up) so the probe log also shows what was
    /// moved off the keystroke path and how long it took.
    static func recordCost(phase: String, milliseconds: Double) {
        guard isEnabled else { return }
        let line = String(format: "%.3f", Date().timeIntervalSince1970)
            + " " + phase
            + " " + String(format: "%.2f", max(0, milliseconds))
            + " 0 0\n"
        queue.async { Self.append(line) }
    }

    /// Records one background phase that just finished.
    ///
    /// - Parameters:
    ///   - phase: Stable activity name (`scrollbackExport`, `sessionAutosave`).
    ///   - startedAt: `ProcessInfo.processInfo.systemUptime` when the phase began.
    ///   - detail: Optional short, space-free fields (`overBudget=1`).
    ///
    /// The span is recovered from the line as `[unixTime - durationMs, unixTime]`.
    nonisolated static func recordActivity(
        _ phase: String,
        startedAt: TimeInterval,
        detail: String? = nil
    ) {
        guard isEnabled, startedAt > 0 else { return }
        let durationMs = max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
        var line = String(format: "%.3f", Date().timeIntervalSince1970)
            + " " + phase
            + " " + String(format: "%.2f", durationMs)
        if let detail, !detail.isEmpty {
            line += " " + detail
        }
        line += "\n"
        queue.async { Self.append(line) }
    }

    /// Starts the release-safe main-thread turn monitor that emits `mainTurn` lines.
    ///
    /// A key event waits in AppKit's queue while the main thread is busy, so a long
    /// main-thread turn is the in-app cause of a spike. Comparing a key line against
    /// the surrounding `mainTurn` line separates "our main thread was busy" from "the
    /// event reached a responsive main thread late anyway" (another process holding
    /// the CPU, or the window server). Those two need different fixes, and a spike
    /// log alone cannot tell them apart. Does nothing unless the probe is enabled.
    static func installMainThreadTurnMonitorIfNeeded() {
        KeyLatencyMainTurnMonitor.shared.installIfNeeded()
    }
}

/// Logs main-thread turns long enough to delay a key event.
///
/// Release-safe counterpart of the DEBUG-only runloop monitors in `AppDelegate`:
/// the same runloop activity bookkeeping, but started only when the key-latency
/// probe is enabled, and written into the probe log so everything needed to
/// attribute a spike sits in one file instead of os_log plus a log stream.
final class KeyLatencyMainTurnMonitor {
    static let shared = KeyLatencyMainTurnMonitor()

    /// Shorter turns cannot explain a spike by themselves, and logging every turn
    /// would both bury the signal and add file I/O to the main thread.
    private let thresholdMs: Double = 20.0
    private var observer: CFRunLoopObserver?
    private var installed = false
    private var turnStart: TimeInterval?

    private init() {}

    func installIfNeeded() {
        guard KeyLatencyProbe.isEnabled, !installed else { return }

        var context = CFRunLoopObserverContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        observer = CFRunLoopObserverCreate(
            kCFAllocatorDefault,
            CFRunLoopActivity.allActivities.rawValue,
            true,
            CFIndex.max,
            { _, activity, info in
                guard let info else { return }
                let monitor = Unmanaged<KeyLatencyMainTurnMonitor>.fromOpaque(info).takeUnretainedValue()
                monitor.handle(activity: activity)
            },
            &context
        )

        guard let observer else { return }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        installed = true
    }

    private func handle(activity: CFRunLoopActivity) {
        let now = ProcessInfo.processInfo.systemUptime
        switch activity {
        case .entry, .afterWaiting:
            turnStart = now
        case .beforeWaiting, .exit:
            guard let start = turnStart else { return }
            turnStart = nil
            let elapsedMs = max(0, (now - start) * 1000.0)
            guard elapsedMs >= thresholdMs else { return }
            KeyLatencyProbe.recordActivity("mainTurn", startedAt: start)
        default:
            break
        }
    }
}

/// Synchronous callback ingress: duplicate titles are rejected before an
/// asynchronous message is enqueued. Each ingress belongs to one Ghostty view,
/// so its newest-value stream preserves that view's final title without a
/// process-global mailbox or cross-surface contention.
final class GhosttyTitleUpdateIngress {
    private let attachmentGeneration: AtomicUInt64Generation
    private let dispatcher: GhosttyTitleUpdateDispatcher
    private let titleChurnFilter: TerminalTitleChurnFilter
    private let continuation: AsyncStream<GhosttyTitleUpdate>.Continuation
    private let consumerTask: Task<Void, Never>
    /// Ghostty serializes action callbacks for a view; no other context reads
    /// or writes this duplicate-rejection snapshot.
    private var lastSubmittedUpdate: GhosttyTitleUpdate?
    init(
        center: NotificationCenter = .default,
        titleChurnFilter: TerminalTitleChurnFilter = TerminalTitleChurnFilter(),
        schedule: GhosttyTitleUpdateDispatcher.Scheduler? = nil
    ) {
        let attachmentGeneration = AtomicUInt64Generation()
        let dispatcher = GhosttyTitleUpdateDispatcher(
            attachmentGeneration: attachmentGeneration,
            schedule: schedule
        ) { updates in
#if DEBUG
            let timingStart = CmuxTypingTiming.start()
#endif
            for update in updates {
                let change = GhosttyTitleChange(
                    tabId: update.tabId,
                    surfaceId: update.surfaceId,
                    title: update.title,
                    stableTitle: update.stableTitle,
                    sourceSurfaceIdentifier: update.sourceSurfaceIdentifier,
                    terminalLifecycleID: update.terminalLifecycleID
                )
                center.post(name: .ghosttyDidSetTitle, object: nil, userInfo: change.userInfo)
            }
#if DEBUG
            CmuxTypingTiming.logDuration(
                path: "title.publish",
                startedAt: timingStart,
                extra: "published=\(updates.count)"
            )
#endif
        }
        let (updates, continuation) = AsyncStream<GhosttyTitleUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        self.attachmentGeneration = attachmentGeneration
        self.dispatcher = dispatcher
        self.titleChurnFilter = titleChurnFilter
        self.continuation = continuation
        consumerTask = Task {
            for await update in updates {
                await dispatcher.receive(update)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask.cancel()
    }

    /// Returns false when normalization removes a label-less spinner frame,
    /// when the update duplicates the callback-local snapshot, or when the
    /// ingress has already terminated.
    ///
    /// Animation frames are forwarded rather than collapsed, so the tab label
    /// still animates. What they carry is a `stableTitle` equal to the previous
    /// frame's, which is how a consumer distinguishes "the label changed" from
    /// "the spinner advanced" and skips the expensive path for the latter.
    @discardableResult
    func submit(
        tabId: UUID,
        surfaceId: UUID,
        sourceSurfaceIdentifier: ObjectIdentifier,
        terminalLifecycleID: UUID,
        title: String,
        titleOverride: String? = nil
    ) -> Bool {
        let displayTitle: String
        let stableTitle: String
        if let titleOverride {
            guard let boundedTitle = AutomaticTerminalTitle(titleOverride)?.value else {
                return false
            }
            // An override is already the resolved label; there is no frame in it.
            displayTitle = boundedTitle
            stableTitle = boundedTitle
        } else if let churnStableTitle = titleChurnFilter.stableTitle(for: title) {
            displayTitle = title
            stableTitle = churnStableTitle
        } else {
            // Nothing but spinner glyphs: no label to show, so drop it entirely.
            return false
        }
        let update = GhosttyTitleUpdate(
            tabId: tabId,
            surfaceId: surfaceId,
            title: displayTitle,
            stableTitle: stableTitle,
            sourceSurfaceIdentifier: sourceSurfaceIdentifier,
            terminalLifecycleID: terminalLifecycleID,
            attachmentGeneration: attachmentGeneration.loadRelaxed()
        )
        guard update != lastSubmittedUpdate else { return false }
        lastSubmittedUpdate = update
        switch continuation.yield(update) {
        case .enqueued, .dropped:
            return true
        case .terminated:
            return false
        @unknown default:
            return false
        }
    }

    func retireCurrentAttachment() {
        let nextGeneration = attachmentGeneration.advanceRelaxed()
        Task { [dispatcher] in
            await dispatcher.retireUpdates(before: nextGeneration)
        }
    }
}
