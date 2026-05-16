import XCTest
@testable import BOREAL

/// Pins the contract that `CaptureService.prepare()` is idempotent — the second
/// call must return immediately without invoking AVFoundation.
///
/// Why this matters: BOREAL has TWO call sites for `prepare()`. The eager preview
/// path in `AppCoordinator.preparePreviewIfNeeded()` calls it on first appear,
/// then the burst-tap path in `runPrepare()` calls it again. Without the
/// `isConfigured` guard, the second call ran `beginConfiguration` +
/// `removeInput/removeOutput` on an already-running session, which left
/// `FigCaptureSourceRemote` in an inconsistent state and bailed with err=-17281.
///
/// We exercise the early-return contract directly (without calling AVFoundation)
/// by constructing the service in a "pre-configured" state via the test-only
/// initializer. If `prepare()` actually attempted real configuration, it would
/// throw "No back camera" on the simulator — so a successful `prepare()` here
/// proves the early-return path was taken.
@MainActor
final class CaptureServiceIdempotencyTests: XCTestCase {

    func testPrepareEarlyReturnsWhenAlreadyConfigured() async throws {
        let service = CaptureService(configuredFromTest: true)
        XCTAssertTrue(service.isConfigured)

        // If this call went into configureLocked() it would throw "No back camera"
        // on the simulator. Successful return == early-return path was taken.
        try await service.prepare()

        XCTAssertTrue(service.isConfigured, "isConfigured must remain true after no-op prepare()")
    }

    func testFreshServiceStartsUnconfigured() {
        let service = CaptureService()
        XCTAssertFalse(service.isConfigured,
                       "fresh CaptureService must report isConfigured=false")
    }

    func testTestOnlyInitDefaultsToFalse() {
        // The test-only initializer must default to false so production code
        // calling the no-arg init() goes through the normal configuration path.
        let service = CaptureService(configuredFromTest: false)
        XCTAssertFalse(service.isConfigured)
    }
}
