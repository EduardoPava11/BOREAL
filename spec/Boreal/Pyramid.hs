-- ════════════════════════════════════════════════════════════════
-- Boreal.Pyramid — the exact integer S-transform pyramid kernels.
--
-- PORT CONVENTIONS (normative, floor-division makes order matter):
--   · pair transform      l = ⌊(a+b)/2⌋ ,  h = a − b
--   · pair inverse        a = l + ⌊(h+1)/2⌋ ,  b = a − h
--   · quad order          HORIZONTAL pairs first, then vertical
--                         (quad (3,1,0,0): row-first 1, col-first 0)
--   · detail band order   coarse → fine; per quad (LH, HL, HH)
--   · LCG test images     s' = s·6364136223846793005
--                              + 1442695040888963407  (wrap i64)
--                         sample = ((s ÷ 65536) mod 4097) − 2048
--                         with FLOOR division and non-negative mod
-- ════════════════════════════════════════════════════════════════

module Boreal.Pyramid where

-- ── The exact integer S-transform ──────────────────────────────

st :: Int -> Int -> (Int, Int)
st a b = ((a + b) `div` 2, a - b)          -- div floors: exact on ℤ

stInv :: Int -> Int -> (Int, Int)
stInv l h = let a = l + ((h + 1) `div` 2) in (a, a - h)

-- 2×2 quad: rows first, then columns.  Returns (LL, LH, HL, HH).
quadF :: (Int, Int, Int, Int) -> (Int, Int, Int, Int)
quadF (a, b, c, d) =
  let (l0, h0) = st a b
      (l1, h1) = st c d
      (ll, lh) = st l0 l1
      (hl, hh) = st h0 h1
  in (ll, lh, hl, hh)

quadI :: (Int, Int, Int, Int) -> (Int, Int, Int, Int)
quadI (ll, lh, hl, hh) =
  let (l0, l1) = stInv ll lh
      (h0, h1) = stInv hl hh
      (a, b)   = stInv l0 h0
      (c, d)   = stInv l1 h1
  in (a, b, c, d)

-- ── One pyramid level over an image ([[Int]], rows) ────────────

type Image  = [[Int]]
type Detail = [[(Int, Int, Int)]]          -- (LH, HL, HH) per quad

chunk2 :: [a] -> [(a, a)]
chunk2 (x:y:rest) = (x, y) : chunk2 rest
chunk2 _          = []

analyzeOnce :: Image -> (Image, Detail)
analyzeOnce img =
  let quadRows = [ [ quadF (a, b, c, d)
                   | ((a, b), (c, d)) <- zip (chunk2 r0) (chunk2 r1) ]
                 | (r0, r1) <- chunk2 img ]
      coarse  = map (map (\(ll, _, _, _) -> ll)) quadRows
      details = map (map (\(_, lh, hl, hh) -> (lh, hl, hh))) quadRows
  in (coarse, details)

synthesizeOnce :: Image -> Detail -> Image
synthesizeOnce coarse details =
  concat [ unquadRow (zipWith merge cRow dRow)
         | (cRow, dRow) <- zip coarse details ]
  where merge ll (lh, hl, hh) = quadI (ll, lh, hl, hh)
        unquadRow quads =
          [ concat [ [a, b] | (a, b, _, _) <- quads ]
          , concat [ [c, d] | (_, _, c, d) <- quads ] ]

-- Full pyramid down to the base rung; details ordered coarse→fine.
analyzeTo :: Int -> Image -> (Image, [Detail])
analyzeTo base img
  | length img <= base = (img, [])
  | otherwise =
      let (coarse, d)    = analyzeOnce img
          (top, deeper)  = analyzeTo base coarse
      in (top, deeper ++ [d])

synthesizeFrom :: Image -> [Detail] -> Image
synthesizeFrom = foldl synthesizeOnce

-- Independent classic coarsening — the baseline "pick a color"
-- path, coded separately from quadF.  Row-first (normative).
coarsenOnce :: Image -> Image
coarsenOnce img =
  [ zipWith (\p q -> (p + q) `div` 2) h0 h1
  | (h0, h1) <- chunk2 hRows ]
  where hRows = [ [ (a + b) `div` 2 | (a, b) <- chunk2 row ]
                | row <- img ]

coarsenTo :: Int -> Image -> Image
coarsenTo base img
  | length img <= base = img
  | otherwise          = coarsenTo base (coarsenOnce img)

-- ── Deterministic pseudo-random images (LCG, no System.Random) ─

lcg :: Int -> Int
lcg s = s * 6364136223846793005 + 1442695040888963407

samples :: Int -> Int -> [Int]
samples seed n = take n (map toSample (iterate lcg seed))
  where toSample s = (s `div` 65536) `mod` 4097 - 2048   -- [-2048, 2048]

mkImage :: Int -> Int -> Image
mkImage seed side = chunk side (samples seed (side * side))
  where chunk _ [] = []
        chunk k xs = take k xs : chunk k (drop k xs)
