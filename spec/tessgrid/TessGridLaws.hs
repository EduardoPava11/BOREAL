-- ════════════════════════════════════════════════════════════════
-- TessGridLaws: R,G,B,T as theorem, on the grid.
--
--   TG1 the theorem's arithmetic + the flattening is a BIJECTION
--       {0..3}⁴ ⇄ 16×16 (fromGrid ∘ toGrid = id, both ways)
--   TG2 SWAP OPTIMALITY (the walk's bound): every one of the 480
--       grid edges is exactly ONE unit step along exactly ONE
--       tesseract axis — ℓ1 = 1, the provable floor
--   TG3 reverse stretch: a 4D unit step maps to grid Manhattan
--       distance ≤ 7 exactly (max attained; G/T steps always 1)
--   TG4 epoch strata: each T value owns exactly 64 grid cells —
--       the batch's 4 frames slice the palette into 4 equal
--       strata (the WHEN axis is real and balanced)
--   TG5 the tower: 4⁴ = 16², 4⁶ = 64², 4⁸ = 256² — each squaring
--       adds one 4×4 tessellation (the recursion's floors; 64×64
--       is the canonical middle)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.TessGrid

-- TG1
lawBijection :: Bool
lawBijection =
  all (\p -> fromGrid (toGrid p) == p) allTess
    && length (map toGrid allTess) == 256
    && all (\(y, x) -> toGrid (fromGrid (y, x)) == (y, x)) grid
  where grid = [ (y, x) | y <- [0 .. 15], x <- [0 .. 15] ]

-- TG2
lawSwapOptimal :: Bool
lawSwapOptimal =
  all ((== 1) . edgeL1) hEdges && all ((== 1) . edgeL1) vEdges
    && length hEdges + length vEdges == 480
  where
    hEdges = [ ((y, x), (y, x + 1)) | y <- [0 .. 15], x <- [0 .. 14] ]
    vEdges = [ ((y, x), (y + 1, x)) | y <- [0 .. 14], x <- [0 .. 15] ]
    edgeL1 (a, b) = tessL1 (fromGrid a) (fromGrid b)

-- TG3
lawReverseStretch :: Bool
lawReverseStretch =
  maximum stretches == 7
    && all (\(p, q) -> gridDist p q >= 1) unitPairs
    && all (\(p, q) -> isGT p q || gridDist p q <= 7) unitPairs
    && all (\(p, q) -> not (isGT p q) || gridDist p q == 1) unitPairs
  where
    unitPairs = [ (p, q) | p <- allTess, q <- allTess, tessL1 p q == 1 ]
    stretches = [ gridDist p q | (p, q) <- unitPairs ]
    gridDist p q =
      let (y1, x1) = toGrid p; (y2, x2) = toGrid q
      in abs (y1 - y2) + abs (x1 - x2)
    -- a G or T step (the snaked minors) — always grid distance 1
    isGT (r1, g1, b1, t1) (r2, g2, b2, t2) =
      (r1 == r2 && b1 == b2 && t1 == t2 && g1 /= g2)
        || (r1 == r2 && g1 == g2 && b1 == b2 && t1 /= t2)

-- TG4
lawEpochStrata :: Bool
lawEpochStrata =
  all (\t -> length (filter ((== t) . epochOf) [0 .. 255]) == 64) [0 .. 3]

-- TG5
lawTower :: Bool
lawTower =
  4 ^ (4 :: Int) == 16 * 16
    && 4 ^ (6 :: Int) == 64 * 64
    && 4 ^ (8 :: Int) == 256 * 256
    && 64 * 64 == (16 * 16) * 16          -- each step: one 4×4 tessellation

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " TessGrid: R,G,B,T on the 16×16 — validated flattening"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("TG1 tesseract ⇄ grid is a bijection",                lawBijection)
    , ("TG2 every grid edge = ONE axis, ONE step (ℓ1 = 1)",  lawSwapOptimal)
    , ("TG3 reverse stretch ≤ 7 (max attained; G/T = 1)",     lawReverseStretch)
    , ("TG4 epoch strata: each frame owns exactly 64 cells",  lawEpochStrata)
    , ("TG5 the tower: 4⁴/4⁶/4⁸ = 16²/64²/256²",             lawTower)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
