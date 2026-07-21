-- ════════════════════════════════════════════════════════════════
-- Boreal.FuseMLE — the maximum-likelihood bracket fuse (MF laws).
--
-- D11 ANSWERED (BOREAL-RAW-LIKELIHOOD-RESEARCH.md §6, Hasinoff/
-- Durand/Freeman ICCV 2010 + the Poisson-Gaussian affine law):
-- fusing an EV bracket is heteroscedastic MLE, and the optimal
-- weights are INVERSE VARIANCE with clipped samples CENSORED.
--
-- Model (per sample, frame i; y = (DN − black)/(white − black) the
-- DNG-normalized value, e_i the relative exposure (darkest = 1),
-- (S_i, O_i) the frame's NoiseProfile — var(y) = S_i·y + O_i):
--
--   x_i  = y_i / e_i                     scene-scale estimate
--   var(x_i) = (S_i·y_i + O_i) / e_i²    the same model, propagated
--   w_i  = 0                 if y_i ≥ clip          (CENSORED)
--        = e_i² / (S_i·max(y_i, 0) + O_i)  otherwise (plug-in 1/var;
--          below black the variance is the read floor O_i — the
--          sub-black tail is real signal, §3 of the research doc)
--   fused = Σ w_i·x_i / Σ w_i
--   all censored → fallback: x of the FIRST frame with minimal e
--   (the darkest frame — least likely clipped, ETTR-anchored)
--
-- Relation to the shipped heuristic (knee/clip fuse): for a fixed
-- pixel, y_i = e_i·x, so the heuristic w = y is proportional to the
-- SHOT-LIMITED MLE weight (O → 0 ⇒ w ∝ e_i; per-pixel constants
-- cancel). The MLE fuse differs exactly where the physics does:
--   • read-floor regime (deep shadows): w → e_i²/O_i — high-e
--     frames deserve MORE weight than the heuristic gives (e vs e²);
--   • per-frame profiles: frame-to-frame S changes (dual conversion
--     gain at high ISO — measured on device 2026-07-19) are honored;
--   • censoring is hard (a likelihood statement), not a rolloff.
--
-- OP ORDER (normative, bit-exact cross-language): f64 end to end;
-- weights and sums accumulate in frame order i ascending, single
-- left-fold from 0; expression shapes exactly as written.
-- ════════════════════════════════════════════════════════════════

module Boreal.FuseMLE where

import Data.List (foldl')

-- One observation: (y, e, s, o).
type Obs = (Double, Double, Double, Double)

mleWeight :: Double -> Obs -> Double
mleWeight clip (y, e, s, o)
  | y >= clip = 0
  | otherwise = e * e / (s * max y 0 + o)

-- Fused scene-scale value from one sample's observations.
fuseSampleMLE :: Double -> [Obs] -> Double
fuseSampleMLE clip obs
  | den > 0   = num / den
  | otherwise = fallback
  where
    terms = [ (mleWeight clip ob, y / e) | ob@(y, e, _, _) <- obs ]
    num = foldl' (\acc (w, x) -> acc + w * x) 0 terms
    den = foldl' (\acc (w, _) -> acc + w) 0 terms
    -- darkest frame (first minimal e), scene-scaled.
    fallback = case obs of
      [] -> 0
      _  -> let eMin = minimum [ e | (_, e, _, _) <- obs ]
                (y0, e0, _, _) = head [ ob | ob@(_, e, _, _) <- obs, e == eMin ]
            in y0 / e0

-- ── Fixture cycle (shared by laws + emit) ──────────────────────
--
-- Device-fact profiles (Daniel's iPhone 17 Pro DNGs, 2026-07-19,
-- tag 51041 read per frame — including the DCG break at ISO 1250):
-- exact decimal literals, identical in every language.

mfProfiles :: [(Double, Double)]
mfProfiles =
  [ (0.000133622, 9.7885e-07)     -- frame 1, ISO 100
  , (0.000257996, 6.53727e-07)    -- frame 2, ISO 200
  , (0.000534232, 1.31462e-06)    -- frame 3, ISO 500
  , (0.000542475, 1.30951e-06) ]  -- frame 4, ISO 1250 — S ≈ frame 3's:
                                  -- the DCG break sits between ISO 500
                                  -- and 1250 (S flat across it)

mfEV :: [Double]
mfEV = [1, 4, 16, 64]

mfClip :: Double
mfClip = 0.98

-- Deterministic scene: x_k spans deep shadow → highlight; frame
-- observations y = e·x exactly (noise-free — the laws that need
-- noise add it themselves), so censoring engages naturally where
-- e·x ≥ clip.  Dyadic x values (k/4096) from the house LCG.
mfScene :: [Double]
mfScene =
  [ fromIntegral ((s `div` 65536) `mod` 4096) / 4096
  | s <- take 256 (iterate lcg 4242 :: [Integer]) ]
  where lcg s = s * 6364136223846793005 + 1442695040888963407

mfObs :: Double -> [Obs]
mfObs x = [ (e * x, e, s, o) | (e, (s, o)) <- zip mfEV mfProfiles ]

mfFused :: [Double]
mfFused = map (fuseSampleMLE mfClip . mfObs) mfScene
