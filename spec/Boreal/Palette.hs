-- ════════════════════════════════════════════════════════════════
-- Boreal.Palette — the 16×16 SOM seed palette over OKLab.
-- Lab/ΔE/conversions live in Boreal.ColorPath (single home, owned
-- deterministic cbrt); re-exported here for the law files.
--
-- Ordering convention (normative): palette index = v·16 + u,
-- u = column = hue, v = row = lightness stratum.
-- ════════════════════════════════════════════════════════════════

module Boreal.Palette
  ( Lab (..)
  , deltaE
  , oklabFromLinearSRGB
  , Cell
  , cellsAll
  , seedChroma
  , palette
  , kNeighbor
  , bellCounts
  , bellStratum
  , bellPalette
  ) where

import Boreal.ColorPath (Lab (..), deltaE, oklabFromLinearSRGB)
import Boreal.Geometry (gridSide)

type Cell = (Int, Int)                     -- (u = col = hue, v = row = L)

cellsAll :: [Cell]
cellsAll = [ (u, v) | v <- [0 .. gridSide - 1], u <- [0 .. gridSide - 1] ]

seedChroma :: Double
seedChroma = 0.10

-- Seed: rows are lightness strata, columns walk hue at fixed
-- chroma.  Smooth by construction; the SOM/NN refines from here.
palette :: Cell -> Lab
palette (u, v) = Lab lightness (seedChroma * cos theta) (seedChroma * sin theta)
  where lightness = 0.15 + 0.7 * fromIntegral v / fromIntegral (gridSide - 1)
        theta     = 2 * pi * fromIntegral u / fromIntegral gridSide

kNeighbor :: Double                        -- the L2 Lipschitz bound
kNeighbor = 0.06

-- ── The bell luminance allocation ──────────────────────────────
--
-- The 256 palette colors are NOT spread evenly over luminance: by
-- the 256² ceiling the palette's L allocation must follow the bell
-- over 16 luminance strata (mid-tones, where the eye lives, get 64
-- colors apiece; the extremes get exactly ONE, pinned to exact
-- black and exact white).  This is the NN's training constraint:
-- the learned seed is lawful only if its L histogram is the bell.
--
-- Open decision D5 (BOREAL-GIF-ISP-WORKFLOW.md): the bell's sparse
-- extremes are ISOLATED colors by construction, so the uniform
-- seed's flat neighbor-Lipschitz bound cannot hold verbatim on a
-- bell-distributed grid — L2 must become stratum-aware when the
-- bell seed replaces the uniform seed as the SOM reference.

bellCounts :: [Int]
bellCounts = [1, 1, 2, 4, 8, 16, 32, 64, 64, 32, 16, 8, 4, 2, 1, 1]

-- index 0..255 → (stratum k, position within stratum, stratum count)
bellStratum :: Int -> (Int, Int, Int)
bellStratum i = go 0 0 bellCounts
  where
    go k start (c : cs)
      | i < start + c = (k, i - start, c)
      | otherwise     = go (k + 1) (start + c) cs
    go k start []     = (k, i - start, 1)

-- The bell-allocated seed: stratum k owns the luminance band
-- [k/16, (k+1)/16); centroids sit at band positions; hue walks
-- within a stratum; sparse strata (count < 4) are near-neutral;
-- the two ends are EXACT black and EXACT white.
bellPalette :: Int -> Lab
bellPalette 0   = Lab 0 0 0
bellPalette 255 = Lab 1 0 0
bellPalette i   = Lab lum (chroma * cos theta) (chroma * sin theta)
  where
    (k, pos, cnt) = bellStratum i
    lum    = (fromIntegral k + (fromIntegral pos + 0.5) / fromIntegral cnt) / 16
    theta  = 2 * pi * fromIntegral pos / fromIntegral cnt
    chroma = if cnt < 4 then 0 else seedChroma
