-- ════════════════════════════════════════════════════════════════
-- Boreal.Battle — the battle laws, with NATURE AS THE EVOLUTION.
--
-- H-JEPA level 1: the interpretation of Bayer-structured data.
-- Two algorithmic encoders of the same DNG contest in latent space:
--
--   coarse C (the 16×16 seed)  = the PRIOR — 256 options, each
--                                owning a home patch (H laws)
--   fine   F (the 256×256)     = the EVIDENCE
--
-- The battle is an ECOSYSTEM: options are species, pixels are
-- territory, usage counts are populations, and the dither walk's
-- grid-neighbor swaps (TG2: one axis, one step, ℓ1 = 1) are the
-- only legal moves. NATURE IS THE EVOLUTION:
--
--   · NEUTRALITY = BEAUTY: with no selection pressure (options
--     equally fit), territory assignment drifts multinomially —
--     E[c_p] = n/256, Var = n·p·(1−p), and E[χ²] = 255 EXACTLY
--     (the Pearson degrees of freedom). The V1f beauty band is
--     the stationary signature of neutral evolution.
--   · SELECTION = SIGNAL: deviation from neutrality is EARNED by
--     evidence — fine detail defeating the home prior. Sterile
--     flats (χ² = 0) are unnatural; collapse is a monoculture.
--   · The per-move cost is CLOSED-FORM: one pixel defecting from
--     option p to option q changes χ² by exactly 512·(c_q−c_p+1)/n
--     — so the walk can maintain the beauty metric incrementally
--     in O(1) per swap (evolution is cheap to simulate).
--
-- TIME (x, y, t): the GIF is multi-dimensional; the epoch axis
-- produces DELTAS between consecutive frames that must be
-- surfaced in the latents and the encoding. The delta primitive
-- is pinned here: churn = the defection list; applying a frame's
-- delta reproduces the next frame exactly (lossless round trip).
--
-- SCOPE: level 1 trains the structure ON L. Chroma (a,b) requires
-- a dedicated analysis — open item D7.
-- ════════════════════════════════════════════════════════════════

module Boreal.Battle where

import Boreal.Binomial (usageHistogram, chiSquare)

-- ── Territory and populations ──────────────────────────────────

-- Usage populations of an index frame (256 species).
populations :: [Int] -> [Int]
populations = usageHistogram

-- ── The per-move (defection) law ───────────────────────────────

-- Exact χ² change when ONE pixel defects from option p to q,
-- given current populations. Closed form: 512·(c_q − c_p + 1)/n.
swapDeltaChi2 :: [Int] -> Int -> Int -> Rational
swapDeltaChi2 counts p q
  | p == q    = 0
  | otherwise = 512 * (fromIntegral (counts !! q)
                        - fromIntegral (counts !! p) + 1)
                  / fromIntegral (sum counts)

-- Apply the defection to the populations.
defect :: [Int] -> Int -> Int -> [Int]
defect counts p q =
  [ c + d i | (i, c) <- zip [0 ..] counts ]
  where d i | i == p = -1 | i == q = 1 | otherwise = 0

-- ── Neutral evolution's moments (exact, ℚ) ─────────────────────

-- Under Multinomial(n, uniform over 256): E[χ²] = 255, exactly.
neutralExpectedChi2 :: Int -> Rational
neutralExpectedChi2 n =
  256 / fromIntegral n * 256 * variance
  where variance = fromIntegral n * (1 / 256) * (255 / 256)

-- ── The temporal delta primitive (x, y, t) ─────────────────────

-- The churn between consecutive frames: the defection list.
frameDelta :: [Int] -> [Int] -> [(Int, Int)]
frameDelta a b = [ (i, y) | (i, (x, y)) <- zip [0 ..] (zip a b), x /= y ]

applyDelta :: [Int] -> [(Int, Int)] -> [Int]
applyDelta a delta =
  [ maybe x id (lookup i delta) | (i, x) <- zip [0 ..] a ]

churn :: [Int] -> [Int] -> Int
churn a b = length (frameDelta a b)
