// ════════════════════════════════════════════════════════════════
// FractalKernel — the (16×16)×(16×16) fractal record ordering and
// the BA5 temporal delta primitive, in the app.
//
//   patchMajor    reorders a row-major 256×256 frame into the H2 /
//                 PatchGrid convention: patch (v,u) outer row-major,
//                 inner (j,i) row-major —
//                 out[(v·16+u)·256 + j·16+i] = frame[(16v+j)·256 + 16u+i]
//                 On the pure-H frame this yields each option's home
//                 patch as one contiguous run of 256 (the seed's
//                 territory made literal in memory).
//   frameDelta    the (x,y,t) churn between consecutive frames as a
//                 lossless defection list (BA5): positions ascending,
//                 new value at each; applyDelta reproduces the next
//                 frame EXACTLY; churn = list length.
//
// Parity: spec/Boreal/Battle.hs (law BA5) → battle_golden.json →
// oracle → this file, checked bit-exact by spec/verify-swift.
// ════════════════════════════════════════════════════════════════

import Foundation

extension BorealKernels {

    // ── The fractal ordering (side 256, 16×16 patches of 16×16) ──

    static func patchMajor<T>(_ frame: [T]) -> [T] {
        precondition(frame.count == 65536, "patchMajor is the 256² ceiling ordering")
        var out = frame
        out.withUnsafeMutableBufferPointer { o in
            frame.withUnsafeBufferPointer { f in
                var w = 0
                for v in 0 ..< 16 {
                    for u in 0 ..< 16 {
                        for j in 0 ..< 16 {
                            let row = (16 * v + j) * 256 + 16 * u
                            for i in 0 ..< 16 {
                                o[w] = f[row + i]
                                w += 1
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func patchMajorInverse<T>(_ patches: [T]) -> [T] {
        precondition(patches.count == 65536, "patchMajorInverse is the 256² ceiling ordering")
        var out = patches
        out.withUnsafeMutableBufferPointer { o in
            patches.withUnsafeBufferPointer { p in
                var r = 0
                for v in 0 ..< 16 {
                    for u in 0 ..< 16 {
                        for j in 0 ..< 16 {
                            let row = (16 * v + j) * 256 + 16 * u
                            for i in 0 ..< 16 {
                                o[row + i] = p[r]
                                r += 1
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    // ── The BA5 temporal delta primitive ─────────────────────────

    static func frameDelta(_ a: [UInt8], _ b: [UInt8]) -> (pos: [Int32], new: [UInt8]) {
        precondition(a.count == b.count, "delta frames must share territory")
        var pos: [Int32] = []
        var new: [UInt8] = []
        for i in 0 ..< a.count where a[i] != b[i] {
            pos.append(Int32(i))
            new.append(b[i])
        }
        return (pos, new)
    }

    static func applyDelta(_ a: [UInt8], pos: [Int32], new: [UInt8]) -> [UInt8] {
        var out = a
        for k in 0 ..< pos.count { out[Int(pos[k])] = new[k] }
        return out
    }

    static func churn(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var c = 0
        for i in 0 ..< a.count where a[i] != b[i] { c += 1 }
        return c
    }

    // ── Structural self-test (harness-run) ───────────────────────

    static func fractalSelfTest() -> Bool {
        // Bijection: inverse ∘ patchMajor == id on a full permutation.
        let idFrame = (0 ..< 65536).map { Int32($0) }
        guard patchMajorInverse(patchMajor(idFrame)) == idFrame else { return false }
        // Pure-H: the up-arrow frame reorders to each option's 256-run
        // (H2 made literal: seed territory is contiguous patch-major).
        var pureH = [UInt8](repeating: 0, count: 65536)
        for y in 0 ..< 256 {
            for x in 0 ..< 256 {
                pureH[y * 256 + x] = UInt8((y / 16) * 16 + x / 16)
            }
        }
        var want = [UInt8](repeating: 0, count: 65536)
        for p in 0 ..< 256 {
            for k in 0 ..< 256 { want[p * 256 + k] = UInt8(p) }
        }
        guard patchMajor(pureH) == want else { return false }
        // Spot formula: pos (v,u,j,i) = (3,5,7,9).
        let outPos = (3 * 16 + 5) * 256 + 7 * 16 + 9
        let srcPos = (16 * 3 + 7) * 256 + 16 * 5 + 9
        return patchMajor(idFrame)[outPos] == Int32(srcPos)
    }
}
