// ════════════════════════════════════════════════════════════════
// CycleSetKernel — the 4-DNG cycle's positional phase decomposition:
// what the network sees, in the app (spec/Boreal/CycleSet.hs, N laws).
//
//   csPhasePlanes   mosaic S² → 4 positional phase planes, each
//                   (S/2)²: plane_p[y][x] = mosaic[2y+py][2x+px],
//                   offsets (0,0),(0,1),(1,0),(1,1) — POSITIONAL and
//                   CFA-agnostic (the bijection never consults the
//                   CFA; color meaning is metadata, never geometry)
//   csAssemble      the exact inverse (N1: assemble ∘ phasePlanes
//                   == id — the network sees everything, once)
//   csCycleTensor   4 EV-normalized frames × 4 phases = 16 channels,
//                   frame-major: channel = 4·frame + phase (N2)
//
// Parity: spec/Boreal/CycleSet.hs → cycleset_golden.json → oracle →
// this file, Q16-exact in spec/verify-swift.
// ════════════════════════════════════════════════════════════════

import Foundation

extension BorealKernels {

    /// The positional phase offsets in normative order (N laws):
    /// phase 0 = (even,even), 1 = (even,odd), 2 = (odd,even), 3 = (odd,odd).
    static let csPhaseOffsets: [(py: Int, px: Int)] = [(0, 0), (0, 1), (1, 0), (1, 1)]

    /// Normative channel bookkeeping (N2): c = 4·frame + phase, frame-major.
    static func csChannelIndex(frame: Int, phase: Int) -> Int {
        4 * frame + phase
    }

    /// One mosaic S² (row-major) → 4 phase planes, each (S/2)² row-major.
    /// nil unless the side is even and the mosaic covers side².
    static func csPhasePlanes(mosaic: [Float], side: Int) -> [[Float]]? {
        guard side > 0, side % 2 == 0, mosaic.count >= side * side else { return nil }
        let half = side / 2
        return csPhaseOffsets.map { off in
            var plane = [Float](repeating: 0, count: half * half)
            for y in 0 ..< half {
                let row = (2 * y + off.py) * side
                for x in 0 ..< half {
                    plane[y * half + x] = mosaic[row + 2 * x + off.px]
                }
            }
            return plane
        }
    }

    /// Exact inverse (N1): interleave the 4 planes back into the S² mosaic.
    static func csAssemble(planes: [[Float]], side: Int) -> [Float]? {
        guard side > 0, side % 2 == 0, planes.count == 4 else { return nil }
        let half = side / 2
        guard planes.allSatisfy({ $0.count == half * half }) else { return nil }
        var mosaic = [Float](repeating: 0, count: side * side)
        for (p, off) in csPhaseOffsets.enumerated() {
            let plane = planes[p]
            for y in 0 ..< half {
                let row = (2 * y + off.py) * side
                for x in 0 ..< half {
                    mosaic[row + 2 * x + off.px] = plane[y * half + x]
                }
            }
        }
        return mosaic
    }

    /// The cycle tensor (N2): 4 EV-normalized frames → 16 channels,
    /// frame-major (channel c = 4·frame + phase), each (S/2)².
    static func csCycleTensor(frames: [[Float]], side: Int) -> [[Float]]? {
        guard frames.count == 4 else { return nil }
        var out: [[Float]] = []
        out.reserveCapacity(16)
        for f in frames {
            guard let planes = csPhasePlanes(mosaic: f, side: side) else { return nil }
            out.append(contentsOf: planes)
        }
        return out
    }
}
