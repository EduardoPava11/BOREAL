-- ════════════════════════════════════════════════════════════════
-- Boreal.TessGrid — R,G,B,T IS A THEOREM: the 4⁴ tesseract on the
-- 16×16 grid, with the literature-validated flattening.
--
--   4⁴ = 256 = 16².  R1 ⊕ R3 = R4 (Tesseract lineage: the palette
--   encodes not just WHAT COLOR but WHEN IT APPEARS; the epoch
--   axis T ∈ {0..3} is fed by the batch's 4 frames).
--
-- THE FLATTENING (validated 2026-07-17 against the index-assignment
-- and space-filling-curve literature): Gray-coded boustrophedon
-- axis-pairing —
--
--   x = 4·R + (G if R even, else 3−G)      (the (R,G) snake)
--   y = 4·B + (T if B even, else 3−T)      (the (B,T) snake)
--
-- WHY (the validation, not taste):
--   · SWAP DIRECTION — PROVABLY OPTIMAL: every 2D grid edge is
--     exactly ONE unit step along exactly ONE of R,G,B,T (ℓ1 = 1;
--     no bijection can do better — distinct coords force ℓ1 ≥ 1).
--     This is the quaternary reflected Gray code property [Z4 Gray
--     map / Lee-metric isometry, Hammons-Kumar-Calderbank-Sloane-
--     Solé], and matches the index-assignment doctrine that
--     STRUCTURED assignments are optimal for uniform product
--     codebooks [McLaughlin-Neuhoff-Ashley 1995; Knagenhjelm-
--     Agrell 1996; Zeger-Gersho 1990 pseudo-Gray = the problem's
--     name]. The dither walk swaps only grid neighbors, so this
--     bound IS the walk's per-swap perceptual cost.
--   · REVERSE DIRECTION: a 4D unit step stretches to grid
--     distance at most 7 (R/B steps: 7−2G ∈ {1,3,5,7}; G/T steps:
--     exactly 1) — within ~2× of the isoperimetric floor (~3) any
--     bijection must pay. Lexicographic pairing would cap this at
--     4 but break the swap direction (block-boundary swaps cost
--     ℓ1 = 4) — worse where it matters.
--   · Double space-filling curves REJECTED: Gotsman-Lindenbaum's
--     converse bound makes the swap-direction worst case
--     unbounded — fatal for the walk.
--
-- Open reconciliation (D6): the bell governs the L allocation of
-- the COLORS placed on this lattice; the tesseract governs the
-- lattice's MEANING. Unifying bell strata with RGBT coordinates is
-- the next design decision, after the battle laws.
-- ════════════════════════════════════════════════════════════════

module Boreal.TessGrid where

-- A tesseract coordinate: (r, g, b, t), each in {0..3}.
type Tess = (Int, Int, Int, Int)

allTess :: [Tess]
allTess = [ (r, g, b, t)
          | r <- [0 .. 3], g <- [0 .. 3], b <- [0 .. 3], t <- [0 .. 3] ]

-- The reflected (snake) digit: identity on even majors, flipped on odd.
snakeDigit :: Int -> Int -> Int
snakeDigit major minor = if even major then minor else 3 - minor

-- Tesseract → grid (y, x), the validated flattening.
toGrid :: Tess -> (Int, Int)
toGrid (r, g, b, t) = (4 * b + snakeDigit b t, 4 * r + snakeDigit r g)

-- Grid → tesseract (exact inverse; snakeDigit is an involution).
fromGrid :: (Int, Int) -> Tess
fromGrid (y, x) = (r, snakeDigit r gRaw, b, snakeDigit b tRaw)
  where (r, gRaw) = x `divMod` 4
        (b, tRaw) = y `divMod` 4

-- Linear palette index of a tesseract point (row-major grid).
tessIndex :: Tess -> Int
tessIndex p = let (y, x) = toGrid p in y * 16 + x

-- ℓ1 (Lee-free, plain Manhattan) distance in the tesseract.
tessL1 :: Tess -> Tess -> Int
tessL1 (r1, g1, b1, t1) (r2, g2, b2, t2) =
  abs (r1 - r2) + abs (g1 - g2) + abs (b1 - b2) + abs (t1 - t2)

-- The epoch (T) of a palette index — the batch-frame stratum.
epochOf :: Int -> Int
epochOf i = let (_, _, _, t) = fromGrid (i `div` 16, i `mod` 16) in t
