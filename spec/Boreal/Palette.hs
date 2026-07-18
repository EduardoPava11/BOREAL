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
