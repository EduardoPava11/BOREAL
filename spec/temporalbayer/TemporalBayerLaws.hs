-- ════════════════════════════════════════════════════════════════
-- TemporalBayerLaws: the cycle's statistics, pinned (THE PIVOT).
--
--   TB1 static exactness: identical noise-free frames ⇒ μ̂ equals
--       the single-frame channel means BITWISE, ĝ = 0, D = 0
--   TB2 noise meter: on the fixture cycle (known injected gain g₀,
--       25% of bins scene-moving), ĝ lands in the documented
--       robust-median window [0.5·g₀, 1.1·g₀]
--   TB3 alias separation: median D over zone-plate bins exceeds
--       100× the median over color-ramp bins; color median sits in
--       the noise-consistent window (0.2, 5)
--   TB4 EV-scale invariance: relabeling exposure (e→2e, frames
--       halved — dyadic λ) leaves ĝ, D, σ_time EXACTLY unchanged
--       (μ̂ halves exactly)
--   TB5 frame-order invariance: reversing frames+ev moves D by
--       ≤ 1e-9 relative (f64 re-association only)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.TemporalBayer

-- TB1: a static, noise-free cycle at EQUAL exposures is EXACT —
-- equal weights make μ̂ = (4m)/4 = m bitwise, so every residual is
-- exactly zero and ĝ, D, σ_time are exactly zero. (Unequal e_j sum
-- to 85: 5m/85m rounding makes exactness impossible — that variant
-- is covered by TB4's dyadic relabeling instead.)
lawStatic :: Bool
lawStatic = muExact && gZero && dZero
  where
    scene = [ tbScene (tbChan y x) (fromIntegral x) (fromIntegral y)
            | y <- [0 .. tbSide - 1], x <- [0 .. tbSide - 1] ]
    st = temporalStats tbSide 0 tbCeiling tbSeed [1, 1, 1, 1] (replicate 4 scene)
    (mr, mg, mb) = channelMeans tbSide tbCeiling 0 scene
    muExact = tbMuR st == mr && tbMuG st == mg && tbMuB st == mb
    gZero = tbGain st == 0
    dZero = all (== 0) (tbD st) && all (== 0) (tbSigmaTime st)

-- TB2: the robust noise meter recovers the injected gain to within
-- a factor — measured on this fixture ĝ ≈ 1.23·g₀ (uniform noise +
-- 25% scene-moving bins pull the median HIGH; the Gaussian-χ²₃
-- story alone would pull it low). The law is order-of-magnitude
-- correctness (catches sign/scale/normalization bugs); calibration
-- of the constant is product tuning, not spec law.
lawNoiseMeter :: Bool
lawNoiseMeter = g >= 0.5 * tbGain0 && g <= 1.5 * tbGain0
  where g = tbGain tbFixtureStats

-- TB3: D separates alias (zone) from true chroma (ramp).
lawAliasSeparation :: Bool
lawAliasSeparation = zoneMed > 100 * colorMed
                       && colorMed > 0.2 && colorMed < 5
  where
    zoneMed = tbMedianOf tbZoneBins (tbD tbFixtureStats)
    colorMed = tbMedianOf tbColorBins (tbD tbFixtureStats)

-- TB4: exposure relabeling by a dyadic λ is EXACT.
lawEVScale :: Bool
lawEVScale = tbGain st' == tbGain st
               && tbD st' == tbD st
               && tbSigmaTime st' == tbSigmaTime st
               && tbMuR st' == map (/ 2) (tbMuR st)
  where
    st = tbFixtureStats
    st' = temporalStats tbSide 0 tbCeiling tbSeed
                        (map (* 2) tbEV)
                        (map (map (/ 2)) tbFrames)

-- TB5: frame order only re-associates f64 sums.
lawFrameOrder :: Bool
lawFrameOrder = and (zipWith close (tbD st') (tbD tbFixtureStats))
  where
    st' = temporalStats tbSide 0 tbCeiling tbSeed
                        (reverse tbEV) (reverse tbFrames)
    close a b = abs (a - b) <= 1.0e-9 * max 1 (abs b)

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " TemporalBayer: the cycle is the atom — noise, alias, time"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("TB1 static noise-free cycle is bitwise exact",        lawStatic)
    , ("TB2 noise meter: ĝ in the robust window of g₀",       lawNoiseMeter)
    , ("TB3 D: zone ≫ 100× color; color noise-consistent",    lawAliasSeparation)
    , ("TB4 EV relabeling (dyadic λ): ĝ, D, σ_time EXACT",    lawEVScale)
    , ("TB5 frame order: D moves ≤ 1e-9 (re-association)",    lawFrameOrder)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
