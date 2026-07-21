-- ════════════════════════════════════════════════════════════════
-- Boreal.Geometry — the single source of the pipeline's constants.
-- Law files check them; the golden emitter exports them; Swift
-- ports read the emitted fixtures, never re-derive.
--
-- DEVICE-VERIFIED 2026-07-17 (c386663, iPhone 17 Pro real capture,
-- Mac replay bit-exact): the DECODED mosaic — what every kernel
-- downstream of the DNG decoder actually receives — is 4032×3024
-- (DefaultCropSize applied at decode). The pre-crop TILE RASTER is
-- 4224×3024 (TileWidth 264 × 16 tiles); it exists only inside the
-- decoder. Crop math is specified on the decoded mosaic.
-- ════════════════════════════════════════════════════════════════

module Boreal.Geometry where

import Data.Bits ((.&.), complement)

-- The decoded DNG mosaic (post-DefaultCrop). Device-verified.
sensorW, sensorH :: Int
sensorW = 4032
sensorH = 3024

-- The decoder-internal tile raster (pre-DefaultCrop), for reference
-- only — no law downstream of the decoder may depend on it.
rasterW, rasterH :: Int
rasterW = 4224
rasterH = 3024

-- Device-verified sensor facts (same capture): naked Bayer is
-- 12-bit on this hardware — never assume 14/16-bit white points.
cfaIndex :: Int
cfaIndex = 1                  -- BGGR (0 = RGGB)

blackLevel, whiteLevel, adcBits :: Int
blackLevel = 528
whiteLevel = 4095             -- 2^12 − 1
adcBits    = 12

canonicalSide :: Int
canonicalSide = 2048          -- 256 · 2^3, maximal for the mosaic

-- ── The crop derivation (CS1/CS6/CS7 — the app's exact rule) ────

-- Largest 256·2^j ≤ min(w, h), capped at canonicalSide.
-- Nothing when the mosaic cannot cover even the 256² ceiling.
canonicalSideFor :: Int -> Int -> Maybe Int
canonicalSideFor w h
  | m < 256   = Nothing
  | otherwise = Just (grow 256)
  where
    m = min w h
    grow s | s * 2 <= m && s * 2 <= canonicalSide = grow (s * 2)
           | otherwise                            = s

-- Centered crop origin snapped DOWN to an even coordinate so the
-- CFA phase (and therefore frame.cfa) is preserved.
cropOrigin :: Int -> Int -> Int
cropOrigin dim side = ((dim - side) `div` 2) .&. complement 1

gridSide :: Int
gridSide = 16                 -- the latent is 16×16

cellSide :: Int               -- photosites per latent-cell side
cellSide = canonicalSide `div` gridSide     -- 128

quadsPerCellSide :: Int       -- Bayer quads per latent-cell side
quadsPerCellSide = cellSide `div` 2         -- 64

-- The full ladder (2026-07-17; RENDER rung 512 added 2026-07-19 on
-- the E1-extension verdict — k=4 sub-JND on real scenes, k=2
-- rejected): 16→32→64→128→256→512.
rungs :: [Int]
rungs = [16, 32, 64, 128, 256, 512]

-- MODEL ceiling: the H2/N0/bell domain — gridSide² (the fractal
-- identity 256 = 16²). The model's food stays here; the 256 rung is
-- a PREFIX of the stack, so nothing the nets consume changes.
ceilingRung :: Int
ceilingRung = 256

-- RENDER ceiling: the GIF frame (k = 4 at the canonical 2048 — the
-- last even cell that keeps a 2×2 sample grid per chroma channel).
renderRung :: Int
renderRung = 512

burstFrames, cycleFrames, cycles :: Int
burstFrames = 64
cycleFrames = 4               -- EV re-plan cadence
cycles      = burstFrames `div` cycleFrames -- 16

latentChannels :: Int
latentChannels = 4            -- L, a, b, σ

-- ── Crop-case table (emitted; the Swift harness replays it) ─────
-- (w, h) pairs covering: the device mosaic, the pre-crop raster,
-- portrait orientation, a hypothetical 48MP readout (cap binds),
-- odd centering, exact fit, and below-ceiling rejection.
cropCases :: [(Int, Int)]
cropCases =
  [ (4032, 3024)   -- THE device mosaic (c386663)
  , (3024, 4032)   -- portrait
  , (4224, 3024)   -- pre-crop raster (if DefaultCrop were skipped)
  , (8064, 6048)   -- 48MP-class readout: cap at 2048 binds
  , (515,  300)    -- odd margins on both axes
  , (511,  511)    -- just under a doubling; odd origin snap
  , (256,  256)    -- exact fit, origin 0
  , (255,  9999)   -- short side below the 256² ceiling: rejected
  ]
