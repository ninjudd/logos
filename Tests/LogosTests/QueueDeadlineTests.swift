import Foundation
import Testing
@testable import Logos

@Suite struct QueueDeadlineTests {
    // Catches the deadline reporting a stall for work that finished, and the timer
    // that fires afterwards resuming the wait a second time, which traps.
    @Test func workThatFinishesInTimeSucceeds() async throws {
        let queue = DispatchQueue(label: "test")
        let finished = await queue.run(within: 0.2) {}
        #expect(finished)
        try await Task.sleep(for: .milliseconds(400))
    }

    // Catches a wait that lasts as long as the work, which would hold every later
    // dictation behind a stalled stop, and the late finish resuming the wait a second time.
    @Test func workThatOverrunsIsAbandoned() async {
        let queue = DispatchQueue(label: "test")
        let stuck = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { stuck.signal() }
        let finished = await queue.run(within: 0.05) { stuck.wait() }
        #expect(!finished)
        // The queue is serial, so this runs after the overrunning work and its claim.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
