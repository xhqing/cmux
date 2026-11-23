import Foundation
import Testing

/// Pins the semantics of the starvation-tolerant wait helpers (TODO T13).
///
/// The helpers exist to keep a busy main actor from turning a correct test red,
/// which makes two properties load-bearing: the budget must still expire for a
/// condition that never becomes true (otherwise nothing fails any more), and the
/// deadline wrapper must return instead of hanging (the job limit is hours away).
@MainActor
@Suite("Main actor wait support", .serialized)
struct MainActorWaitSupportTests {
    @Test("A condition that already holds returns immediately")
    func immediateCondition() async {
        let start = ContinuousClock.now
        let satisfied = await waitForMainActorState(budget: .seconds(1)) { true }
        #expect(satisfied)
        #expect(start.duration(to: ContinuousClock.now) < .milliseconds(500))
    }

    @Test("A condition that turns true while waiting is detected")
    func deferredCondition() async {
        let flag = FlagBox()
        let flip = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            flag.value = true
        }
        let satisfied = await waitForMainActorState(budget: .seconds(5)) { flag.value }
        _ = await flip.value
        #expect(satisfied)
        #expect(flag.value)
    }

    @Test("A condition that never turns true still fails once the healthy budget is spent")
    func exhaustedBudget() async {
        let start = ContinuousClock.now
        let satisfied = await waitForMainActorState(
            budget: .milliseconds(120),
            hardLimit: .seconds(5),
            label: "MainActorWaitSupportTests.exhaustedBudget",
            state: { "flag=false" }
        ) { false }
        let elapsed = start.duration(to: ContinuousClock.now)
        #expect(!satisfied)
        #expect(elapsed < .seconds(3), "The hard limit bounds a wedged condition")
    }

    @Test("The deadline wrapper finishes an operation that completes in time")
    func deadlineWrapperCompletes() async {
        let flag = FlagBox()
        let finished = await runWithMainActorDeadline(limit: .seconds(2)) {
            await MainActor.run { flag.value = true }
        }
        #expect(finished)
        #expect(flag.value)
    }

    @Test("The deadline wrapper gives up instead of hanging")
    func deadlineWrapperExpires() async {
        let start = ContinuousClock.now
        let finished = await runWithMainActorDeadline(
            limit: .milliseconds(80),
            label: "MainActorWaitSupportTests.deadlineWrapperExpires"
        ) {
            // The shape of a wedged `ProductAnalytics.drain()`: a continuation
            // that never resumes, so cancellation alone cannot unblock it.
            await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        }
        #expect(!finished)
        #expect(start.duration(to: ContinuousClock.now) < .seconds(3))
    }

    @MainActor
    private final class FlagBox {
        var value = false
    }
}
