-- ════════════════════════════════════════════════════════════════
-- Boreal.CycleSet — the 4-DNG set, mapped: what the network sees.
--
-- A cycle is FOUR DNG mosaics of one scene (the EV plan's frames:
-- green-ETTR, red-ETTR, blue-ETTR, shadow-floor — capture order).
-- The NN's input tensor is their PHASE DECOMPOSITION:
--
--   mosaic S² ──▶ 4 positional phase planes, each (S/2)²:
--     phase 0 = sites (even row, even col)
--     phase 1 = sites (even row, odd  col)
--     phase 2 = sites (odd  row, even col)
--     phase 3 = sites (odd  row, odd  col)
--
--   tensor = 4 frames × 4 phases = 16 channels × (S/2)²,
--   channel index c = 4·frame + phase (frame-major, normative).
--
-- Phases are POSITIONAL and CFA-agnostic (the bijection never
-- consults the CFA); their color MEANING is metadata:
--   RGGB: phase 0 = R, phases 1,2 = G, phase 3 = B
--   BGGR: phase 0 = B, phases 1,2 = G, phase 3 = R
--
-- Each frame is EV-normalized by ITS OWN e_t before decomposition
-- (exact affine — laws CQ6/EV4), so the tensor is scene-linear on
-- a common scale and the whole map is 1-homogeneous: exposure
-- equivariance of the network is inherited, not learned.
--
-- The keystone (law N3): the phase planes ARE the classic baseline
-- at the finest rung — cfaBin at k = 2 is exactly
--   R = phase-R plane, G = (phase-G₁ + phase-G₂)/2, B = phase-B
-- so the network's input already contains, verbatim, the k=2
-- "pick the colors" demosaic it must learn to beat.
--
-- Output contract (structural, re-checked here): the target is the
-- multi-scale residual stack (MS laws; Σ r'² coefficients per
-- channel) whose 256-entry seed prefix must be BELL-ADMISSIBLE
-- (B laws) — the H-JEPA's targets, end to end.
-- ════════════════════════════════════════════════════════════════

module Boreal.CycleSet where

import Boreal.Exposure (Mosaic)

-- ── Phase decomposition (positional, CFA-agnostic) ─────────────

type Plane = [[Rational]]

phasePlanes :: Mosaic -> [Plane]
phasePlanes m =
  [ [ [ m !! (2 * y + py) !! (2 * x + px)
      | x <- [0 .. half - 1] ]
    | y <- [0 .. half - 1] ]
  | (py, px) <- phaseOffsets ]
  where half = length m `div` 2

phaseOffsets :: [(Int, Int)]
phaseOffsets = [(0, 0), (0, 1), (1, 0), (1, 1)]

-- Exact inverse: interleave the 4 planes back into the mosaic.
assemble :: [Plane] -> Mosaic
assemble [p0, p1, p2, p3] =
  concat
    [ [ interleaveRow (p0 !! y) (p1 !! y)
      , interleaveRow (p2 !! y) (p3 !! y) ]
    | y <- [0 .. length p0 - 1] ]
  where interleaveRow a b = concat [ [av, bv] | (av, bv) <- zip a b ]
assemble _ = error "assemble: needs exactly 4 planes"

-- ── The cycle tensor ───────────────────────────────────────────

-- 4 EV-normalized mosaics → 16 channels (frame-major), each (S/2)².
cycleTensor :: [Mosaic] -> [Plane]
cycleTensor frames = concatMap phasePlanes frames

-- Channel index bookkeeping (normative).
channelIndex :: Int -> Int -> Int
channelIndex frame phase = 4 * frame + phase

-- CFA color meaning of a phase (metadata, not geometry).
--   0 = R, 1 = G, 2 = B
phaseColor :: Int -> Int -> Int
phaseColor cfa phase = case (cfa, phase) of
  (0, 0) -> 0                  -- RGGB: phase 0 is R
  (0, 3) -> 2                  -- RGGB: phase 3 is B
  (1, 0) -> 2                  -- BGGR: phase 0 is B
  (1, 3) -> 0                  -- BGGR: phase 3 is R
  _      -> 1                  -- the two off-diagonal phases are G
