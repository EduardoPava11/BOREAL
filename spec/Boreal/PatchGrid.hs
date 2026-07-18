-- ════════════════════════════════════════════════════════════════
-- Boreal.PatchGrid — the H in H-JEPA, literally:
--
--     (16×16) × (16×16)  =  256×256
--
-- The ceiling frame factorizes as a 16×16 OUTER grid of 16×16
-- INNER patches. Coordinates split exactly:
--
--     y = 16·v + j,   x = 16·u + i
--     outer (patch) = (v,u) — THE SEED'S OWN GRID
--     inner (pixel within patch) = (j,i)
--
-- So each seed cell is the coarse latent OF ITS OWN PATCH (A2,
-- squared), and the arithmetic closes the loop with the binomial
-- ideal: balanced usage at the ceiling gives every color exactly
-- n/256 = 256 pixels — ONE PATCH'S AREA. Balance and
-- home-centering meet at the same fixed point: patch p speaking
-- mostly color p. V1-H is the two-level JEPA over exactly this
-- factorization: predict the inner 16×16 from the cell (+context);
-- the deterministic up (nearest replication) maps level-0
-- perfection to level-1 perfection (law H4).
-- ════════════════════════════════════════════════════════════════

module Boreal.PatchGrid where

import Data.Ratio ((%))

side16, side256 :: Int
side16 = 16
side256 = 256

-- Linear ceiling index → ((v,u) outer, (j,i) inner), exactly.
factorIdx :: Int -> ((Int, Int), (Int, Int))
factorIdx idx = ((y `div` 16, x `div` 16), (y `mod` 16, x `mod` 16))
  where y = idx `div` side256
        x = idx `mod` side256

unfactorIdx :: ((Int, Int), (Int, Int)) -> Int
unfactorIdx ((v, u), (j, i)) = (16 * v + j) * side256 + (16 * u + i)

-- Ceiling frame (65536, row-major) → 256 patches of 256 pixels,
-- patch-major (p = v·16 + u), inner row-major (j·16 + i).
patches :: [a] -> [[a]]
patches frame =
  [ [ frame !! unfactorIdx ((v, u), (j, i))
    | j <- [0 .. 15], i <- [0 .. 15] ]
  | v <- [0 .. 15], u <- [0 .. 15] ]

assemblePatches :: [[a]] -> [a]
assemblePatches ps =
  [ ps !! (v * 16 + u) !! (j * 16 + i)
  | y <- [0 .. side256 - 1], x <- [0 .. side256 - 1]
  , let (v, j) = (y `div` 16, y `mod` 16)
  , let (u, i) = (x `div` 16, x `mod` 16) ]

-- The hierarchical statistic: mean over p of the share of patch
-- p's pixels that use color p. 1 = perfect H (every patch pure its
-- own color); the all-one-color collapse scores exactly 1/256.
homeShare :: [Int] -> Rational
homeShare frame =
  sum [ fromIntegral (length (filter (== p) patch)) % 256
      | (p, patch) <- zip [0 ..] (patches frame) ] / 256

-- The perfect-H ceiling: patch p filled with color p — which is
-- exactly the nearest-upscale of the A2 identity seed (law H4).
pureH :: [Int]
pureH = assemblePatches [ replicate 256 p | p <- [0 .. 255] ]
