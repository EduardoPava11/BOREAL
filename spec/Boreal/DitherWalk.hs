-- ════════════════════════════════════════════════════════════════
-- Boreal.DitherWalk — the core mechanism, made constructive:
-- a macro 16×16 SEEDS the colors; the dithering WALKS to populate
-- the 256×256 GIF.
--
-- Instead of indexing every pixel by global argmin over all 256
-- colors (256 distance evaluations per pixel), the WALK visits
-- pixels in a fixed serpentine order and chooses each pixel's
-- color from the WINDOW of the palette grid around the pixel's
-- HOME cell (the patch it lives in, per the (16×16)×(16×16)
-- factorization), radius r:
--
--   candidates per pixel: (2r+1)² instead of 256
--   r = 2  →  25 evals  →  10.24× fewer than global argmin
--
-- and, crucially, the walk enforces the SOM law L1 BY
-- CONSTRUCTION: an emitted index can never be farther than r from
-- the pixel's home cell — home-centering stops being a hoped-for
-- property of the data and becomes a structural guarantee of the
-- procedure. Speed and lawfulness are the same design move.
--
-- The FS variant carries quantization error forward (Floyd-
-- Steinberg weights 7,3,5,1 /16) in EXACT Q16 integers with a
-- pinned remainder policy, so the walk is bit-deterministic:
--
--   shares = (w·e) div 16 (floor), remainder joins the 7/16
--   (east) share; borders drop out-of-frame shares.
--
-- Enumeration convention (normative): window cells row-major
-- (dv outer, du inner, ascending), STRICT-LESS argmin — so with
-- the full window (r = 15) the walk reproduces the global
-- ties-lowest argmin exactly (law DW5).
-- ════════════════════════════════════════════════════════════════

module Boreal.DitherWalk where

import Boreal.GifTarget (Q16Lab, dist2)

-- Serpentine visit order over an s×s frame (row 0 left→right,
-- row 1 right→left, …) — the walk's fixed path.
serpentine :: Int -> [(Int, Int)]
serpentine s =
  [ (y, if even y then x else s - 1 - x)
  | y <- [0 .. s - 1], x <- [0 .. s - 1] ]

-- A pixel's home cell in the palette grid: the patch it lives in.
homeCell :: Int -> (Int, Int) -> (Int, Int)
homeCell s (y, x) = (y * 16 `div` s, x * 16 `div` s)

-- Window argmin: candidates are the clamped (2r+1)² neighborhood of
-- home, enumerated row-major, strict-less (ties → first = lowest).
windowPick :: Int -> [Q16Lab] -> (Int, Int) -> Q16Lab -> Int
windowPick r palette (hv, hu) p = go candidates maxBound 0
  where
    clampG t = max 0 (min 15 t)
    candidates =
      [ v * 16 + u
      | dv <- [-r .. r], du <- [-r .. r]
      , let v = clampG (hv + dv), let u = clampG (hu + du) ]
    go [] _ best = best
    go (j : js) bestD best
      | d < bestD = go js d j
      | otherwise = go js bestD best
      where d = dist2 (palette !! j) p

-- ── The plain walk (no diffusion): seed + windows populate s² ──

ditherWalk :: Int -> [Q16Lab] -> [Q16Lab] -> [Int]
ditherWalk r palette target =
  [ windowPick r palette (homeCell s (y, x))
      (target !! (y * s + x))
  | (y, x) <- serpentine s ]
  where s = isqrt (length target)

-- Reorder a serpentine-emitted list back to row-major.
rowMajor :: Int -> [Int] -> [Int]
rowMajor s emitted =
  [ m !! (y * s + if even y then x else s - 1 - x)
  | y <- [0 .. s - 1], x <- [0 .. s - 1] ]
  where m = emitted

-- ── The FS walk: exact integer error diffusion ─────────────────

-- Split an error EXACTLY into FS shares (east 7, sw 3, s 5, se 1,
-- /16, floor); the remainder joins the east share. Sum is exact.
splitFS :: Int -> (Int, Int, Int, Int)
splitFS e = (e7 + rest, e3, e5, e1)
  where e7 = (7 * e) `div` 16
        e3 = (3 * e) `div` 16
        e5 = (5 * e) `div` 16
        e1 = (1 * e) `div` 16
        rest = e - (e7 + e3 + e5 + e1)

isqrt :: Int -> Int
isqrt n = head [ s | s <- [1 ..], s * s >= n ]
