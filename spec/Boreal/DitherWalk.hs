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

-- ── The FS WALK LOOP (P1, 2026-07-19): the full carry-buffer,
-- serpentine, windowed, error-diffusing walk — THE product decode.
--
-- Conventions (normative):
--   * carry buffer: one Q16 Int per channel per pixel, starts 0;
--     corrected pixel = target + carry, NEVER clamped (Q16 ints).
--   * pick: windowPick r on the CORRECTED value (strict-less,
--     row-major window — DW5's enumeration).
--   * error e = corrected − palette[pick], per channel; split by
--     splitFS (DW2's exact shares, remainder → east).
--   * neighbors in WALK order: on even (left→right) rows east =
--     (y, x+1), sw = (y+1, x−1), s = (y+1, x), se = (y+1, x+1);
--     on odd (right→left) rows the kernel MIRRORS horizontally:
--     east = (y, x−1), sw = (y+1, x+1), s = (y+1, x),
--     se = (y+1, x−1). Shares landing outside the frame are
--     DROPPED (and accounted — DW8).
--   * emission is serpentine; fsWalk returns ROW-MAJOR indices
--     (rowMajor applied), plus the per-channel dropped-share sums.

fsNeighbors :: Int -> (Int, Int) -> [(Int, Int)]
fsNeighbors s (y, x)
  | even y    = [(y, x + 1), (y + 1, x - 1), (y + 1, x), (y + 1, x + 1)]
  | otherwise = [(y, x - 1), (y + 1, x + 1), (y + 1, x), (y + 1, x - 1)]
  where _ = s

inFrame :: Int -> (Int, Int) -> Bool
inFrame s (y, x) = y >= 0 && y < s && x >= 0 && x < s

-- One channel's walk state: carries indexed row-major.
type Carry = [Int]

fsWalk :: Int -> [Q16Lab] -> [Q16Lab] -> ([Int], (Int, Int, Int))
fsWalk r palette target = (rowMajorAt s emitted, dropped)
  where
    s = isqrt (length target)
    zeroC = replicate (s * s) 0
    (emitted, dropped) = go (serpentine s) zeroC zeroC zeroC (0, 0, 0) []
    go [] _ _ _ dr acc = (reverse acc, dr)
    go ((y, x) : rest) cL ca cb (dL, da, db) acc =
      let i = y * s + x
          (tL, tA, tB) = target !! i
          corr = (tL + cL !! i, tA + ca !! i, tB + cb !! i)
          pick = windowPick r palette (homeCell s (y, x)) corr
          (pL, pA, pB) = palette !! pick
          eL = (\(a, _, _) -> a) corr - pL
          eA = (\(_, a, _) -> a) corr - pA
          eB = (\(_, _, a) -> a) corr - pB
          ns = fsNeighbors s (y, x)
          distr e c = foldl step (c, 0) (zip ns (tuple4 (splitFS e)))
            where step (cc, dd) (p2, share)
                    | inFrame s p2 =
                        (bump cc (fst p2 * s + snd p2) share, dd)
                    | otherwise = (cc, dd + share)
          (cL', dL') = distr eL cL
          (ca', da') = distr eA ca
          (cb', db') = distr eB cb
      in go rest cL' ca' cb' (dL + dL', da + da', db + db') (pick : acc)
    bump c j v = take j c ++ [c !! j + v] ++ drop (j + 1) c
    tuple4 (a, b, c, d) = [a, b, c, d]

-- Serpentine-emitted list back to row-major, at a known side.
rowMajorAt :: Int -> [Int] -> [Int]
rowMajorAt s emitted =
  [ pos !! (y * s + x) | y <- [0 .. s - 1], x <- [0 .. s - 1] ]
  where
    pos = [ v | (_, v) <- orderAsc ]
    orderAsc =
      walkSortOn fst (zip [ y * s + if even y then x else s - 1 - x
                      | (y, x) <- [ (yy, xx) | yy <- [0 .. s - 1]
                                             , xx <- [0 .. s - 1] ] ]
                      emitted)

walkSortOn :: Ord b => (a -> b) -> [a] -> [a]
walkSortOn f = foldr ins []
  where ins x [] = [x]
        ins x (y : ys) | f x <= f y = x : y : ys
                       | otherwise  = y : ins x ys

isqrt :: Int -> Int
isqrt n = head [ s | s <- [1 ..], s * s >= n ]

-- ── Shared scene builders (law file AND emitter import these) ──

-- Upscale a 256-entry palette to an s² pure-H target.
seedTargetFor :: [Q16Lab] -> Int -> [Q16Lab]
seedTargetFor pal s =
  [ pal !! (v * 16 + u)
  | y <- [0 .. s - 1], x <- [0 .. s - 1]
  , let v = y * 16 `div` s, let u = x * 16 `div` s ]

-- LCG-jittered target around the seed (a "real" scene stand-in).
-- Convention (normative): s' = s*6364136223846793005 +
-- 1442695040888963407 over unbounded Integer; per channel delta =
-- (s' div 65536) mod 4001 − 2000; three draws per pixel L,a,b.
jitterTargetFor :: [Q16Lab] -> Int -> Int -> [Q16Lab]
jitterTargetFor pal seed s =
  go (map j (iterate lcg (fromIntegral seed))) (seedTargetFor pal s)
  where
    lcg n = n * 6364136223846793005 + 1442695040888963407 :: Integer
    j n = fromIntegral ((n `div` 65536) `mod` 4001 - 2000)
    go (dl : da : db : rest) ((l, a, b) : ps) =
      (l + dl, a + da, b + db) : go rest ps
    go _ [] = []
    go _ ps = ps
