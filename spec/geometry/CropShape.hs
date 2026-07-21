-- ════════════════════════════════════════════════════════════════
-- CropShape: Bayer geometry for the 64-burst → 16×16 latent
--
-- The DECODED mosaic is 4032×3024, BGGR, 12-bit (black 528, white
-- 4095) — DEVICE-VERIFIED 2026-07-17 (c386663; DefaultCropSize is
-- applied at decode; the pre-crop tile raster 4224×3024 exists only
-- inside the decoder). The canonical crop side is the LARGEST
-- S = 256·2^j that fits the short mosaic side, capped at 2048:
-- S = 2048 (j = 3). Everything downstream is dyadic: the quad grid
-- is 1024², a 16×16 latent cell spans 128 photosites = 64 quads,
-- and every ladder rung {16,32,64,128,256} divides the crop side
-- with quad alignment.
--
-- Burst structure: 64 frames = 16 EV cycles × 4 frames.  One NN
-- inference per cycle ⇒ the burst yields 16 latent frames of
-- 16×16×4.  Constants live in Boreal.Geometry (single source).
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Bits ((.&.))
import Data.Maybe (fromJust, isJust)
import Boreal.Geometry

-- ── Laws ───────────────────────────────────────────────────────

-- CS1: the canonical side is DERIVED from the device mosaic by the
--      app's own rule — largest 256·2^j ≤ min side, capped — and
--      the next doubling would not fit under the cap on this
--      hardware (maximality).
lawCanonicalSide :: Bool
lawCanonicalSide =
  canonicalSideFor sensorW sensorH == Just canonicalSide
    && canonicalSide == 256 * 2 ^ (3 :: Int)
    && canonicalSide <= minSide
    && 256 * 2 ^ (4 :: Int) > minSide
  where minSide = min sensorW sensorH

-- CS2: the ladder is the full dyadic run from the 16² base to the
--      RENDER ceiling (512², added 2026-07-19 on the E1-extension
--      verdict); the MODEL ceiling 256² = gridSide² (the fractal
--      identity — H2/N0/bell domain) sits inside it as a rung; every
--      rung divides the crop side with whole-quad alignment (an even
--      photosite span — the carrier-nulling condition).
lawDyadicRungs :: Bool
lawDyadicRungs =
  rungs == takeWhile (<= renderRung) (iterate (* 2) gridSide)
    && length rungs == 6
    && last rungs == renderRung
    && ceilingRung == gridSide * gridSide
    && ceilingRung `elem` rungs
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

-- CS6: the derivation over the crop-case table — every accepted
--      side is a rung-compatible power-of-two 256·2^j within the
--      cap AND maximal for its mosaic; below-ceiling mosaics are
--      rejected; the cap binds on oversize readouts.
lawDerivationTable :: Bool
lawDerivationTable =
  and [ ok w h | (w, h) <- cropCases ]
    && canonicalSideFor 8064 6048 == Just canonicalSide  -- cap binds
    && canonicalSideFor 255 9999 == Nothing              -- rejected
    && canonicalSideFor 256 256  == Just 256             -- exact fit
  where
    ok w h = case canonicalSideFor w h of
      Nothing -> min w h < 256
      Just s  ->
        s >= 256 && s <= canonicalSide
          && isPow2 (s `div` 256)
          && s <= min w h
          && (s == canonicalSide || 2 * s > min w h)     -- maximal
    isPow2 n = n > 0 && n .&. (n - 1) == 0

-- CS7: the crop origin is EVEN on both axes (CFA phase survives),
--      in bounds, and centered to within one photosite of the true
--      center (the even snap moves it at most 1).
lawCropOrigin :: Bool
lawCropOrigin =
  and [ originOK d s
      | (w, h) <- cropCases
      , isJust (canonicalSideFor w h)
      , let s = fromJust (canonicalSideFor w h)
      , d <- [w, h] ]
  where
    originOK dim side =
      let o      = cropOrigin dim side
          center = (dim - side) `div` 2
      in even o && o >= 0 && o + side <= dim
           && center - o <= 1 && center - o >= 0

-- CS8: device-verified sensor facts — the naked Bayer on this
--      hardware is 12-bit (white = 2^12 − 1, NOT 16383), black
--      sits strictly inside the range, and the CFA is BGGR.
lawDeviceFacts :: Bool
lawDeviceFacts =
  whiteLevel == 2 ^ adcBits - 1
    && adcBits == 12
    && blackLevel == 528
    && blackLevel > 0 && blackLevel < whiteLevel
    && cfaIndex == 1                        -- BGGR
    && min rasterW rasterH >= min sensorW sensorH  -- crop shrinks

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " CropShape: 4032×3024 (decoded) → 2048² crop → 1024² quads"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("CS1 canonicalSide DERIVED from device mosaic, maximal",  lawCanonicalSide)
    , ("CS2 rungs 16…512 dyadic, quad-aligned; 256 = model ceiling", lawDyadicRungs)
    , ("CS3 cell samples 4096R+8192G+4096B = 128², conserved",   lawSampleAccounting)
    , ("CS4 cycle richness 4·128² = 65536 samples/cell",         lawCycleRichness)
    , ("CS5 burst = 16 cycles × 4; 16² = 256 = ceiling",         lawBurstStructure)
    , ("CS6 derivation table: maximal, capped, reject <256",     lawDerivationTable)
    , ("CS7 crop origin even, in-bounds, centered within 1",     lawCropOrigin)
    , ("CS8 device facts: 12-bit (white 4095), black 528, BGGR", lawDeviceFacts)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
