-- ════════════════════════════════════════════════════════════════
-- Boreal.Binomial — the V1 objective: the binomial approximation
-- at 16×16 colors.
--
-- An index frame of n pixels over the 256-color seed palette is
-- BINOMIALLY PERFECT when its usage histogram matches the balanced
-- ideal: every color used n/256 times (at the bijection rung
-- n = 256, that is the PERMUTATION — each color exactly once,
-- OneSix A2 realized). Deviation is measured by the χ² statistic
-- against B(n, 1/256):
--
--     χ² = Σⱼ (cⱼ − n/256)² · 256 / n
--
-- χ² = 0 iff perfectly balanced; uniform-random indexing sits near
-- E[χ²] ≈ 255; scene-collapsed palettes blow far past it. All our
-- frame sizes are 256·4^k, so n/256 is an integer and χ² is a
-- DYADIC rational — exact in f64, bit-exact across every port.
--
-- Why this is the V1 target: balanced usage = maximal entropy of
-- the 8-bit index stream = the palette EARNS all 256 of its codes
-- — the rate of the GIF's one lossy stage is fully spent. V1 is a
-- bare-bones palette encoder judged by exactly this number (plus
-- the bell and ΔE); everything fancier reasons on top of it.
-- ════════════════════════════════════════════════════════════════

module Boreal.Binomial where

-- Usage histogram: 256 counts from an index frame.
usageHistogram :: [Int] -> [Int]
usageHistogram indices =
  [ length (filter (== j) indices) | j <- [0 .. 255] ]

-- The χ² statistic against B(n, 1/256), exact over ℚ.
chiSquare :: [Int] -> Rational
chiSquare counts =
  sum [ d * d | c <- counts
      , let d = fromIntegral c - expected ] * 256 / fromIntegral n
  where n = sum counts
        expected = fromIntegral n / 256 :: Rational

-- Convenience: statistic straight from an index frame.
indexChiSquare :: [Int] -> Rational
indexChiSquare = chiSquare . usageHistogram
