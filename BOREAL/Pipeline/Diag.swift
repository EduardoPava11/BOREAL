import Foundation

/// Diag — the device's own narrative, written for the Mac session that
/// reads the bundle ("more logs for you to read"). A thread-safe line
/// buffer, reset alongside Perf at the start of each run; every line is
/// timestamped against the run epoch, mirrored to os.Logger (Console),
/// and drained into the bundle as `log.txt`.
final class Diag: @unchecked Sendable {

    static let shared = Diag()
    private static let cap = 4000

    private let lock = NSLock()
    private var lines: [String] = []
    private var epoch = ContinuousClock.now

    func reset() {
        lock.lock()
        lines.removeAll()
        epoch = ContinuousClock.now
        lock.unlock()
        log("meta", BundleStamp.line())
    }

    func log(_ tag: String, _ msg: String) {
        lock.lock()
        let d = ContinuousClock.now - epoch
        let t = Double(d.components.seconds) * 1000
            + Double(d.components.attoseconds) / 1e15
        if lines.count < Self.cap {
            lines.append(String(format: "[%9.1f] %@: %@", t, tag, msg))
        }
        lock.unlock()
        blog.info("\(tag, privacy: .public): \(msg, privacy: .public)")
    }

    /// The full narrative for the bundle's log.txt.
    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n") + "\n"
    }
}
