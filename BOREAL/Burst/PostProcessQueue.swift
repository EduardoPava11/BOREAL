import Foundation

/// Bounded-concurrency queue for post-process work (DNG crop-tag rewrite + thumbnail
/// generation). Caps in-flight jobs at `limit` so memory stays bounded even during a
/// 64-frame burst with ~10 MB DNGs.
///
/// Previously: each frame spawned an unbounded `Task.detached`. At peak ~47 concurrent
/// tasks held ~470 MB of in-flight DNG data, triggering silent jetsam termination on
/// iPhone 17 Pro. This actor gates the work so peak memory stays ~30 MB.
actor PostProcessQueue {
    private let limit: Int
    private var inFlight: Int = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int = 2) {
        self.limit = limit
    }

    /// Awaits a free slot, then spawns the job as a detached Task. Returns immediately
    /// once the slot is granted (does NOT wait for `job` to finish).
    /// The job MUST eventually return — if it never does, all subsequent enqueues hang.
    func enqueue(_ job: @escaping @Sendable () async -> Void) async {
        while inFlight >= limit {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
        inFlight += 1
        Task.detached(priority: .userInitiated) { [weak self] in
            await job()
            await self?.complete()
        }
    }

    /// Blocks until all currently-in-flight work has completed.
    func drain() async {
        while inFlight > 0 {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                waiters.append(c)
            }
        }
    }

    private func complete() {
        inFlight -= 1
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }
}
