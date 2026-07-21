-- ════════════════════════════════════════════════════════════════
-- MleFuseLaws: the maximum-likelihood bracket fuse, pinned (MF laws;
-- D11 answered — inverse-variance weights from the per-frame
-- NoiseProfile, censored at clip).
--
--   MF1 consistency: noise-free coherent observations (y = e·x, all
--       unclipped) fuse to EXACTLY x — weights normalize out
--   MF2 shot-limited degeneracy: with O = 0 and equal S, weights are
--       ∝ e (the shipped heuristic's regime); fused == Σe·x_i/Σe
--   MF3 read-floor degeneracy: with S = 0, weights are ∝ e²/O —
--       high-e frames dominate quadratically in deep shadow
--   MF4 censoring: y ≥ clip contributes ZERO; all-censored falls
--       back to the darkest frame's scene estimate
--   MF5 variance dominance: fused variance 1/Σw never exceeds the
--       best single frame's variance (Σw ≥ max w)
--   MF6 sub-black: y < 0 keeps its value with read-floor weight
--       e²/O — the shadow tail is data, not garbage
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.FuseMLE

approx :: Double -> Double -> Bool
approx a b = abs (a - b) <= 1e-12 * max 1 (abs b)

-- MF1: coherent noise-free observations fuse to exactly x.
lawConsistency :: Bool
lawConsistency =
  and [ approx (fuseSampleMLE mfClip (mfObs x)) x
      | x <- mfScene, all (\(y, _, _, _) -> y < mfClip) (mfObs x) ]

-- MF2: O = 0, equal S ⇒ w ∝ e ⇒ fused = Σ e·x_i / Σ e.
lawShotLimited :: Bool
lawShotLimited = and [ check x noise | x <- [0.001, 0.01, 0.2], noise <- [0, 0.0004] ]
  where
    check x0 noise =
      let xs = [ x0 + noise, x0 - noise, x0 + noise / 2, x0 ]
          obs = [ (e * x, e, 0.0002, 0) | (e, x) <- zip mfEV xs
                , e * x < mfClip ]
          want = sum [ e * (y / e) | (y, e, _, _) <- obs ]
               / sum [ e | (_, e, _, _) <- obs ]
          -- w = e²/(S·y) = e²/(S·e·x) ∝ e/x; for the equal-x case the
          -- x cancels; with jitter it does not — so compute the TRUE
          -- weighted mean and compare against fuseSampleMLE directly:
          w (y, e, s, _) = e * e / (s * y)
          true = sum [ w ob * (y / e) | ob@(y, e, _, _) <- obs ]
               / sum [ w ob | ob <- obs ]
      in approx (fuseSampleMLE mfClip obs) true
         && (noise > 0 || approx (fuseSampleMLE mfClip obs) want)

-- MF3: S = 0 ⇒ w ∝ e²/O.
lawReadFloor :: Bool
lawReadFloor = approx got want
  where
    obs = [ (e * 0.001, e, 0, o) | (e, (_, o)) <- zip mfEV mfProfiles ]
    w (_, e, _, o) = e * e / o
    want = sum [ w ob * (y / e) | ob@(y, e, _, _) <- obs ]
         / sum [ w ob | ob <- obs ]
    got = fuseSampleMLE mfClip obs

-- MF4: censoring — clipped frames contribute zero; all-clipped
-- falls back to the darkest frame's estimate.
lawCensoring :: Bool
lawCensoring = partial && total
  where
    -- x = 0.05: frames at e = 16, 64 have y = 0.8, 3.2 → e=64 clipped.
    obsP = mfObs 0.05
    unclipped = [ ob | ob@(y, _, _, _) <- obsP, y < mfClip ]
    partial = approx (fuseSampleMLE mfClip obsP)
                     (fuseSampleMLE mfClip unclipped)
                && length unclipped == 3
    -- everything clipped → darkest frame's y/e.
    obsT = [ (0.99, e, s, o) | (e, (s, o)) <- zip mfEV mfProfiles ]
    total = approx (fuseSampleMLE mfClip obsT) (0.99 / 1)

-- MF5: 1/Σw ≤ 1/max w ⇔ fused variance never worse than the best
-- single frame (checked over the fixture scene's unclipped samples).
lawDominance :: Bool
lawDominance =
  and [ let ws = [ mleWeight mfClip ob | ob <- mfObs x ]
        in sum ws >= maximum ws
      | x <- mfScene ]

-- MF6: sub-black values keep their value, weighted by the read floor.
lawSubBlack :: Bool
lawSubBlack = approx got want
  where
    obs = [ (-0.002, 1, 0.0002, 1e-6), (0.004, 4, 0.0002, 1e-6) ]
    w1 = 1 / 1e-6                                    -- e=1, y<0 → e²/O
    w2 = 16 / (0.0002 * 0.004 + 1e-6)
    want = (w1 * (-0.002) + w2 * (0.004 / 4)) / (w1 + w2)
    got = fuseSampleMLE mfClip obs

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " MleFuse: inverse-variance bracket fusion (D11, MF laws)"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("MF1 coherent frames fuse to exactly x",                lawConsistency)
    , ("MF2 shot-limited limit: w ∝ e (the old heuristic)",    lawShotLimited)
    , ("MF3 read-floor limit: w ∝ e²/O",                       lawReadFloor)
    , ("MF4 censoring: clipped = zero; all-clipped → darkest", lawCensoring)
    , ("MF5 fused variance ≤ best single frame",               lawDominance)
    , ("MF6 sub-black is data: value kept, read-floor weight", lawSubBlack)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
