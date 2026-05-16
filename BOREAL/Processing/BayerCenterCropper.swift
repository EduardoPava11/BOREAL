import Foundation

/// Center-crop a sensor-sized Bayer mosaic to the BOREAL square crop, keeping
/// the cropped mosaic's (0, 0) on an R photosite of the original sensor.
///
/// Geometry comes from `BayerCropPlan`. For the iPhone 17 Pro 12 MP sensor:
///   input  4032 × 3024 RGGB
///   output 2944 × 2944 RGGB, taken from origin (544, 40)
///
/// Both crop-origin coordinates must be even. The constructor of `BayerCropPlan`
/// guarantees this for the canonical sensor; this function verifies it at
/// runtime so any future geometry change can't silently scramble Bayer phase.
enum BayerCenterCropper {

    enum CropError: Error, CustomStringConvertible {
        case wrongSensorDims(width: Int, height: Int, expected: (Int, Int))
        case oddCropOrigin(x: Int, y: Int)
        case cropTooLarge(cropSize: Int, sensorWidth: Int, sensorHeight: Int)

        var description: String {
            switch self {
            case .wrongSensorDims(let w, let h, let exp):
                return "expected sensor \(exp.0)×\(exp.1), got \(w)×\(h)"
            case .oddCropOrigin(let x, let y):
                return "crop origin (\(x), \(y)) must be even on both axes to preserve RGGB phase"
            case .cropTooLarge(let s, let w, let h):
                return "crop size \(s)×\(s) does not fit in sensor \(w)×\(h)"
            }
        }
    }

    /// Center-crop `src` to `BayerCropPlan.cropSize × BayerCropPlan.cropSize`
    /// using the canonical origin `(BayerCropPlan.cropOriginX, cropOriginY)`.
    static func centerCrop(_ src: BayerMosaic) throws -> BayerMosaic {
        guard src.width == BayerCropPlan.sensorWidth,
              src.height == BayerCropPlan.sensorHeight else {
            throw CropError.wrongSensorDims(
                width: src.width, height: src.height,
                expected: (BayerCropPlan.sensorWidth, BayerCropPlan.sensorHeight)
            )
        }
        return try cropCenteredSquare(src,
                                      cropSize: BayerCropPlan.cropSize,
                                      originX: BayerCropPlan.cropOriginX,
                                      originY: BayerCropPlan.cropOriginY)
    }

    /// General center-square crop with explicit origin. Exposed so tests can
    /// exercise edge cases (odd origin, oversize crop) without relying on the
    /// canonical numbers.
    static func cropCenteredSquare(_ src: BayerMosaic,
                                   cropSize s: Int,
                                   originX x0: Int,
                                   originY y0: Int) throws -> BayerMosaic {
        guard x0 % 2 == 0, y0 % 2 == 0 else {
            throw CropError.oddCropOrigin(x: x0, y: y0)
        }
        guard x0 >= 0, y0 >= 0,
              x0 + s <= src.width, y0 + s <= src.height else {
            throw CropError.cropTooLarge(cropSize: s,
                                         sensorWidth: src.width,
                                         sensorHeight: src.height)
        }

        var out: [UInt16] = []
        out.reserveCapacity(s * s)
        // Row-by-row copy: appendContentsOf on an array slice is the fast path
        // here — Swift's stdlib lowers it to a memmove inside the inline buffer.
        let srcW = src.width
        for row in y0..<(y0 + s) {
            let rowStart = row * srcW + x0
            out.append(contentsOf: src.samples[rowStart..<(rowStart + s)])
        }
        // Pass the CFA pattern through unchanged: even-origin crop preserves
        // the channel-at-(0,0) invariant, so the cropped mosaic carries the
        // same pattern as the source.
        return BayerMosaic(width: s,
                           height: s,
                           cfaPattern: src.cfaPattern,
                           bitsPerSample: src.bitsPerSample,
                           blackLevel: src.blackLevel,
                           whiteLevel: src.whiteLevel,
                           samples: out)
    }
}
