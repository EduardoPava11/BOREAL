import Foundation

/// The V1 objective statistic (spec/Boreal/Binomial.hs): how close an index
/// frame sits to the balanced ideal B(n, 1/256). χ² = 0 is the A2
/// permutation at the bijection rung; one-color collapse scores 255·n.
/// Our frame sizes (256·4^k) make χ² dyadic — the Double is bit-exact.
extension BorealKernels {

    static func usageHistogram(_ indices: [UInt8]) -> [Int] {
        var counts = [Int](repeating: 0, count: 256)
        for i in indices { counts[Int(i)] += 1 }
        return counts
    }

    static func chiSquare(counts: [Int]) -> Double {
        let n = counts.reduce(0, +)
        guard n > 0 else { return 0 }
        let expected = Double(n) / 256
        var acc = 0.0
        for c in counts {
            let d = Double(c) - expected
            acc += d * d
        }
        return acc * 256 / Double(n)
    }

    static func indexChiSquare(_ indices: [UInt8]) -> Double {
        chiSquare(counts: usageHistogram(indices))
    }
}
