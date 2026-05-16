import XCTest
@testable import BOREAL

/// Tests the geometry invariants of the BOREAL center crop and the cropper's
/// behavior on synthetic mosaics. No real DNGs needed — the cropper is purely
/// a function over `BayerMosaic`, so synthetic samples that encode (row, col)
/// in their value let us assert exactly which sensor region was extracted.
final class BayerCenterCropperTests: XCTestCase {

    // MARK: - Geometry invariants (no input mosaic, just the constants)

    func testCropSizeMatches64TimesBlock() {
        XCTAssertEqual(BayerCropPlan.cropSize,
                       BayerCropPlan.binCount * BayerCropPlan.bayerBlockSize)
        XCTAssertEqual(BayerCropPlan.cropSize, 2944)
    }

    func testCropOriginIsEvenOnBothAxes() {
        XCTAssertEqual(BayerCropPlan.cropOriginX % 2, 0)
        XCTAssertEqual(BayerCropPlan.cropOriginY % 2, 0)
    }

    func testCropOriginCentersTheSquareOnSensor() {
        // Slack must be evenly split → origin == (sensorDim - cropSize) / 2.
        XCTAssertEqual(BayerCropPlan.cropOriginX,
                       (BayerCropPlan.sensorWidth - BayerCropPlan.cropSize) / 2)
        XCTAssertEqual(BayerCropPlan.cropOriginY,
                       (BayerCropPlan.sensorHeight - BayerCropPlan.cropSize) / 2)
        XCTAssertEqual(BayerCropPlan.cropOriginX, 544)
        XCTAssertEqual(BayerCropPlan.cropOriginY, 40)
    }

    func testCropFitsWithinSensor() {
        XCTAssertLessThanOrEqual(BayerCropPlan.cropOriginX + BayerCropPlan.cropSize,
                                 BayerCropPlan.sensorWidth)
        XCTAssertLessThanOrEqual(BayerCropPlan.cropOriginY + BayerCropPlan.cropSize,
                                 BayerCropPlan.sensorHeight)
    }

    func testRGGBCellsPerOutputPixel() {
        // 23² complete RGGB cells per 46×46 macropixel.
        XCTAssertEqual(BayerCropPlan.rggbCellsPerOutputPixel, 23 * 23)
        XCTAssertEqual(BayerCropPlan.rggbCellsPerOutputPixel, 529)
        XCTAssertEqual(BayerCropPlan.totalSamplesPerOutputPixel, 46 * 46)
    }

    // MARK: - Behavior on synthetic mosaics

    /// Build a 4032×3024 mosaic where each sample encodes its position with
    /// the row in the high byte and column in the low byte, mod 256. The
    /// truncation is fine — we only need a pattern that lets us assert where
    /// each sample originated.
    private func makeSensorMosaic() -> BayerMosaic {
        let w = BayerCropPlan.sensorWidth
        let h = BayerCropPlan.sensorHeight
        var samples = [UInt16](repeating: 0, count: w * h)
        for r in 0..<h {
            let hi = UInt16((r & 0xFF) << 8)
            for c in 0..<w {
                samples[r * w + c] = hi | UInt16(c & 0xFF)
            }
        }
        return BayerMosaic(width: w, height: h,
                           bitsPerSample: 14,
                           blackLevel: 528, whiteLevel: 16383,
                           samples: samples)
    }

    func testCenterCropProducesExpectedDimensions() throws {
        let src = makeSensorMosaic()
        let cropped = try BayerCenterCropper.centerCrop(src)
        XCTAssertEqual(cropped.width, BayerCropPlan.cropSize)
        XCTAssertEqual(cropped.height, BayerCropPlan.cropSize)
        XCTAssertEqual(cropped.samples.count,
                       BayerCropPlan.cropSize * BayerCropPlan.cropSize)
    }

    func testCenterCropPreservesBitDepthAndLevels() throws {
        let src = makeSensorMosaic()
        let cropped = try BayerCenterCropper.centerCrop(src)
        XCTAssertEqual(cropped.bitsPerSample, src.bitsPerSample)
        XCTAssertEqual(cropped.blackLevel, src.blackLevel)
        XCTAssertEqual(cropped.whiteLevel, src.whiteLevel)
    }

