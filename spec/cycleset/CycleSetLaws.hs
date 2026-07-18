-- ════════════════════════════════════════════════════════════════
-- CycleSetLaws: the 4-DNG set → NN input tensor, under law.
--
--   N1 phase decomposition is a BIJECTION: assemble ∘ phasePlanes
--      == id, exactly (ℚ) — the network sees everything, once
--   N2 shape closed form: 16 channels × (S/2)², conservation
--      16·(S/2)² == 4·S² samples, channel order frame-major
--   N3 the keystone: cfaBin at k = 2 equals { phase-R,
--      (phase-G₁ + phase-G₂)/2, phase-B } per cell, exactly (ℚ)
--      — the input CONTAINS the finest classic baseline verbatim
--   N4 the tensor map is 1-homogeneous (ℚ): scaling a frame
--      scales its planes — exposure equivariance is inherited
--   N5 output-contract structure: target stack Σ r'² = 87296 at
--      the 2048 product shape; the seed prefix is 256 = 16² (the
--      bell-admissible slice, B laws)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.CycleSet
import Boreal.Exposure (CellRGB (..), cfaBin)
import Boreal.Geometry (gridSide)
import Boreal.MultiScale (mkMosaicUnit, prefixLen, rungsFor)

mosaic :: [[Rational]]
mosaic = mkMosaicUnit 11 16

-- N1: exact bijection.
lawBijection :: Bool
lawBijection = assemble (phasePlanes mosaic) == mosaic

-- N2: shapes and ordering.
lawShapes :: Bool
lawShapes =
  length tensor == 16
    && all (\p -> length p == 8 && all ((== 8) . length) p) tensor
    && 16 * 8 * 8 == 4 * 16 * 16
    && channelIndex 3 3 == 15
    && channelIndex 1 2 == 6
  where tensor = cycleTensor (replicate 4 mosaic)

-- N3: the phase planes ARE cfaBin at k = 2 (RGGB), exactly.
lawPhaseIsFinestBaseline :: Bool
lawPhaseIsFinestBaseline =
  and [ let CellRGB r g b = bins !! y !! x
        in r == p0 !! y !! x
             && g == (p1 !! y !! x + p2 !! y !! x) / 2
             && b == p3 !! y !! x
      | y <- [0 .. 7], x <- [0 .. 7] ]
  where bins = cfaBin 2 mosaic
        [p0, p1, p2, p3] = phasePlanes mosaic

-- N4: 1-homogeneity, exact.
lawHomogeneous :: Bool
lawHomogeneous =
  phasePlanes (map (map (* c)) mosaic)
    == map (map (map (* c))) (phasePlanes mosaic)
  where c = 7 / 3

-- N5: the output contract's structural constants.
lawOutputContract :: Bool
lawOutputContract =
  prefixLen (rungsFor 2048) 256 == 87296
    && prefixLen (rungsFor 2048) 16 == 256
    && gridSide * gridSide == 256
    && phaseColor 0 0 == 0 && phaseColor 0 3 == 2   -- RGGB: R..B
    && phaseColor 1 0 == 2 && phaseColor 1 3 == 0   -- BGGR: B..R
    && phaseColor 0 1 == 1 && phaseColor 1 2 == 1   -- G everywhere between

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " CycleSet: the 4-DNG set → what the network sees"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("N1 phase decomposition is a bijection (ℚ)",         lawBijection)
    , ("N2 16 × (S/2)² frame-major; sample conservation",   lawShapes)
    , ("N3 phases == cfaBin k=2 — the finest baseline",     lawPhaseIsFinestBaseline)
    , ("N4 tensor map is 1-homogeneous (ℚ)",                lawHomogeneous)
    , ("N5 output contract: 87296 stack, 256 bell seed",    lawOutputContract)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
