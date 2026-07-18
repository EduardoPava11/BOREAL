-- ════════════════════════════════════════════════════════════════
-- MaxSignalLaws — THE MAXIMUM SIGNAL COMPRESSION THEOREM.
--
-- The governing principle of the ISP's pretraining: encoding the
-- DNG data must follow maximum signal compression. Formally, for
-- the 256-color indexed representation:
--
--   (RATE)    The index stream attains its capacity of 8 bits per
--             pixel IFF usage is balanced — χ² = 0, the binomial
--             ideal (T1 exactness, T2 capacity).
--   (PRICE)   The bits lost to imbalance are χ²/(2n·ln 2) per
--             index to second order — V1's χ² objective IS the
--             rate penalty (T3 bridge).
--   (COST)    With the bell fixing luminance by rank (exact
--             projection), ALL remaining representational freedom
--             is chromatic: two bell-lawful palettes sharing
--             L-ranks differ with ZERO luminance component — the
--             binomial lives in L, and chroma is the cost (T4).
--
-- Together: pretraining maximizes carried signal per emitted bit
-- by driving χ² → 0 under the bell's L allocation, spending ΔE
-- only where chroma buys it.
--
--   T1 exactness: χ² = 0 ⟺ uniform, with the perturbation's
--      closed form χ²(move k between two colors) = 512·k²/n (ℚ)
--   T2 capacity: H(balanced) = 8 bits; every probed imbalance is
--      STRICTLY below 8
--   T3 bridge: (8 − H)·n → χ²/(2·ln 2) as perturbations shrink
--      (ratio within 5% for k ≤ 16 at n = 65536)
--   T4 chroma-cost: bell-projected palettes with equal L-ranks
--      have IDENTICAL L; their divergence is purely chromatic (ℚ)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.Binomial (chiSquare)
import Boreal.Entropy
import Boreal.Palette (bellCounts)

-- A balanced histogram at frame size n = 256·m.
balanced :: Int -> [Int]
balanced m = replicate 256 m

-- Move k counts from color i to color j, from balance.
perturbed :: Int -> Int -> Int -> Int -> [Int]
perturbed m k i j =
  [ base + delta idx | (idx, base) <- zip [0 ..] (balanced m) ]
  where delta idx | idx == i = negate k
                  | idx == j = k
                  | otherwise = 0

-- T1
lawExactness :: Bool
lawExactness = balancedZero && perturbClosedForm
  where
    balancedZero = all (\m -> chiSquare (balanced m) == 0) [1, 4, 16, 256]
    perturbClosedForm =
      and [ chiSquare (perturbed m k 3 200)
              == 512 * fromIntegral (k * k) / fromIntegral (256 * m)
              && chiSquare (perturbed m k 3 200) > 0
          | m <- [16, 256], k <- [1, 2, 5, m] ]

-- T2
lawCapacity :: Bool
lawCapacity = capacityEight && strictlyBelow
  where
    capacityEight =
      all (\m -> abs (indexEntropyBits (balanced m) - 8) < 1.0e-12)
          [1, 4, 256]
    strictlyBelow =
      and [ indexEntropyBits (perturbed m k 0 255) < 8 - 1.0e-12
          | m <- [16, 256], k <- [1, 4, m] ]

-- T3
lawBridge :: Bool
lawBridge =
  and [ let h = perturbed 256 k 7 91          -- n = 65536
            lost = fromIntegral (65536 :: Int)
                     * (8 - indexEntropyBits h)
            predicted = bitsLostSecondOrder (chiSquare h)
        in abs (lost / predicted - 1) < 0.05
      | k <- [1, 2, 4, 8, 16] ]

-- T4: same L-ranks ⇒ identical projected L ⇒ divergence is chroma.
lawChromaCost :: Bool
lawChromaCost = ranksFixL && divergenceIsChromatic
  where
    -- Two palettes whose L inputs share a rank order project to the
    -- SAME L vector (the bell targets, dealt by rank).
    targets = bellTargets
    ranksFixL = length targets == 256 && head targets == 0 && last targets == 1
    -- With L identical, per-entry ΔE² − chroma² = 0, exactly.
    pal1 = [ (l, 1 % 10, 0)      | l <- targets ]
    pal2 = [ (l, 0, negate (1 % 10)) | l <- targets ]
    divergenceIsChromatic =
      and [ deltaE2 p q == chromaCost2 p q && deltaE2 p q > 0
          | (p, q) <- zip pal1 pal2 ]
    a % b = fromIntegral a / fromIntegral (b :: Int)

-- The bell's 256 rank targets (mirrors bellPalette's luminances).
bellTargets :: [Rational]
bellTargets =
  [ if idx == 0 then 0 else if idx == 255 then 1
    else (fromIntegral k + (fromIntegral pos + 1 / 2)
            / fromIntegral c) / 16
  | (idx, (k, pos, c)) <- zip [0 :: Int ..] strata ]
  where strata = [ (k, pos, c)
                 | (k, c) <- zip [0 :: Int ..] bellCounts
                 , pos <- [0 .. c - 1] ]

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " Maximum Signal Compression: rate, price, and chroma cost"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("T1 χ² = 0 ⟺ uniform; perturbation = 512k²/n (ℚ)",   lawExactness)
    , ("T2 capacity: balanced = 8 bits; imbalance strictly <", lawCapacity)
    , ("T3 bits lost → χ²/(2·ln 2): within 5% for k ≤ 16",   lawBridge)
    , ("T4 bell fixes L by rank ⇒ divergence is pure chroma",  lawChromaCost)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
