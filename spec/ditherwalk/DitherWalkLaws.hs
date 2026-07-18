-- ════════════════════════════════════════════════════════════════
-- DitherWalkLaws: formal verification of the core mechanism —
-- the macro 16×16 seeds colors; the dithering walks to populate
-- the GIF frame.
--
--   DW1 totality: the walk assigns every pixel exactly once, all
--       indices in range — a fixed serpentine path, pure and
--       deterministic
--   DW2 exact diffusion arithmetic: the FS split conserves the
--       error EXACTLY in integers (shares sum to e, each within 1
--       of its ideal weight) — bit-determinism of the dither
--   DW3 locality ⇒ L1 BY CONSTRUCTION: every emitted index lies
--       within Chebyshev r of the pixel's home cell — the SOM's
--       home-centering law becomes a structural guarantee
--   DW4 the seed anchor: on the upscaled seed itself, the walk
--       reproduces pure-H exactly (every patch its own color)
--   DW5 consistency: with the full window (r = 15) the walk IS
--       the global ties-lowest argmin — the fast path degrades
--       gracefully into the exact one
--   DW6 the speed law: r = 2 costs 25 evaluations per pixel vs
--       256 — 10.24× fewer, closed form
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.ColorPath (quantizeLab)
import Boreal.DitherWalk
import Boreal.GifTarget (Q16Lab, indexMap)
import Boreal.Palette (bellPalette)

palette :: [Q16Lab]
palette = [ quantizeLab (bellPalette i) | i <- [0 .. 255] ]

-- Upscale the palette itself to an s² target (the pure-H scene).
seedTarget :: Int -> [Q16Lab]
seedTarget s =
  [ palette !! (v * 16 + u)
  | y <- [0 .. s - 1], x <- [0 .. s - 1]
  , let v = y * 16 `div` s, let u = x * 16 `div` s ]

-- LCG-jittered target around the seed (a "real" scene stand-in).
jitterTarget :: Int -> Int -> [Q16Lab]
jitterTarget seed s = go (map j (iterate lcg (fromIntegral seed))) (seedTarget s)
  where
    lcg n = n * 6364136223846793005 + 1442695040888963407 :: Integer
    j n = fromIntegral ((n `div` 65536) `mod` 4001 - 2000)
    go (dl : da : db : rest) ((l, a, b) : ps) =
      (l + dl, a + da, b + db) : go rest ps
    go _ [] = []
    go _ ps = ps

-- DW1
lawTotality :: Bool
lawTotality =
  length out == 32 * 32 && all (\i -> i >= 0 && i < 256) out
  where out = ditherWalk 2 palette (jitterTarget 5 32)

-- DW2
lawExactDiffusion :: Bool
lawExactDiffusion =
  and [ let (e7, e3, e5, e1) = splitFS e
        in e7 + e3 + e5 + e1 == e
             && abs (e3 * 16 - 3 * e) <= 16
             && abs (e5 * 16 - 5 * e) <= 16
             && abs (e1 * 16 - 1 * e) <= 16
      | e <- [-70000, -12345, -16, -1, 0, 1, 7, 16, 12345, 65536] ]

-- DW3
lawLocalityIsL1 :: Bool
lawLocalityIsL1 =
  and [ let (hv, hu) = homeCell 32 (y, x)
            j = row !! (y * 32 + x)
        in max (abs (j `div` 16 - hv)) (abs (j `mod` 16 - hu)) <= 2
      | y <- [0 .. 31], x <- [0 .. 31] ]
  where row = rowMajor 32 (ditherWalk 2 palette (jitterTarget 9 32))

-- DW4
lawSeedAnchor :: Bool
lawSeedAnchor =
  and [ rowMajor 32 (ditherWalk r palette (seedTarget 32)) == pure32
      | r <- [0, 1, 2] ]
  where pure32 = [ (y * 16 `div` 32) * 16 + x * 16 `div` 32
                 | y <- [0 .. 31], x <- [0 .. 31] ]

-- DW5
lawFullWindowIsArgmin :: Bool
lawFullWindowIsArgmin =
  rowMajor 16 (ditherWalk 15 palette tgt) == indexMap palette tgt
  where tgt = jitterTarget 13 16

-- DW6
lawSpeed :: Bool
lawSpeed =
  (2 * 2 + 1) ^ (2 :: Int) == 25
    && (256 :: Rational) / 25 > 10
    && 256 `div` 25 == (10 :: Int)

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " DitherWalk: seed 16×16, walk the dither, populate 256×256"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("DW1 totality: every pixel assigned, in range",        lawTotality)
    , ("DW2 FS split conserves error EXACTLY (integers)",     lawExactDiffusion)
    , ("DW3 locality ⇒ L1 by construction (Chebyshev ≤ r)",  lawLocalityIsL1)
    , ("DW4 on the seed itself the walk IS pure-H",           lawSeedAnchor)
    , ("DW5 full window == global ties-lowest argmin",        lawFullWindowIsArgmin)
    , ("DW6 r=2: 25 vs 256 evals — 10.24× fewer, closed form", lawSpeed)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
