-- ════════════════════════════════════════════════════════════════
-- HierarchyLaws: (16×16)×(16×16) = 256×256 — V1 is H.
--
--   H1 the coordinate factorization is a bijection on [0, 65536)
--   H2 patches ⇄ frame is exact; every patch holds 256 pixels
--   H3 the perfect-H frame: homeShare = 1, usage ≡ 256, χ² = 0 —
--      binomial balance and home-centering meet at one fixed point
--   H4 the deterministic up maps level-0 perfection to level-1
--      perfection: nearest-upscale of the A2 identity seed IS the
--      perfect-H ceiling (the JEPA's up-arrow respects the ideal)
--   H5 collapse anchor: the one-color frame's homeShare is exactly
--      1/256 (only its own patch scores) — closed form
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.Binomial (indexChiSquare, usageHistogram)
import Boreal.PatchGrid

-- H1
lawFactorBijection :: Bool
lawFactorBijection =
  16 * 16 * (16 * 16) == 256 * 256
    && and [ unfactorIdx (factorIdx i) == i | i <- probe ]
    && and [ let ((v, u), (j, i)) = factorIdx idx
             in v >= 0 && v < 16 && u >= 0 && u < 16
                  && j >= 0 && j < 16 && i >= 0 && i < 16
           | idx <- probe ]
  where probe = [0, 1, 15, 16, 255, 256, 4095, 4096, 32768, 65535]

-- H2
lawPatchBijection :: Bool
lawPatchBijection =
  assemblePatches (patches frame) == frame
    && all ((== 256) . length) (patches frame)
    && length (patches frame) == 256
  where frame = [ (i * 2531 + 977) `mod` 256 | i <- [0 .. 65535] ]

-- H3
lawPerfectH :: Bool
lawPerfectH =
  homeShare pureH == 1
    && usageHistogram pureH == replicate 256 256
    && indexChiSquare pureH == 0

-- H4: nearest-upscale of the identity seed == pureH.
lawUpRespectsIdeal :: Bool
lawUpRespectsIdeal =
  upscale16 [0 .. 255] == pureH
  where
    upscale16 seed =
      [ seed !! ((y `div` 16) * 16 + (x `div` 16))
      | y <- [0 .. 255], x <- [0 .. 255] ]

-- H5
lawCollapseShare :: Bool
lawCollapseShare = homeShare (replicate 65536 0) == 1 / 256

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " Hierarchy: (16×16)×(16×16) = 256×256 — V1 is H"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("H1 coordinate factorization is a bijection",        lawFactorBijection)
    , ("H2 patches ⇄ frame exact; 256 patches of 256",      lawPatchBijection)
    , ("H3 perfect-H: homeShare 1, usage ≡ 256, χ² = 0",   lawPerfectH)
    , ("H4 up(A2 identity seed) == the perfect-H ceiling",  lawUpRespectsIdeal)
    , ("H5 collapse homeShare = 1/256, closed form",        lawCollapseShare)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
