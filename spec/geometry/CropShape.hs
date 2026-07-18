-- ════════════════════════════════════════════════════════════════
-- CropShape: Bayer geometry for the 64-burst → 16×16 latent
--
-- The sensor readout is 4224×3024 (12MP quad-binned, RGGB).
-- The canonical crop side is the LARGEST S = 256·2^j that fits
-- the short sensor side: S = 2048 (j = 3).  Everything downstream
-- is dyadic: the quad grid is 1024², a 16×16 latent cell spans
-- 128 photosites = 64 quads, and every ladder rung
-- {16,32,64,128,256} divides the crop side with quad alignment.
--
-- Burst structure: 64 frames = 16 EV cycles × 4 frames.  One NN
-- inference per cycle ⇒ the burst yields 16 latent frames of
-- 16×16×4.  Constants live in Boreal.Geometry (single source).
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Boreal.Geometry

-- ── Laws ───────────────────────────────────────────────────────

-- CS1: canonical side is the LARGEST 256·2^j fitting the sensor.
lawCanonicalSide :: Bool
lawCanonicalSide =
  canonicalSide == 256 * 2 ^ (3 :: Int)
    && canonicalSide <= minSide
    && 256 * 2 ^ (4 :: Int) > minSide
  where minSide = min sensorW sensorH

-- CS2: the ladder is the full dyadic run from the 16² base to the
--      256² ceiling; every rung divides the crop side with
--      whole-quad alignment (an even photosite span).
lawDyadicRungs :: Bool
lawDyadicRungs =
  rungs == takeWhile (<= ceilingRung) (iterate (* 2) gridSide)
    && length rungs == 5
    && and [ isPow2 r | r <- rungs ]
    && and [ canonicalSide `mod` r == 0 | r <- rungs ]
    && and [ even (canonicalSide `div` r) | r <- rungs ]
  where isPow2 n = n > 0 && n .&. (n - 1) == 0

-- CS3: per-cell per-frame sample accounting, exact conservation.
lawSampleAccounting :: Bool
lawSampleAccounting =
  rSamples == 4096
    && gSamples == 8192
    && bSamples == 4096
    && rSamples + gSamples + bSamples == cellSide * cellSide
    && gridSide * gridSide * cellSide * cellSide
         == canonicalSide * canonicalSide
  where rSamples = quadsPerCellSide * quadsPerCellSide
        gSamples = 2 * rSamples
        bSamples = rSamples

-- CS4: a cycle feeds the NN 4 frames ⇒ 65 536 samples per cell.
lawCycleRichness :: Bool
lawCycleRichness =
  cycleFrames * cellSide * cellSide == 65536

-- CS5: burst structure — 16 cycles of 4; 16 latent frames of
--      16×16×4; everything-16 closure (cycles == gridSide).
lawBurstStructure :: Bool
lawBurstStructure =
  cycles == 16
    && cycles == gridSide
    && cycles * cycleFrames == burstFrames
    && gridSide * gridSide == 256
    && gridSide * gridSide == ceilingRung   -- 16² = 256 = ceiling side
    && latentChannels == 4

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " CropShape: 4224×3024 → 2048² crop → 1024² quads → 16²"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("CS1 canonicalSide = 256·2^3, maximal for sensor",      lawCanonicalSide)
    , ("CS2 rungs {16,32,64,128,256} dyadic, quad-aligned",    lawDyadicRungs)
    , ("CS3 cell samples 4096R+8192G+4096B = 128², conserved", lawSampleAccounting)
    , ("CS4 cycle richness 4·128² = 65536 samples/cell",       lawCycleRichness)
    , ("CS5 burst = 16 cycles × 4; 16² = 256 = ceiling",       lawBurstStructure)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
