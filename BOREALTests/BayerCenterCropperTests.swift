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
        // iPhone 17 Pro main wide: sensor 4224×3024 → crop origin (640, 40).
        XCTAssertEqual(BayerCropPlan.cropOriginX,
                       (BayerCropPlan.sensorWidth - BayerCropPlan.cropSize) / 2)
        XCTAssertEqual(BayerCropPlan.cropOriginY,
                       (BayerCropPlan.sensorHeight - BayerCropPlan.cropSize) / 2)
        XCTAssertEqual(BayerCropPlan.cropOriginX, 640)
        XCTAssertEqual(BayerCropPlan.cropOriginY, 40)
        XCTAssertEqual(BayerCropPlan.sensorWidth, 4224)
        XCTAssertEqual(BayerCropPlan.sensorHeight, 3024)
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

    /// Build a 4224×3024 mosaic where each sample encodes its position with
    /// the row in the high byte and column in the low byte, mod 256. The
    /// truncation is fine — we only need a pattern that lets us assert where
    /// each sample originated. CFA pattern is BGGR (iPhone 17 Pro main wide).
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
                           cfaPattern: .bggr,
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

        // Cropped (0,0) corresponds to source (cropOriginY, cropOriginX) = (40, 640).
        let topLeft = cropped.sample(row: 0, col: 0)
        XCTAssertEqual(topLeft,
                       UInt16((BayerCropPlan.cropOriginY & 0xFF) << 8)
                       | UInt16(BayerCropPlan.cropOriginX & 0xFF))

        // Cropped (cropSize-1, cropSize-1) corresponds to source corner.
        let last = BayerCropPlan.cropSize - 1
        let bottomRight = cropped.sample(row: last, col: last)
        let srcRow = BayerCropPlan.cropOriginY + last  // 40 + 2943 = 2983
        let srcCol = BayerCropPlan.cropOriginX + last  // 640 + 2943 = 3583
        XCTAssertEqual(bottomRight, UInt16((srcRow & 0xFF) << 8) | UInt16(srcCol & 0xFF))

        // Spot-check an interior point.
        let mid = BayerCropPlan.cropSize / 2
        let interior = cropped.sample(row: mid, col: mid)
        let isr = BayerCropPlan.cropOriginY + mid
        let isc = BayerCropPlan.cropOriginX + mid
        XCTAssertEqual(interior, UInt16((isr & 0xFF) << 8) | UInt16(isc & 0xFF))
    }

    func testCenterCropPreservesBGGRPhase() throws {
        // iPhone 17 Pro main wide ships BGGR: B at (even,even), G at the
        // off-diagonals, R at (odd,odd). Build a synthetic mosaic where each
        // sample's value encodes its (row%2, col%2) parity, then verify the
        // cropped (0,0) lands on a B photosite (because cropOriginX=640 and
        // cropOriginY=40 are both even).
        //
        //   B (even, even) → 2000 + 0 + 0 = 2000
        //   G (even, odd ) → 2000 + 0 + 1 = 2001
        //   G (odd,  even) → 2000 + 2 + 0 = 2002
        //   R (odd,  odd ) → 2000 + 2 + 1 = 2003
        let w = BayerCropPlan.sensorWidth
        let h = BayerCropPlan.sensorHeight
        var samples = [UInt16](repeating: 0, count: w * h)
        for r in 0..<h {
            for c in 0..<w {
                samples[r * w + c] = UInt16(2000 + (r % 2) * 2 + (c % 2))
            }
        }
        let src = BayerMosaic(width: w, height: h,
                              cfaPattern: .bggr,
                              bitsPerSample: 14,
                              blackLevel: 528, whiteLevel: 16383,
                              samples: samples)
        let cropped = try BayerCenterCropper.centerCrop(src)

        // Origin (640, 40) is even-even → B photosite under BGGR.
        XCTAssertEqual(cropped.sample(row: 0, col: 0), 2000, "cropped (0,0) must be B (even,even)")
        XCTAssertEqual(cropped.sample(row: 0, col: 1), 2001, "cropped (0,1) must be G (even,odd)")
        XCTAssertEqual(cropped.sample(row: 1, col: 0), 2002, "cropped (1,0) must be G (odd,even)")
        XCTAssertEqual(cropped.sample(row: 1, col: 1), 2003, "cropped (1,1) must be R (odd,odd)")

        // CFA pattern carries through the crop.
        XCTAssertEqual(cropped.cfaPattern, .bggr)

        // Channel-at-position interpretation via CFAPattern.channel(...) matches.
        XCTAssertEqual(cropped.cfaPattern.channel(rowParity: 0, colParity: 0), .b)
        XCTAssertEqual(cropped.cfaPattern.channel(rowParity: 0, colParity: 1), .g)
        XCTAssertEqual(cropped.cfaPattern.channel(rowParity: 1, colParity: 0), .g)
        XCTAssertEqual(cropped.cfaPattern.channel(rowParity: 1, colParity: 1), .r)
    }

    // MARK: - Error paths

    func testWrongSensorDimsThrows() {
        let badSamples = [UInt16](repeating: 0, count: 100 * 100)
        let bad = BayerMosaic(width: 100, height: 100,
                              cfaPattern: .bggr,
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
