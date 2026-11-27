import Foundation

extension DispatchQueue {
    /// Runs `work` on this queue and waits for it at most `seconds`, returning
    /// whether it finished in time. Work that overruns keeps running, because a
    /// thread stuck in Core Audio can't be interrupted, and its finish is ignored.
    func run(within seconds: TimeInterval, _ work: @escaping @Sendable () -> Void) async -> Bool {
        let once = Once()
        return await withCheckedContinuation { continuation in
            self.async {
                work()
                if once.claim() { continuation.resume(returning: true) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { continuation.resume(returning: false) }
            }
        }
    }
}

/// Lets exactly one of several racing callers through.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}
