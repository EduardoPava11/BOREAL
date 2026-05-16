import XCTest
@testable import BOREAL

/// Pure-function tests for the burst state machine. No AVFoundation; no async.
final class BurstReducerTests: XCTestCase {

    // MARK: - Happy path

    func testIdleTapStartsPreparing() {
        let s = BurstReducer.reduce(.idle, .tapCapture)
        XCTAssertEqual(s, .preparing)
    }

    func testPreparedStartsCapturingSlotZero() {
        let s = BurstReducer.reduce(.preparing, .prepared)
        if case .capturing(let slot, let captured, let skipped, _) = s {
            XCTAssertEqual(slot, 0)
            XCTAssertEqual(captured, 0)
            XCTAssertEqual(skipped, [])
        } else {
            XCTFail("Expected .capturing, got \(s)")
        }
    }

    func testDeliveredAdvancesSlot() {
        // With targetFrameCount == 4, advancing from mid-burst slot 1 → 2 is the
        // analog of the old "5 → 6" intermediate-advance test.
        let from = BurstState.capturing(slot: 1, captured: 1, skipped: [], startedAt: Date())
        let raw = makeRaw(slot: 1)
        let s = BurstReducer.reduce(from, .frameDelivered(raw))
        if case .capturing(let slot, let captured, let skipped, _) = s {
            XCTAssertEqual(slot, 2)
            XCTAssertEqual(captured, 2)
            XCTAssertEqual(skipped, [])
        } else {
            XCTFail("Expected .capturing(slot: 2), got \(s)")
        }
    }

    func testSkippedAdvancesSlotAndRecordsIndex() {
        let from = BurstState.capturing(slot: 1, captured: 1, skipped: [], startedAt: Date())
        let s = BurstReducer.reduce(from, .frameSkipped(slot: 1, reason: .timeout))
        if case .capturing(let slot, let captured, let skipped, _) = s {
            XCTAssertEqual(slot, 2)
            XCTAssertEqual(captured, 1)
            XCTAssertEqual(skipped, [1])
        } else {
            XCTFail("Expected .capturing(slot: 2), got \(s)")
        }
    }

    func testLastSlotDeliveredEntersDone() {
        // Terminal slot is targetFrameCount - 1 (= 3 in MVP scope). Under
        // synchronous post-process the reducer skips .draining entirely and
        // transitions directly to .done — by the time AppCoordinator's
        // applyEventSideEffects has called postProcessFrame for this slot,
        // all per-frame writes are committed, no async work to drain.
        let last = BurstReducer.targetFrameCount - 1
        let from = BurstState.capturing(slot: last, captured: last, skipped: [], startedAt: Date())
        let raw = makeRaw(slot: last)
        let s = BurstReducer.reduce(from, .frameDelivered(raw))
        if case .done(let captured, let skipped, _, _) = s {
            XCTAssertEqual(captured, BurstReducer.targetFrameCount)
            XCTAssertEqual(skipped, [])
        } else {
            XCTFail("Expected .done, got \(s)")
        }
    }

    func testLastSlotSkippedWithCapturedEntersDone() {
        // Captured the first half, skipped the rest including the terminal slot.
        // Same .draining → .done collapse as the delivered case above.
        let last = BurstReducer.targetFrameCount - 1
        let halfCaptured = BurstReducer.targetFrameCount / 2
        let from = BurstState.capturing(slot: last,
                                        captured: halfCaptured,
                                        skipped: Array(halfCaptured..<last),
                                        startedAt: Date())
        let s = BurstReducer.reduce(from, .frameSkipped(slot: last, reason: .timeout))
        if case .done(let captured, let skipped, _, _) = s {
            XCTAssertEqual(captured, halfCaptured)
            XCTAssertEqual(skipped, Array(halfCaptured..<BurstReducer.targetFrameCount))
        } else {
            XCTFail("Expected .done, got \(s)")
        }
    }

    func testAllSkippedGoesStraightToDone() {
        let last = BurstReducer.targetFrameCount - 1
        let from = BurstState.capturing(slot: last,
                                        captured: 0,
                                        skipped: Array(0..<last),
                                        startedAt: Date())
        let s = BurstReducer.reduce(from, .frameSkipped(slot: last, reason: .timeout))
        if case .done(let captured, let skipped, _, _) = s {
            XCTAssertEqual(captured, 0)
            XCTAssertEqual(skipped.count, BurstReducer.targetFrameCount)
        } else {
            XCTFail("Expected .done with zero captured, got \(s)")
        }
    }

