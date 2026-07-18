-- ════════════════════════════════════════════════════════════════
-- Boreal.Entropy — the rate side of the Maximum Signal Compression
-- theorem: what an index stream can carry, and what imbalance
-- costs.
--
-- The 8-bit index stream has capacity 8 bits/pixel. It attains
-- capacity iff usage is BALANCED (χ² = 0 — the binomial ideal);
-- the bits lost to imbalance are, to second order, χ²/(2n·ln 2)
-- per frame — the χ² statistic V1 optimizes IS the rate penalty
-- in disguise.
-- ════════════════════════════════════════════════════════════════

module Boreal.Entropy where

-- Shannon entropy of the index stream, bits per index, from the
-- 256-count usage histogram. 0·log 0 = 0.
indexEntropyBits :: [Int] -> Double
indexEntropyBits counts =
  negate (sum [ p * logBase 2 p
              | c <- counts, c > 0
              , let p = fromIntegral c / n ])
  where n = fromIntegral (sum counts)

-- The second-order price of imbalance, bits per frame:
--   n·(8 − H)  ≈  χ² / (2·ln 2)
bitsLostSecondOrder :: Rational -> Double
bitsLostSecondOrder chi2 = fromRational chi2 / (2 * log 2)

-- Exact squared ΔE decomposition (the Pythagorean split that makes
-- chroma a separable cost once the bell fixes L).
deltaE2 :: (Rational, Rational, Rational) -> (Rational, Rational, Rational)
        -> Rational
deltaE2 (l1, a1, b1) (l2, a2, b2) =
  (l1 - l2) ^ two + (a1 - a2) ^ two + (b1 - b2) ^ two
  where two = 2 :: Int

chromaCost2 :: (Rational, Rational, Rational) -> (Rational, Rational, Rational)
            -> Rational
chromaCost2 (_, a1, b1) (_, a2, b2) =
  (a1 - a2) ^ two + (b1 - b2) ^ two
  where two = 2 :: Int
