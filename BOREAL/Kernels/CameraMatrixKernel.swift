import Foundation

/// Camera → ProPhoto matrix composition (Boreal.ColorPath CQ9/CQ10,
/// the NT law). Ported from spec/Boreal/ColorPath.hs; verified bitwise
/// against colorpath_golden.json's `camera` section by the gate.
///
/// THE NEUTRAL TEST (NT, normative): the composed matrix must map
/// AsShotNeutral to EQUAL ProPhoto channels. The 2026-07-19 device
/// magenta was an NT violation: the old decoder bolted the WB diagonal
/// onto an INVERTED ColorMatrix — a composition only valid for a true
/// ForwardMatrix — applying white balance twice.
///
/// Op shapes are pinned to the spec (same expression trees in Haskell /
/// Python / Swift → bit-identical f64). All math in Double; the decoder
/// rounds to Float once, at the Frame boundary.
extension BorealKernels {

    /// XYZ (D50) → ProPhoto linear (Lindbloom inverse literals).
    static let xyzToProphotoD50: [Double] = [
        1.3459434, -0.2556075, -0.0511118,
        -0.5445988, 1.5081673,  0.0205351,
        0.0,        0.0,        1.2118128,
    ]

    /// Bradford cone response (classic CAT literals).
    static let bradfordCone: [Double] = [
        0.8951, 0.2664, -0.1614,
        -0.7502, 1.7135, 0.0367,
        0.0389, -0.0685, 1.0296,
    ]

    /// D50 white = prophotoToXyzD50 · (1,1,1) — ONE source of truth
    /// (the ProPhoto rows sum to D50 white by construction).
    static let d50White: (Double, Double, Double) = apply3d(
        prophotoToXyzD50, (1, 1, 1))

    /// row·vec, m0·v0 + m1·v1 + m2·v2 left-to-right, no FMA (spec order).
    static func apply3d(_ m: [Double],
                        _ v: (Double, Double, Double)) -> (Double, Double, Double) {
        (m[0] * v.0 + m[1] * v.1 + m[2] * v.2,
         m[3] * v.0 + m[4] * v.1 + m[5] * v.2,
         m[6] * v.0 + m[7] * v.1 + m[8] * v.2)
    }

    /// c[i][j] = a[i][0]·b[0][j] + a[i][1]·b[1][j] + a[i][2]·b[2][j],
    /// left-to-right (spec order — NOT an accumulator loop).
    static func mul3d(_ a: [Double], _ b: [Double]) -> [Double] {
        var c = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            for j in 0..<3 {
                c[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j]
                    + a[i * 3 + 2] * b[6 + j]
            }
        }
        return c
    }

    /// 3×3 inverse, cofactor expansion, pinned op shapes (spec inv3).
    /// nil on a (near-)singular matrix — callers degrade to no-color.
    static func inv3d(_ m: [Double]) -> [Double]? {
        let det = m[0] * (m[4] * m[8] - m[5] * m[7])
            - m[1] * (m[3] * m[8] - m[5] * m[6])
            + m[2] * (m[3] * m[7] - m[4] * m[6])
        guard abs(det) > 1e-12 else { return nil }
        let iv = 1 / det
        return [
            (m[4] * m[8] - m[5] * m[7]) * iv, (m[2] * m[7] - m[1] * m[8]) * iv,
            (m[1] * m[5] - m[2] * m[4]) * iv,
            (m[5] * m[6] - m[3] * m[8]) * iv, (m[0] * m[8] - m[2] * m[6]) * iv,
            (m[2] * m[3] - m[0] * m[5]) * iv,
            (m[3] * m[7] - m[4] * m[6]) * iv, (m[1] * m[6] - m[0] * m[7]) * iv,
            (m[0] * m[4] - m[1] * m[3]) * iv,
        ]
    }

    /// Bradford adaptation: arbitrary white → D50.
    static func bradfordToD50(_ w: (Double, Double, Double)) -> [Double]? {
        guard let coneInv = inv3d(bradfordCone) else { return nil }
        let cw = apply3d(bradfordCone, w)
        let cd = apply3d(bradfordCone, d50White)
        guard cw.0 != 0, cw.1 != 0, cw.2 != 0 else { return nil }
        let diag: [Double] = [cd.0 / cw.0, 0, 0, 0, cd.1 / cw.1, 0, 0, 0, cd.2 / cw.2]
        return mul3d(coneInv, mul3d(diag, bradfordCone))
    }

    /// FM path: M = P · FM · diag(g/asn_r, 1, g/asn_b) — a DNG
    /// ForwardMatrix consumes WHITE-BALANCED camera values, so the WB
    /// diagonal belongs here (and ONLY here).
    static func cameraToProPhotoFM(_ fm: [Double],
                                   asn: (Double, Double, Double)) -> [Double]? {
        guard fm.count == 9, asn.0 > 0, asn.1 > 0, asn.2 > 0 else { return nil }
        let (mr, mg, mb) = (asn.1 / asn.0, 1.0, asn.1 / asn.2)
        var fmWB = [Double](repeating: 0, count: 9)
        for i in 0..<3 {
            fmWB[i * 3] = fm[i * 3] * mr
            fmWB[i * 3 + 1] = fm[i * 3 + 1] * mg
            fmWB[i * 3 + 2] = fm[i * 3 + 2] * mb
        }
        return mul3d(xyzToProphotoD50, fmWB)
    }

    /// CM fallback (the iPhone live path): white balance is IMPLICIT —
    /// inv(CM) carries the real neutral to the scene white; Bradford
    /// carries the scene white to D50. NO wb diagonal.
    static func cameraToProPhotoCM(_ cm: [Double],
                                   asn: (Double, Double, Double)) -> [Double]? {
        guard cm.count == 9, asn.0 > 0, asn.1 > 0, asn.2 > 0,
              let camToXYZ = inv3d(cm) else { return nil }
        let xw = apply3d(camToXYZ, asn)
        guard xw.1 > 0 else { return nil }
        guard let brad = bradfordToD50((xw.0 / xw.1, 1, xw.2 / xw.1)) else { return nil }
        return mul3d(xyzToProphotoD50, mul3d(brad, camToXYZ))
    }
}