    func testPostProcessDecrementsAndCompletesDraining() {
        let started = Date()
        let from = BurstState.draining(captured: 3, skipped: [10], postProcessLeft: 1, startedAt: started)
        let s = BurstReducer.reduce(from, .postProcessFinished(slot: 0, success: true))
        if case .done(let captured, let skipped, _, _) = s {
            XCTAssertEqual(captured, 3)
            XCTAssertEqual(skipped, [10])
        } else {
            XCTFail("Expected .done, got \(s)")
        }
    }

    func testPostProcessIntermediateStaysInDraining() {
        let from = BurstState.draining(captured: 10, skipped: [], postProcessLeft: 5, startedAt: Date())
        let s = BurstReducer.reduce(from, .postProcessFinished(slot: 0, success: true))
        if case .draining(_, _, let left, _) = s {
            XCTAssertEqual(left, 4)
        } else {
            XCTFail("Expected .draining(left: 4), got \(s)")
        }
    }

    // MARK: - Universal events

    func testUserResetReturnsToIdleFromAnyState() {
        let states: [BurstState] = [
            .preparing,
            .capturing(slot: 30, captured: 30, skipped: [], startedAt: Date()),
            .draining(captured: 60, skipped: [], postProcessLeft: 2, startedAt: Date()),
            .done(captured: 64, skipped: [], folder: URL(fileURLWithPath: "/tmp"), durationSec: 2.3),
            .failed(message: "x"),
        ]
        for s in states {
            XCTAssertEqual(BurstReducer.reduce(s, .userReset), .idle, "from \(s)")
        }
    }

    func testFailedFromAnyStateGoesToFailed() {
        let from = BurstState.capturing(slot: 10, captured: 10, skipped: [], startedAt: Date())
        let s = BurstReducer.reduce(from, .failed("oops"))
        XCTAssertEqual(s, .failed(message: "oops"))
    }

    // MARK: - Idempotent / stale events

    func testStaleDeliveryInDraining() {
        let from = BurstState.draining(captured: 30, skipped: [], postProcessLeft: 5, startedAt: Date())
        let raw = makeRaw(slot: 5)  // out-of-order delivery
        let s = BurstReducer.reduce(from, .frameDelivered(raw))
        XCTAssertEqual(s, from, "stale .frameDelivered in .draining is a no-op")
    }

    func testWrongSlotDeliveryIgnored() {
        let from = BurstState.capturing(slot: 5, captured: 5, skipped: [], startedAt: Date())
        let raw = makeRaw(slot: 10)  // wrong slot — guard against reordering
        let s = BurstReducer.reduce(from, .frameDelivered(raw))
        XCTAssertEqual(s, from, "delivery for slot != current is ignored")
    }

    // MARK: - .setComplete (Phase 2 trigger event)

    func testSetCompleteIsNoopForFSM() {
        // .setComplete is a side-effect-only event: it triggers the Phase 2
        // pipeline in AppCoordinator.applyEventSideEffects, but the FSM
        // state machine never transitions on it. Verify across all states.
        let states: [BurstState] = [
            .idle,
            .preparing,
            .capturing(slot: 0, captured: 0, skipped: [], startedAt: Date()),
            .draining(captured: 4, skipped: [], postProcessLeft: 4, startedAt: Date()),
            .done(captured: 4, skipped: [], folder: URL(fileURLWithPath: "/tmp"), durationSec: 0.5),
            .failed(message: "x"),
        ]
        for s in states {
            XCTAssertEqual(BurstReducer.reduce(s, .setComplete(setIdx: 0)), s,
                           ".setComplete must be a no-op from any state, was \(s)")
        }
    }

    // MARK: - Helpers

    private func makeRaw(slot: Int) -> CapturedRaw {
        CapturedRaw(
            slot: slot,
            dngBytes: Data([0x4D, 0x4D, 0x00, 0x2A]),   // BE TIFF magic, not really a DNG
            hardwareTimestamp: .zero,
            wallClock: Date()
        )
    }
}
