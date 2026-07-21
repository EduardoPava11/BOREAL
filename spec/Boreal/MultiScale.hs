-- ════════════════════════════════════════════════════════════════
-- Boreal.MultiScale — the custom ISP: demosaic at EVERY scale.
--
-- Each rung r ∈ {16,32,64,128,256} is its OWN demosaic of the
-- mosaic — the CFA-aware per-channel mean at that rung's cell size
-- (k = side/r), then color matrix, then OKLab Q16.  A rung is NOT
-- a resize of a finer rung; that independence is the custom-ISP
-- identity and, later, the H-JEPA's room to learn.
--
-- The latent record is a RESIDUAL STACK between the scales:
--
--   [ rung16 | rung32 − up(rung16) | rung64 − up(rung32) | … ]
--
-- with up = exact 2×2 nearest-neighbor replication.  Prefix
-- through level r decodes to EXACTLY the rung-r demosaic (MS3).
-- The stack is deliberately overcomplete (Σ r² ≈ 1.33·ceiling²):
-- every residual value is a JEPA prediction target.
--
-- Two structural truths the laws pin:
--   · LINEAR nesting is EXACT (ℚ): a parent cell's per-channel
--     mean equals the mean of its four children — cfaBin telescopes.
--   · OKLab nesting is NOT exact: cbrt's Jensen gap makes the
--     residual DC nonzero even on the classic path.  That gap is
--     bounded (MS4), not zero — by design.
--
-- Conventions: normalized mosaic in [0,1) (dyadic in fixtures so
-- f64/f32 are exact); RGGB/BGGR as in cfaBin; rung cell k must be
-- even (k ≥ 2 keeps 1R+2G+1B per cell); f64 color path via
-- Boreal.ColorPath (owned cbrt — bit-exact everywhere).
-- ════════════════════════════════════════════════════════════════

module Boreal.MultiScale where

import Data.Ratio ((%))
import Boreal.ColorPath (Lab (..), M3, apply3, oklabFromProPhotoLinear,
                         quantizeLab)
import Boreal.Exposure (CellRGB (..), Mosaic, cfaBin)

-- ── Rungs available for a given mosaic side ─────────────────────

-- 512 added 2026-07-19 (E1-extension verdict: k=4 box means stay
-- sub-JND on real scenes, mean ΔE 0.0020/p95 0.0066 vs the HA
-- reference; k=2 rejected at p95 0.0119 — see
-- BOREAL-DEBAYER-MATH-RESEARCH.md). 512 is the RENDER ceiling (the
-- GIF frame); 256 remains the MODEL ceiling (H2/N0/bell domain,
-- gridSide² — Boreal.Geometry.ceilingRung).
allRungs :: [Int]
allRungs = [16, 32, 64, 128, 256, 512]

rungsFor :: Int -> [Int]
rungsFor side =
  [ r | r <- allRungs
      , side `mod` r == 0
      , let k = side `div` r
      , k >= 2, even k ]

-- ── Per-rung classic demosaic: cfaBin → color → OKLab Q16 ──────

-- One rung's linear camera RGB (exact ℚ; k = side/r).
rungLinear :: Int -> Int -> Mosaic -> [[CellRGB]]
rungLinear side r = cfaBin (side `div` r)

-- One rung's Q16 OKLab planes (L, a, b), row-major.  `m` is the
-- camera→ProPhoto matrix (identity when the DNG carried no color).
rungQ16 :: M3 -> Int -> Int -> Mosaic -> ([Int], [Int], [Int])
rungQ16 m side r mosaic = unzip3
  [ quantizeLab (oklabFromProPhotoLinear (apply3 m (f rr, f gg, f bb)))
  | row <- rungLinear side r mosaic
  , CellRGB rr gg bb <- row ]
  where f = fromRational

-- All rungs for a mosaic, coarse → fine.
rungStack :: M3 -> Int -> Mosaic -> [(Int, ([Int], [Int], [Int]))]
rungStack m side mosaic =
  [ (r, rungQ16 m side r mosaic) | r <- rungsFor side ]

-- ── The residual stack (per channel) ───────────────────────────

-- Exact 2×2 nearest-neighbor replication of a flat r² plane.
upsample2 :: Int -> [Int] -> [Int]
upsample2 r img =
  concat [ dup row ++ dup row | row <- chunk r img ]
  where dup = concatMap (\v -> [v, v])
        chunk _ [] = []
        chunk n xs = take n xs : chunk n (drop n xs)

-- Encode: rung planes (coarse → fine, sides doubling) → the stack.
encodeMS :: [(Int, [Int])] -> [Int]
encodeMS []                 = []
encodeMS ((r0, base) : fs)  = base ++ go r0 base fs
  where
    go _ _ [] = []
    go rPrev prev ((r, img) : rest)
      | r == 2 * rPrev =
          let up = upsample2 rPrev prev
          in zipWith (-) img up ++ go r img rest
      | otherwise = error "encodeMS: rungs must double"

-- Cumulative prefix length through rung r (the layout closed form).
prefixLen :: [Int] -> Int -> Int
prefixLen rungs r = sum [ r' * r' | r' <- rungs, r' <= r ]

-- Decode the prefix through rung r back to that rung's plane.
decodeRung :: [Int] -> [Int] -> Int -> [Int]
decodeRung rungs bands r = go (head rungs) baseTaken rest
  where
    base      = head rungs
    baseTaken = take (base * base) bands
    rest      = drop (base * base) bands
    go rCur img remaining
      | rCur == r = img
      | otherwise =
          let rNext = 2 * rCur
              n     = rNext * rNext
              det   = take n remaining
              up    = upsample2 rCur img
          in go rNext (zipWith (+) up det) (drop n remaining)

-- ── Deterministic normalized dyadic test mosaics ───────────────

lcgQ16 :: Integer -> Integer
lcgQ16 s = s * 6364136223846793005 + 1442695040888963407

mkMosaicUnit :: Integer -> Int -> Mosaic
mkMosaicUnit seed side =
  chunk side [ (v `mod` 16384) % 16384 | v <- take (side * side) vals ]
  where vals = map (abs . (`div` 65536)) (iterate lcgQ16 seed)
        chunk _ [] = []
        chunk n xs = take n xs : chunk n (drop n xs)
