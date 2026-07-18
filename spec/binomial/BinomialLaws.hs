-- ════════════════════════════════════════════════════════════════
-- BinomialLaws: the V1 objective, pinned (the binomial
-- approximation at 16×16 colors).
--
--   V1a conservation: the usage histogram sums to n
--   V1b the permutation anchor: the A2 identity frame (the seed
--       indexed against itself) has usage ≡ 1 and χ² = 0 — the
--       bijection rung's perfect score
--   V1c balance anchor: any perfectly balanced frame (n = 256·4^k,
--       each color n/256 times) has χ² = 0 at every rung size
--   V1d collapse blows up: a one-color frame scores χ² = 255·n —
--       the worst case, in closed form
--   V1e dyadic exactness: for our frame sizes χ² is a dyadic
--       rational (denominator a power of two) — f64 ports are
--       bit-exact, no tolerance needed
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Ratio (denominator)
import Boreal.Binomial

lcgIndices :: Int -> Int -> [Int]
lcgIndices seed n =
  [ fromIntegral ((s `div` 65536) `mod` 256)
  | s <- take n (iterate lcg (fromIntegral seed)) ]
  where lcg s = s * 6364136223846793005 + 1442695040888963407 :: Integer

-- V1a
lawConservation :: Bool
lawConservation =
  and [ sum (usageHistogram xs) == length xs
      | xs <- [ lcgIndices 3 256, lcgIndices 5 4096, replicate 100 7 ] ]

-- V1b
lawPermutationAnchor :: Bool
lawPermutationAnchor =
  usageHistogram identity == replicate 256 1
    && indexChiSquare identity == 0
  where identity = [0 .. 255]

-- V1c
lawBalanceAnchor :: Bool
lawBalanceAnchor =
  and [ indexChiSquare (concatMap (replicate k) [0 .. 255]) == 0
      | k <- [1, 4, 16, 256] ]          -- rungs 16, 32, 64, 256

-- V1d: all n pixels on one color →
--   χ² = [(n − n/256)² + 255(n/256)²]·256/n = 255·n
lawCollapseWorstCase :: Bool
lawCollapseWorstCase =
  and [ indexChiSquare (replicate n 0) == 255 * fromIntegral n
      | n <- [256, 4096, 65536] ]

-- V1e
lawDyadicExact :: Bool
lawDyadicExact =
  and [ isPow2 (denominator (indexChiSquare (lcgIndices s n)))
      | (s, n) <- [(3, 256), (5, 1024), (7, 4096), (9, 65536)] ]
  where isPow2 d = d == until (>= d) (* 2) 1   -- smallest 2^k ≥ d equals d

-- V1f — THE BEAUTY BAND (Daniel's criterion; FLAG_BEAUTY lineage):
--   beauty is FIT TO THE BINOMIAL, not uniformity. A fair random
--   assignment has E[chi^2] = 255 EXACTLY (BA3 proves it); equal
--   counts (chi^2 = 0) are sterile; concentration (device capture:
--   20205) is collapse. The target is the BAND around 255. The rate
--   price of beauty over perfection is chi^2/(2 ln 2) ~ 184 bits per
--   65536-px frame = 0.003 bits/px — beauty is almost free.
lawBeautyBand :: Bool
lawBeautyBand = fairInBand && sterileBelow && priceTiny
  where
    -- Genuine LCG-random assignments land in the band; flat and
    -- collapsed do not.
    band x = x > 150 && x < 400
    fairInBand =
      and [ band (fromRational (indexChiSquare (lcgIndices s 65536)))
          | s <- [3, 9, 21 :: Int] ]
    sterileBelow =
      not (band 0) && not (band (255 * 65536))
    priceTiny =
      (255 :: Double) / (2 * log 2) / 65536 < 0.003   -- bits/px

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " Binomial: the V1 objective — balanced 16×16 color usage"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("V1a usage histogram conserves n",                  lawConservation)
    , ("V1b A2 identity: usage ≡ 1, χ² = 0",              lawPermutationAnchor)
    , ("V1c balanced frames score 0 at every rung",        lawBalanceAnchor)
    , ("V1d collapse worst case = 255·n, closed form",     lawCollapseWorstCase)
    , ("V1e χ² is dyadic for our frame sizes (f64-exact)", lawDyadicExact)
    , ("V1f beauty band: fit the binomial, χ² ≈ 255 ± band", lawBeautyBand)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
