import XCTest
@testable import BOREAL

/// Pure-function tests for the per-set binomial code-budget pyramid.
/// These tests guard the conservation invariant (sum = 256) and the
/// power-of-two property the voxel-pack writer relies on.
final class PyramidTableTests: XCTestCase {

    func testPyramidLengthMatchesSetCount() {
        XCTAssertEqual(PyramidTable.pyramid.count, PyramidTable.setCount)
        XCTAssertEqual(PyramidTable.setCount, 16)
        XCTAssertEqual(PyramidTable.framesPerSet, 4)
        XCTAssertEqual(PyramidTable.totalFrameCount, 64)
    }

    func testPyramidLiteralValues() {
        XCTAssertEqual(PyramidTable.pyramid,
                       [1, 1, 2, 4, 8, 16, 32, 64,
                        64, 32, 16, 8, 4, 2, 1, 1])
    }

    func testPyramidSumIsConservation256() {
        XCTAssertEqual(PyramidTable.pyramid.reduce(0, +),
                       PyramidTable.codeBudgetSumPerChannel)
        XCTAssertEqual(PyramidTable.codeBudgetSumPerChannel, 256)
    }

    func testPyramidIsSymmetric() {
        let reversed = Array(PyramidTable.pyramid.reversed())
        XCTAssertEqual(PyramidTable.pyramid, reversed)
    }

    func testEveryBudgetIsPowerOfTwo() {
        for (idx, budget) in PyramidTable.pyramid.enumerated() {
            XCTAssertEqual(budget & (budget - 1), 0,
                           "set \(idx) budget \(budget) is not a power of two")
        }
    }

    func testBitsPerCodeMatchesLog2() {
        let expected = [0, 0, 1, 2, 3, 4, 5, 6,
                        6, 5, 4, 3, 2, 1, 0, 0]
        for setIdx in 0..<PyramidTable.setCount {
            XCTAssertEqual(PyramidTable.bitsPerCode(setIdx: setIdx),
                           expected[setIdx],
                           "bitsPerCode(\(setIdx))")
        }
    }
}
