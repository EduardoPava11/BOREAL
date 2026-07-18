-- ════════════════════════════════════════════════════════════════
-- Boreal.Geometry — the single source of the pipeline's constants.
-- Law files check them; the golden emitter exports them; Zig and
-- Swift ports read the emitted fixtures, never re-derive.
-- ════════════════════════════════════════════════════════════════

module Boreal.Geometry where

sensorW, sensorH :: Int
sensorW = 4224
sensorH = 3024

canonicalSide :: Int
canonicalSide = 2048          -- 256 · 2^3, maximal for the sensor

gridSide :: Int
gridSide = 16                 -- the latent is 16×16

cellSide :: Int               -- photosites per latent-cell side
cellSide = canonicalSide `div` gridSide     -- 128

quadsPerCellSide :: Int       -- RGGB quads per latent-cell side
quadsPerCellSide = cellSide `div` 2         -- 64

-- The full ladder (decided 2026-07-17): 16→32→64→128→256.
rungs :: [Int]
rungs = [16, 32, 64, 128, 256]

ceilingRung :: Int
ceilingRung = 256

burstFrames, cycleFrames, cycles :: Int
burstFrames = 64
cycleFrames = 4               -- EV re-plan cadence
cycles      = burstFrames `div` cycleFrames -- 16

latentChannels :: Int
latentChannels = 4            -- L, a, b, σ
