-- ════════════════════════════════════════════════════════════════
-- EvNormalize: EV-aware cycles feed the NN on a common scene scale
--
-- Mirrors the device-proven fuse math (FuseKernel.swift; ported
-- from fuse.zig, tree deleted M5) EXACTLY over ℚ (see
-- Boreal.Exposure, shared with the emitter).  The payoff law is
-- EV4: the classic CFA-binned path is 1-HOMOGENEOUS, so exact
-- pre-NN normalization plus a BIAS-FREE network makes exposure
-- equivariance of the whole pipeline a theorem, not a hope.
--
--   EV1 darkest frame ratio = 1; all ratios ≥ 1
--   EV2 scale invariance: brightness rescale leaves ratios fixed
--   EV3 fallbacks: bad metadata → {1,…}; near-equal spread →
--       {1,…} (temporal denoise); corruption clamp at 256
--   EV4 CFA binning is 1-homogeneous; normalization commutes
--   EV5 CFA binning is additive (linearity)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Ratio ((%))
import Boreal.Exposure

-- ── Laws ───────────────────────────────────────────────────────

bracket :: [(Rational, Rational, Rational)]
bracket = [ (1 % 250, 100, 178 % 100)      -- the darkest
          , (1 % 60,  100, 178 % 100)
          , (1 % 15,  200, 178 % 100)
          , (1 % 8,   400, 178 % 100) ]

-- EV1: darkest = 1 exactly; every ratio ≥ 1.
lawDarkestIsUnit :: Bool
lawDarkestIsUnit =
  minimum es == 1 && all (>= 1) es && head es == 1
  where es = relExposures bracket

-- EV2: rescaling scene brightness (all ISO × c) fixes the ratios.
lawScaleInvariance :: Bool
lawScaleInvariance =
  and [ relExposures (scaleISO c bracket) == relExposures bracket
      | c <- [2, 3, 7, 1 % 3] ]
  where scaleISO c = map (\(t, iso, n) -> (t, c * iso, n))

-- EV3: the three fallback/guard behaviors.
lawFallbacks :: Bool
lawFallbacks = badMeta && nearEqual && wideKept && corruptClamped
  where ones = [1, 1, 1, 1]
        badMeta   = relExposures ((0, 100, 2) : drop 1 bracket) == ones
        nearEqual = relExposures (replicate 4 (1 % 60, 100, 2)) == ones
        -- a 6-stop bracket is NOT clamped (64 survives) …
        sixStop   = [ (1 % 256, 100, 2), (1 % 64, 100, 2)
                    , (1 % 16, 100, 2), (1 % 4, 100, 2) ]
        wideKept  = maximum (relExposures sixStop) == 64
        -- … but a 10-stop outlier hits the 256 corruption guard.
        tenStop   = [ (1 % 1024, 100, 2), (1 % 60, 100, 2)
                    , (1 % 30, 100, 2), (1, 100, 2) ]
        corruptClamped = maximum (relExposures tenStop) == 256

-- EV4: cfaBin is 1-homogeneous, and dividing by e then binning
-- equals binning then dividing — normalization commutes exactly.
lawHomogeneous :: Bool
lawHomogeneous =
  and [ cfaBin 4 (scaleMosaic c m) == map (map (scaleCell c)) (cfaBin 4 m)
        && cfaBin 4 (scaleMosaic (1 / e) m)
             == map (map (scaleCell (1 / e))) (cfaBin 4 m)
      | seed <- [5, 6]
      , let m = mkMosaic seed 8
      , (c, e) <- [(3, 64), (1 % 7, 256)] ]

-- EV5: cfaBin is additive.
lawAdditive :: Bool
lawAdditive =
  and [ cfaBin 4 (addMosaic a b)
          == zipWith (zipWith (+)) (cfaBin 4 a) (cfaBin 4 b)
      | (sa, sb) <- [(31, 32), (33, 34)]
      , let a = mkMosaic sa 8
            b = mkMosaic sb 8 ]

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " EvNormalize: exact EV ratios + 1-homogeneous classic path"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("EV1 darkest frame = 1, all ratios ≥ 1",            lawDarkestIsUnit)
    , ("EV2 brightness rescale leaves ratios unchanged",   lawScaleInvariance)
    , ("EV3 fallbacks: bad-meta, near-equal, 256 clamp",   lawFallbacks)
    , ("EV4 cfaBin 1-homogeneous; normalize commutes",     lawHomogeneous)
    , ("EV5 cfaBin additive",                              lawAdditive)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
