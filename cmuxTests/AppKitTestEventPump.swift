import Foundation
import CmuxTerminal

/// Lets native callbacks and main-actor tasks run while a hosted-view test waits.
@MainActor
struct AppKitTestEventPump {
    func startSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        surface.requestInputDemandSurfaceStartIfNeeded()
        for await _ in readiness { break }
    }

    func drain() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    /// Pumps the main queue until `condition` holds.
    ///
    /// The budget is spent on *healthy* waiting only: when the main actor is busy
    /// with other suites in the same process (the CI job runs every suite at
    /// once), the wait extends instead of failing, and the timeout line in the CI
    /// log says whether the actor or the CPU was the bottleneck (TODO T13).
    func waitUntil(
        timeout: Duration = .seconds(1),
        hardLimit: Duration = .seconds(300),
        label: String = "AppKitTestEventPump.waitUntil",
        _ condition: () -> Bool
    ) async -> Bool {
        if condition() { return true }
        var clock = MainActorWaitClock(
            nominalStep: .milliseconds(1),
            budget: timeout,
            hardLimit: hardLimit
        )
        let heartbeat = MainActorWaitHeartbeat()
        while true {
            let start = ContinuousClock.now
            await drain()
            clock.record(start.duration(to: ContinuousClock.now))
            if condition() {
                _ = await heartbeat.stop()
                return true
            }
            guard !Task.isCancelled, !clock.isExhausted else { break }
        }
        let processStall = await heartbeat.stop()
        reportMainActorWaitTimeout(
            clock.diagnostic(label: label, detachedStall: processStall, state: nil)
        )
        return condition()
    }
}
