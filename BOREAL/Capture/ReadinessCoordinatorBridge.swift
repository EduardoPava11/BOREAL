import AVFoundation
import Foundation

/// Wraps `AVCapturePhotoOutputReadinessCoordinator` (iOS 17+, WWDC23) into a
/// suspension-friendly Swift Concurrency API.
///
/// Apple's design: the coordinator's delegate callback **always fires on the main
/// queue**, and a callback with the initial value is delivered as soon as the delegate
/// is set. That lets us pin the bridge to `@MainActor`.
///
/// `awaitReady(timeoutMs:)` returns when readiness == `.ready`, or throws
/// `BridgeError.timeout` if the deadline passes. Internally uses a `OneShot` ref
/// type so the delegate-callback path and the timeout path can race without
/// confusing the Swift 6 region-isolation checker.
@MainActor
final class ReadinessCoordinatorBridge: NSObject,
                                         AVCapturePhotoOutputReadinessCoordinatorDelegate {
    enum BridgeError: Error, CustomStringConvertible {
        case timeout(milliseconds: Int)
        var description: String {
            switch self {
            case .timeout(let ms): "readiness timeout after \(ms) ms"
            }
        }
    }

    private let coordinator: AVCapturePhotoOutputReadinessCoordinator
    private var currentReadiness: AVCapturePhotoOutput.CaptureReadiness = .sessionNotRunning
    private var waiters: [OneShot] = []

    init(photoOutput: AVCapturePhotoOutput) {
        self.coordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        super.init()
        self.coordinator.delegate = self
    }

    func startTracking(_ settings: AVCapturePhotoSettings) {
        coordinator.startTrackingCaptureRequest(using: settings)
    }

    func stopTracking(uniqueID: Int64) {
        coordinator.stopTrackingCaptureRequest(using: uniqueID)
    }

    func awaitReady(timeoutMs: Int = 2_000) async throws {
        if currentReadiness == .ready { return }

        let oneShot = OneShot()
        waiters.append(oneShot)

        // Fire a timeout Task that fails the oneshot if readiness never arrives.
        // The delegate callback (handleReadinessChange) will succeed it on `.ready`.
        Task.detached { [timeoutMs] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            oneShot.fail(BridgeError.timeout(milliseconds: timeoutMs))
        }

        try await oneShot.wait()
    }

    // MARK: AVCapturePhotoOutputReadinessCoordinatorDelegate

    nonisolated func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator,
                                          captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness) {
        // Apple guarantees this fires on the main queue.
        MainActor.assumeIsolated {
            self.handleReadinessChange(captureReadiness)
        }
    }

    private func handleReadinessChange(_ r: AVCapturePhotoOutput.CaptureReadiness) {
        currentReadiness = r
        Log.capture.info("Readiness → \(String(describing: r), privacy: .public)")
        if r == .ready {
            let toResume = waiters
            waiters.removeAll()
            for w in toResume { w.succeed() }
        }
    }
}

/// Typed one-shot continuation wrapper. Exactly one of `succeed(_:)` / `fail(_:)`
/// actually resumes the underlying CheckedContinuation; further calls are no-ops.
///
/// Used to mediate between a delegate callback (success path) and a timeout Task
/// (failure path) without the region-isolation checker objecting to the typical
/// TaskGroup-with-nested-continuation pattern.
final class OneShotResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var pendingValue: Result<T, Error>?
    private var resumed = false

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            lock.lock()
            if resumed, let pending = pendingValue {
                lock.unlock()
                switch pending {
                case .success(let v): c.resume(returning: v)
                case .failure(let e): c.resume(throwing: e)
                }
                return
            }
            continuation = c
            lock.unlock()
        }
    }

    func succeed(_ value: T) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = continuation
        continuation = nil
        if c == nil { pendingValue = .success(value) }
        lock.unlock()
        c?.resume(returning: value)
    }

    func fail(_ error: Error) {
        lock.lock()
        if resumed { lock.unlock(); return }
        resumed = true
        let c = continuation
        continuation = nil
        if c == nil { pendingValue = .failure(error) }
        lock.unlock()
        c?.resume(throwing: error)
    }
}

/// Void-typed convenience alias.
typealias OneShot = OneShotResult<Void>

extension OneShotResult where T == Void {
    func succeed() { succeed(()) }
}

/// Convenience typealias for the CaptureService's specific use.
typealias OneShotRaw = OneShotResult<CapturedRaw>