    func testCenterCropExtractsCorrectRegion() throws {
        let src = makeSensorMosaic()
        let cropped = try BayerCenterCropper.centerCrop(src)

        // Cropped (0,0) corresponds to source (40, 544).
        let topLeft = cropped.sample(row: 0, col: 0)
        XCTAssertEqual(topLeft, UInt16((40 & 0xFF) << 8) | UInt16(544 & 0xFF))

        // Cropped (cropSize-1, cropSize-1) corresponds to source (40+2943, 544+2943).
        let last = BayerCropPlan.cropSize - 1
        let bottomRight = cropped.sample(row: last, col: last)
        let srcRow = BayerCropPlan.cropOriginY + last  // 40 + 2943 = 2983
        let srcCol = BayerCropPlan.cropOriginX + last  // 544 + 2943 = 3487
        XCTAssertEqual(bottomRight, UInt16((srcRow & 0xFF) << 8) | UInt16(srcCol & 0xFF))

        // Spot-check an interior point.
        let mid = BayerCropPlan.cropSize / 2
        let interior = cropped.sample(row: mid, col: mid)
        let isr = BayerCropPlan.cropOriginY + mid
        let isc = BayerCropPlan.cropOriginX + mid
        XCTAssertEqual(interior, UInt16((isr & 0xFF) << 8) | UInt16(isc & 0xFF))
    }

    func testCenterCropPreservesRGGBPhase() throws {
        // Build a mosaic where each sample carries its (row%2, col%2) parity:
        //   R  (even, even) → 1000 + 0 + 0 = 1000
        //   Gr (even, odd ) → 1000 + 0 + 1 = 1001
        //   Gb (odd,  even) → 1000 + 2 + 0 = 1002
        //   B  (odd,  odd ) → 1000 + 2 + 1 = 1003
        let w = BayerCropPlan.sensorWidth
        let h = BayerCropPlan.sensorHeight
        var samples = [UInt16](repeating: 0, count: w * h)
        for r in 0..<h {
            for c in 0..<w {
                let rp = r % 2
                let cp = c % 2
                samples[r * w + c] = UInt16(1000 + rp * 2 + cp)
            }
        }
        let src = BayerMosaic(width: w, height: h,
                              bitsPerSample: 14,
                              blackLevel: 528, whiteLevel: 16383,
                              samples: samples)
        let cropped = try BayerCenterCropper.centerCrop(src)

        // Origin (544, 40) is even-even → R photosite. So cropped (0,0) must read 1000.
        XCTAssertEqual(cropped.sample(row: 0, col: 0), 1000, "cropped (0,0) must be R")
        XCTAssertEqual(cropped.sample(row: 0, col: 1), 1001, "cropped (0,1) must be Gr")
        XCTAssertEqual(cropped.sample(row: 1, col: 0), 1002, "cropped (1,0) must be Gb")
        XCTAssertEqual(cropped.sample(row: 1, col: 1), 1003, "cropped (1,1) must be B")
    }

    // MARK: - Error paths

    func testWrongSensorDimsThrows() {
        let badSamples = [UInt16](repeating: 0, count: 100 * 100)
        let bad = BayerMosaic(width: 100, height: 100,
                              bitsPerSample: 14,
                              blackLevel: 0, whiteLevel: 16383,
                              samples: badSamples)
        XCTAssertThrowsError(try BayerCenterCropper.centerCrop(bad)) { err in
            guard case BayerCenterCropper.CropError.wrongSensorDims = err else {
                return XCTFail("expected wrongSensorDims, got \(err)")
            }
        }
    }

    func testOddCropOriginThrows() {
        let src = makeSensorMosaic()
        XCTAssertThrowsError(
            try BayerCenterCropper.cropCenteredSquare(src, cropSize: 100,
                                                     originX: 545, originY: 40)
        ) { err in
            guard case BayerCenterCropper.CropError.oddCropOrigin = err else {
                return XCTFail("expected oddCropOrigin, got \(err)")
            }
        }
    }

    func testOversizeCropThrows() {
        let src = makeSensorMosaic()
        XCTAssertThrowsError(
            try BayerCenterCropper.cropCenteredSquare(src, cropSize: 5000,
                                                     originX: 0, originY: 0)
        ) { err in
            guard case BayerCenterCropper.CropError.cropTooLarge = err else {
                return XCTFail("expected cropTooLarge, got \(err)")
            }
        }
    }
}
