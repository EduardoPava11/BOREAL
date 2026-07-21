import Foundation
import os

/// P0 instrumentation floor (BOREAL-METAL-PRECISION-WORKFLOW.md).
///
/// Every pipeline stage runs inside `Perf.shared.time(...)`: an os_signpost
/// interval (Instruments: subsystem com.daniel.boreal, category perf) plus a
/// wall-clock sample into this collector. Report bundles carry the numbers —
/// the standing rule is "no optimization claim without a before/after pair",
/// and this collector is where the pairs come from.
///
/// Thread-safe by a lock (stages run on detached reduction chains); reset at
/// the start of each run (single cycle or burst) so a report's perf block
/// describes exactly the run it ships with.
final class Perf: @unchecked Sendable {

    static let shared = Perf()

    private static let signposter = OSSignposter(subsystem: "com.daniel.boreal",
                                                 category: "perf")

    private let lock = NSLock()
    private var samples: [String: [Double]] = [:]     // stage → ms per call
    // Per-call timeline: (start offset since reset, duration), capped per
    // stage — lets a Mac session reconstruct WHEN each call ran, not just
    // its aggregate. ("More logs for you to read.")
    private var timeline: [String: [(t: Double, ms: Double)]] = [:]
    private static let timelineCap = 128
    private var thermal: [[String: Any]] = []         // trajectory, in run order
    private var peakFootprint: Int64 = 0
    private var epoch = ContinuousClock.now

    /// Start a fresh run: drop all samples, restart the clock, take the
    /// first thermal + footprint reading.
    func reset() {
        lock.lock()
        samples.removeAll()
        timeline.removeAll()
        thermal.removeAll()
        peakFootprint = Self.footprint()
        epoch = ContinuousClock.now
        lock.unlock()
        sampleThermal("start")
    }

    /// Time one pipeline stage: signpost interval + wall-clock sample +
    /// footprint peak update. The name is a StaticString so the interval
    /// shows up named in Instruments, not as a format string.
    func time<T>(_ stage: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = Self.signposter.beginInterval(stage)
        let t0 = ContinuousClock.now
        defer {
            Self.signposter.endInterval(stage, state)
            record("\(stage)", ms: Self.ms(since: t0))
        }
        return try body()
    }

    /// Async twin of `time` (capture awaits, reduction chain hops).
    func timeAsync<T>(_ stage: StaticString,
                      _ body: () async throws -> T) async rethrows -> T {
        let state = Self.signposter.beginInterval(stage)
        let t0 = ContinuousClock.now
        defer {
            Self.signposter.endInterval(stage, state)
            record("\(stage)", ms: Self.ms(since: t0))
        }
        return try await body()
    }

    /// Manual sample for stages timed at the call site (used around
    /// actor-isolated awaits a closure can't cleanly wrap, e.g. the
    /// AVFoundation bracket capture).
    func note(_ stage: String, ms: Double) { record(stage, ms: ms) }

    static func msSince(_ t0: ContinuousClock.Instant) -> Double { ms(since: t0) }

    /// One point on the thermal trajectory (burst start / every 4 cycles /
    /// end). `phys_footprint` rides along — it is the number Jetsam kills on.
    func sampleThermal(_ label: String) {
        let state: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  state = "nominal"
        case .fair:     state = "fair"
        case .serious:  state = "serious"
        case .critical: state = "critical"
        @unknown default: state = "unknown"
        }
        let fp = Self.footprint()
        lock.lock()
        defer { lock.unlock() }
        peakFootprint = max(peakFootprint, fp)
        thermal.append(["at": label,
                        "tMs": Self.ms(since: epoch),
                        "state": state,
                        "footprintMB": Double(fp) / 1_048_576.0])
    }

    /// The report.json `perf` block. JSON-safe types only.
    func reportBlock() -> [String: Any] {
        // Drain GPU timings from the Metal mapper (self-contained there so
        // the spec harness, which compiles Kernels/ alone, stays closed).
        let gpu = MetalIndexMapper.shared?.drainGPUSampleMs() ?? []
        lock.lock()
        defer { lock.unlock() }
        peakFootprint = max(peakFootprint, Self.footprint())
        var stages: [String: Any] = [:]
        for (name, xs) in samples {
            stages[name] = ["n": xs.count,
                            "medianMs": Self.median(xs),
                            "maxMs": xs.max() ?? 0,
                            "totalMs": xs.reduce(0, +)]
        }
        var block: [String: Any] = [
            "note": "wall-clock per stage (os_signpost twins in Instruments: com.daniel.boreal/perf); gpu = command-buffer gpuStartTime→gpuEndTime for the Metal index map; footprint = task_vm_info.phys_footprint; timeline = per-call [startMs sinceReset, durationMs], first 128 calls per stage",
            "stages": stages,
            "timeline": timeline.mapValues { calls in
                calls.map { [(($0.t * 100).rounded() / 100), (($0.ms * 1000).rounded() / 1000)] }
            },
            "thermal": thermal,
            "peakFootprintMB": Double(peakFootprint) / 1_048_576.0,
        ]
        if !gpu.isEmpty {
            block["gpu"] = ["indexMap": ["n": gpu.count,
                                         "medianMs": Self.median(gpu),
                                         "maxMs": gpu.max() ?? 0,
                                         "totalMs": gpu.reduce(0, +)]]
        }
        return block
    }

    // ── internals ───────────────────────────────────────────────────────────

    private func record(_ stage: String, ms: Double) {
        let fp = Self.footprint()
        lock.lock()
        samples[stage, default: []].append(ms)
        let end = Self.ms(since: epoch)
        if timeline[stage, default: []].count < Self.timelineCap {
            timeline[stage, default: []].append((t: end - ms, ms: ms))
        }
        peakFootprint = max(peakFootprint, fp)
        lock.unlock()
    }

    private static func ms(since t0: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - t0
        return Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
    }

    private static func median(_ xs: [Double]) -> Double {
        guard !xs.isEmpty else { return 0 }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Resident-memory truth: `phys_footprint` from task_vm_info — the
    /// figure the Jetsam memory limit is enforced against (RSS undercounts
    /// compressed + IOKit pages).
    private static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }
}
