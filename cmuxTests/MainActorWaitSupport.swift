import Foundation
import os

/// Starvation-tolerant waiting for main-actor state changes (TODO T13).
///
/// The CI job runs every `cmuxTests` suite in one process, so the main actor is
/// shared with ~9000 other tests. It can be unavailable for tens of seconds
/// (measured in run 45034081189: 72 log gaps of 5 s or more, the longest 398 s).
/// A plain "poll until a state changes, give up after N seconds of wall clock"
/// turns that environment delay into a red test even when the code under test is
/// correct, because the transition is merely queued behind other work.
///
/// These helpers only spend their budget on time during which the main actor was
/// actually keeping up. Environment stalls extend the wait instead of failing it;
/// a hard wall-clock cap keeps a real hang from running to the job limit; and the
/// timeout diagnostic says whether the actor, the CPU, or the condition itself
/// was the reason, so the next red is diagnosable instead of mysterious.
@MainActor
struct MainActorWaitClock {
    /// Expected wall-clock cost of one wait iteration. Time spent beyond this is
    /// charged to the environment, not to the budget.
    let nominalStep: Duration
    /// Portion of the wall clock during which the main actor must keep up before
    /// the condition is declared unsatisfiable.
    let budget: Duration
    /// Absolute ceiling, so a genuinely hung condition still fails in test time.
    let hardLimit: Duration

    private let start = ContinuousClock.now
    private(set) var healthy: Duration = .zero
    private(set) var environmentStall: Duration = .zero
    private(set) var maxStall: Duration = .zero
    private(set) var iterations = 0

    init(
        nominalStep: Duration,
        budget: Duration,
        hardLimit: Duration = .seconds(600)
    ) {
        self.nominalStep = nominalStep
        self.budget = budget
        self.hardLimit = hardLimit
    }

    var wallClock: Duration { start.duration(to: ContinuousClock.now) }

    /// Charges one completed iteration to the budget or to the environment.
    mutating func record(_ elapsed: Duration) {
        iterations += 1
        if elapsed > nominalStep {
            let stall = elapsed - nominalStep
            environmentStall += stall
            if stall > maxStall { maxStall = stall }
            healthy += nominalStep
        } else {
            healthy += elapsed
        }
    }

    var isExhausted: Bool {
        healthy >= budget || wallClock >= hardLimit
    }

    /// One line for the CI log: how much of the wall clock the environment took,
    /// and which side was starving.
    func diagnostic(label: String, detachedStall: Duration?, state: String?) -> String {
        let kind: String
        if maxStall < .milliseconds(250) {
            kind = "actor-responsive"
        } else if let detachedStall, detachedStall >= .milliseconds(250) {
            kind = "process-starved"
        } else {
            kind = "actor-busy"
        }
        var line = "[MainActorWait] TIMEOUT label=\"\(label)\" kind=\(kind)"
        line += " healthy=\(Self.format(healthy)) budget=\(Self.format(budget))"
        line += " wall=\(Self.format(wallClock)) blocked=\(Self.format(environmentStall))"
        line += " iterations=\(iterations) maxActorStall=\(Self.format(maxStall))"
        if let detachedStall {
            line += " maxProcessStall=\(Self.format(detachedStall))"
        }
        if let state {
            line += " state=\(state)"
        }
        return line
    }

    private static func format(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
        return String(format: "%.2fs", seconds)
    }
}

/// Measures, from a non-main-actor task, how badly the whole process stalls.
/// A late main actor with a punctual heartbeat means the actor is busy; both late
/// means the runner itself is starved.
@MainActor
final class MainActorWaitHeartbeat {
    private let task: Task<Duration, Never>

    init(interval: Duration = .milliseconds(20)) {
        task = Task.detached(priority: .utility) {
            var maxGap = Duration.zero
            while !Task.isCancelled {
                let start = ContinuousClock.now
                try? await Task.sleep(for: interval)
                let elapsed = start.duration(to: ContinuousClock.now)
                if elapsed > maxGap { maxGap = elapsed }
            }
            return maxGap
        }
    }

    /// Stops the heartbeat and returns its longest observed gap.
    func stop() async -> Duration {
        task.cancel()
        return await task.value
    }
}

/// Writes one diagnostic line to stderr, where the CI log collects it.
@MainActor
func reportMainActorWaitTimeout(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

/// Waits for a main-actor condition, extending the budget through environment
/// stalls and reporting why it gave up.
@MainActor
func waitForMainActorState(
    budget: Duration = .seconds(30),
    hardLimit: Duration = .seconds(600),
    label: @autoclosure () -> String = "",
    state: (() -> String)? = nil,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    if condition() { return true }

    let tick = Duration.milliseconds(2)
    var clock = MainActorWaitClock(nominalStep: tick, budget: budget, hardLimit: hardLimit)
    let heartbeat = MainActorWaitHeartbeat()

    while true {
        let start = ContinuousClock.now
        try? await Task.sleep(for: tick)
        clock.record(start.duration(to: ContinuousClock.now))
        if condition() {
            _ = await heartbeat.stop()
            return true
        }
        if clock.isExhausted { break }
    }

    let processStall = await heartbeat.stop()
    reportMainActorWaitTimeout(
        clock.diagnostic(label: label(), detachedStall: processStall, state: state?())
    )
    return condition()
}

/// Resumes a continuation exactly once, so the operation and the timer can race.
private final class OneShotResume: @unchecked Sendable {
    private let resumed = OSAllocatedUnfairLock(initialState: false)
    private let continuation: CheckedContinuation<Bool, Never>

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(finished: Bool) {
        let isFirst = resumed.withLock { already -> Bool in
            guard !already else { return false }
            already = true
            return true
        }
        if isFirst { continuation.resume(returning: finished) }
    }
}

/// Runs `operation` with a deadline, so an un-bounded production wait cannot drag
/// the job to its 6-hour limit (run 44703813508 hung for 4 hours this way).
/// Returns `true` when `operation` finished in time.
///
/// Deliberately unstructured: a task group waits for every child on scope exit,
/// so a child stuck in a `CheckedContinuation` that never resumes (exactly how
/// `ProductAnalytics.drain()` wedges) would hang the wrapper too. Here the
/// operation task is simply abandoned when the timer wins — fine in a test
/// process that is about to report the failure.
@MainActor
func runWithMainActorDeadline(
    limit: Duration = .seconds(60),
    label: @autoclosure () -> String = "",
    _ operation: @escaping @Sendable () async -> Void
) async -> Bool {
    let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        let once = OneShotResume(continuation)
        Task {
            await operation()
            once.resume(finished: true)
        }
        Task {
            try? await Task.sleep(for: limit)
            once.resume(finished: false)
        }
    }
    if !finished {
        reportMainActorWaitTimeout(
            "[MainActorWait] DEADLINE label=\"\(label())\" limit=\(limit)"
        )
    }
    return finished
}
