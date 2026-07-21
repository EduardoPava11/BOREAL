-- ════════════════════════════════════════════════════════════════
-- BinContractLaws: THE BIN-COMMUTATION THEOREM, machine-checked in
-- exact ℚ (Boreal.BinContract — the V1 engine's input contract).
--
--   BC1 φ ∘ β_b = box_b ∘ φ : phase decomposition commutes with
--       per-phase binning (each phase plane is independently
--       box-reduced)
--   BC2 THE THEOREM: cfaBin(S/(b·r)) ∘ β_b = cfaBin(S/r) — the
--       ladder factors through binning, EXACTLY in ℚ, at every
--       rung whose binned cell is a whole even quad count
--   BC3 ladder split: rungsFor(S/b) = { r ∈ rungsFor S | r ≤ S/(2b) }
--       — at device scale (2048, b=4) the binned ladder IS the
--       model rungs and the render rung is the exact complement
--   BC4 1-homogeneity: β_b(λ·m) = λ·β_b(m) — exposure equivariance
--       (N4) survives the binned input
--   BC5 N3 on device: cfaBin 2 ∘ β_b = cfaBin 2b — the encoder's
--       verbatim k=2 baseline is the model-ceiling rung of the
--       full ladder
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Ratio ((%))
import Boreal.BinContract
import Boreal.CycleSet (phasePlanes)
import Boreal.Exposure (cfaBin, mkMosaic, scaleMosaic)
import Boreal.MultiScale (rungsFor)

side :: Int
side = 64

mosaics :: [Mosaic']
mosaics = [ mkMosaic s side | s <- [7, 1234, 987654321] ]

type Mosaic' = [[Rational]]

-- BC1: phase decomposition commutes with per-phase binning.
lawPhaseCommute :: Bool
lawPhaseCommute =
  and [ phasePlanes (binPhase b m) == map (boxPlane b) (phasePlanes m)
      | m <- mosaics, b <- [2, 4] ]

-- BC2: THE THEOREM — the ladder factors through β_b, exactly.
lawBinCommute :: Bool
lawBinCommute =
  and [ cfaBin (side `div` (b * r)) (binPhase b m) == cfaBin (side `div` r) m
      | m <- mosaics
      , b <- [2, 4]
      , r <- rungsFor (side `div` b) ]

-- BC3: the ladder split, at the fixture scale AND the device scale.
lawLadderSplit :: Bool
lawLadderSplit =
  and [ rungsFor (s `div` b) == [ r | r <- rungsFor s, r <= s `div` (2 * b) ]
      | (s, b) <- [(side, 2), (side, 4), (2048, 4), (2048, 2)] ]
    && rungsFor (2048 `div` 4) == [16, 32, 64, 128, 256]   -- the model rungs
    && [ r | r <- rungsFor 2048, r > 2048 `div` 8 ] == [512] -- the render rung

-- BC4: β_b is 1-homogeneous (exact).
lawHomogeneous :: Bool
lawHomogeneous =
  and [ binPhase b (scaleMosaic (7 % 3) m) == scaleMosaic (7 % 3) (binPhase b m)
      | m <- mosaics, b <- [2, 4] ]

-- BC5: N3 transported — the binned k=2 baseline is the full
-- mosaic's model-ceiling rung.
lawN3Device :: Bool
lawN3Device =
  and [ cfaBin 2 (binPhase b m) == cfaBin (2 * b) m
      | m <- mosaics, b <- [2, 4] ]

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " BinContract: the ladder factors through binning (exact ℚ)"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("BC1 phase decomposition commutes with β_b",           lawPhaseCommute)
    , ("BC2 THEOREM: cfaBin ∘ β_b == cfaBin (all shared rungs)", lawBinCommute)
    , ("BC3 ladder split: binned ladder == model rungs; render = complement", lawLadderSplit)
    , ("BC4 β_b 1-homogeneous: exposure equivariance survives", lawHomogeneous)
    , ("BC5 N3 on device: binned k=2 baseline == model-ceiling rung", lawN3Device)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
