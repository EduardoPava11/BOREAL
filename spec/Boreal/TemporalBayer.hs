-- ════════════════════════════════════════════════════════════════
-- Boreal.TemporalBayer — the cycle's statistics (TB laws).
--
-- THE PIVOT (BOREAL-TEMPORAL-BAYER-WORKFLOW.md): the 4-frame EV
-- cycle is a per-bin experiment, not just capture mechanics. After
-- per-frame EV normalization the frames are 4 estimates of one
-- scene-linear value per bin with variance ∝ 1/e_j (shot noise), so
-- the cycle yields:
--
--   NOISE METER  per-bin weighted mean μ̂ (weights e_j = inverse
--                variance) and residual v̂; the cycle-global gain ĝ
--                is the MEDIAN of v̂/(μ̂/N) over all (bin, channel) —
--                median for robustness to scene motion (moving bins
--                inflate v̂; ≤ half the bins moving leaves ĝ sane).
--                DOCUMENTED BIAS: ĝ is a constant-factor estimator,
--                not calibrated — Gaussian-χ²₃ median alone would
--                read ≈ 0.79·g, while motion inflation and the
--                uniform injected noise pull it high (measured
--                ≈ 1.23·g₀ on the fixture). TB2's window pins
--                order-of-magnitude correctness; calibrating the
--                constant is product tuning, not spec law.
--
--   ALIAS        E1's carrier-site false color is STATIC per frame
--   DISCRIMINATOR and flips with sub-pixel tremor; true chroma is
--                stable. Per ceiling bin, with chroma proxies
--                q1 = m_R − m_G, q2 = m_B − m_G:
--                D = ½ Σ_dims [ Σ_j e_j(q_j − q̄)² / (3·V_dim) ],
--                V_dim = n̂ sum of the two channels. Noise-only
--                content → D ≈ 1 (×bias); alias/chroma-motion → ≫ 1.
--
--   σ_time       D aggregated to the seed grid (mean over the
--                (rung/seed)² block) — the temporal twin of the σ
--                head (which is cross-SCALE energy at cell Nyquist).
--
-- CONVENTIONS (normative, bit-exact cross-language): f64 end to end
-- (f32 mosaics widen exactly); channel means y-outer x-inner within
-- the cell, cells row-major, single left-fold accumulator from 0;
-- frame sums j ascending; ratio list bins-ascending × channels
-- R,G,B; median = sort ascending, take index n/2 (upper median);
-- N_R = N_B = (k/2)², N_G = 2(k/2)² with k = side/rung EVEN (the
-- whole-Bayer-period law — msRungs' (side/r)%2==0).
-- ════════════════════════════════════════════════════════════════

module Boreal.TemporalBayer where

import Data.List (sort, foldl')

-- ── Per-rung per-channel cell means (flat row-major f64 mosaic) ─

-- cfa: 0 = RGGB (even,even = R; odd,odd = B; else G); 1 = BGGR.
channelMeans :: Int -> Int -> Int -> [Double] -> ([Double], [Double], [Double])
channelMeans side rung cfa mosaic = unzip3
  [ cell cy cx | cy <- [0 .. rung - 1], cx <- [0 .. rung - 1] ]
  where
    k = side `div` rung
    quarter = fromIntegral ((k `div` 2) * (k `div` 2)) :: Double
    cell cy cx =
      let (sr, sg, sb) = foldl' add (0, 0, 0)
            [ (y, x) | y <- [cy * k .. cy * k + k - 1]
                     , x <- [cx * k .. cx * k + k - 1] ]
      in (sr / quarter, sg / (2 * quarter), sb / quarter)
      where
        add (a, g, b) (y, x) =
          let v = mosaic !! (y * side + x)
          in case (y `mod` 2, x `mod` 2) of
               (0, 0) -> if cfa == 0 then (a + v, g, b) else (a, g, b + v)
               (1, 1) -> if cfa == 0 then (a, g, b + v) else (a + v, g, b)
               _      -> (a, g + v, b)

-- ── The cycle statistics ───────────────────────────────────────

data TBStats = TBStats
  { tbMuR, tbMuG, tbMuB :: [Double]   -- rung² weighted bin means
  , tbGain              :: Double     -- ĝ, the robust noise gain
  , tbD                 :: [Double]   -- rung² alias discriminator
  , tbSigmaTime         :: [Double]   -- seed² aggregated D
  }

-- ev: one relative exposure per frame (darkest = 1); frames are the
-- EV-NORMALIZED mosaics (CQ6/EV4 upstream), all side².
temporalStats :: Int -> Int -> Int -> Int -> [Double] -> [[Double]] -> TBStats
temporalStats side cfa rung seed ev frames = TBStats muR muG muB gHat d sigT
  where
    nFrames = length frames
    dof = fromIntegral (nFrames - 1) :: Double
    sumE = foldl' (+) 0 ev
    perFrame = map (channelMeans side rung cfa) frames   -- j ascending
    chans ch = map (sel ch) perFrame
    sel 0 (r, _, _) = r
    sel 1 (_, g, _) = g
    sel _ (_, _, b) = b
    nBins = rung * rung
    k = side `div` rung
    nR = fromIntegral ((k `div` 2) * (k `div` 2)) :: Double
    nG = 2 * nR

    wmean ms i = foldl' (\s j -> s + ev !! j * (ms !! j !! i)) 0 [0 .. nFrames - 1] / sumE
    resid ms mu i =
      foldl' (\s j -> let dv = ms !! j !! i - mu in s + ev !! j * dv * dv)
             0 [0 .. nFrames - 1] / dof

    muOf ch = [ wmean (chans ch) i | i <- [0 .. nBins - 1] ]
    muR = muOf 0
    muG = muOf 1
    muB = muOf 2
    vOf ch mus = [ resid (chans ch) (mus !! i) i | i <- [0 .. nBins - 1] ]
    vR = vOf 0 muR
    vG = vOf 1 muG
    vB = vOf 2 muB

    -- ĝ: median of v̂ / (μ̂/N), bins ascending × channels R,G,B.
    ratios = concat
      [ [ ratio (vR !! i) (muR !! i) nR
        , ratio (vG !! i) (muG !! i) nG
        , ratio (vB !! i) (muB !! i) nR ]
      | i <- [0 .. nBins - 1] ]
      where ratio v mu n = if mu > 0 then v / (mu / n) else 0
    gHat = let s = sort ratios in s !! (length s `div` 2)

    -- D per bin: chroma proxies q1 = R−G, q2 = B−G.
    q1 = [ zipWith (-) (sel 0 f) (sel 1 f) | f <- perFrame ]
    q2 = [ zipWith (-) (sel 2 f) (sel 1 f) | f <- perFrame ]
    dOf qs vA vB' i =
      let mu = wmean qs i
          num = foldl' (\s j -> let dv = qs !! j !! i - mu
                                in s + ev !! j * dv * dv) 0 [0 .. nFrames - 1]
          v = vA + vB'
      in if v > 0 then num / (dof * v) else 0
    d = [ (dOf q1 (gHat * (muR !! i) / nR) (gHat * (muG !! i) / nG) i
           + dOf q2 (gHat * (muB !! i) / nR) (gHat * (muG !! i) / nG) i) / 2
        | i <- [0 .. nBins - 1] ]

    -- σ_time: mean of D over each seed cell's (rung/seed)² block.
    f = rung `div` seed
    sigT =
      [ foldl' (+) 0
          [ d !! ((sy * f + dy) * rung + sx * f + dx)
          | dy <- [0 .. f - 1], dx <- [0 .. f - 1] ]
          / fromIntegral (f * f)
      | sy <- [0 .. seed - 1], sx <- [0 .. seed - 1] ]

-- ── The fixture cycle (shared by laws + emit; deterministic) ───
--
-- Scene on side 64 (RGGB), three regions exercising the three
-- signals; frames sampled at sub-pixel tremor shifts δ_j; shot
-- noise var g₀·scene/e_j injected via the house LCG; every sample
-- quantized to k/4096 (exact in f32, f64, and JSON decimal).
--
--   x<32, y<32 : GRAY ZONE PLATE — full-spectrum luma; per-channel
--                sublattice phases disagree and FLIP with δ (alias)
--   x<32, y≥32 : FLAT GRAY 0.3 — shift-invariant, noise-only
--   x≥32       : COLOR RAMP — equal slopes, constant channel
--                offsets ⇒ chroma proxies EXACTLY shift-invariant

tbSide, tbCeiling, tbSeed :: Int
tbSide = 64
tbCeiling = 32
tbSeed = 16

tbEV :: [Double]
tbEV = [1, 4, 16, 64]

tbGain0 :: Double
tbGain0 = 0.0004

tbShifts :: [(Double, Double)]
tbShifts = [(0, 0), (0.5, 0.25), (0.25, 0.5), (0.5, 0.5)]

-- Scene value for channel ch (0=R,1=G,2=B) at CONTINUOUS coords.
tbScene :: Int -> Double -> Double -> Double
tbScene ch xx yy
  | xx < 32 && yy < 32 = 0.5 + 0.35 * cos ((xx * xx + yy * yy) / 9)
  | xx < 32            = 0.3
  | otherwise          =
      let base = 0.15 + 0.003 * xx + 0.002 * yy
      in base + case ch of 0 -> 0.12; 1 -> 0; _ -> -0.08

-- CFA channel at a site (RGGB).
tbChan :: Int -> Int -> Int
tbChan y x = case (y `mod` 2, x `mod` 2) of
  (0, 0) -> 0
  (1, 1) -> 2
  _      -> 1

-- One frame: shifted scene + LCG shot noise, dyadic-quantized.
tbFrame :: Int -> [Double]
tbFrame j =
  [ quant (v + eta s v)
  | (s, v) <- zip seeds
      [ tbScene (tbChan y x) (fromIntegral x + dx) (fromIntegral y + dy)
      | y <- [0 .. tbSide - 1], x <- [0 .. tbSide - 1] ] ]
  where
    (dx, dy) = tbShifts !! j
    e = tbEV !! j
    lcg s = s * 6364136223846793005 + 1442695040888963407
    seeds = take (tbSide * tbSide)
                 (iterate lcg (fromIntegral (j + 1) * 7919 :: Int))
    uni s = fromIntegral ((s `div` 65536) `mod` 4294967296) / 4294967296 :: Double
    eta s v = (uni s - 0.5) * sqrt (12 * tbGain0 * v / e)
    quant x = fromIntegral (round (x * 4096) :: Int) / 4096

tbFrames :: [[Double]]
tbFrames = map tbFrame [0 .. 3]

tbFixtureStats :: TBStats
tbFixtureStats = temporalStats tbSide 0 tbCeiling tbSeed tbEV tbFrames

-- Region classification at the ceiling grid.
tbZoneBins, tbColorBins :: [Int]
tbZoneBins  = [ cy * tbCeiling + cx | cy <- [0 .. 15], cx <- [0 .. 15] ]
tbColorBins = [ cy * tbCeiling + cx | cy <- [0 .. tbCeiling - 1]
                                    , cx <- [16 .. tbCeiling - 1] ]

tbMedianOf :: [Int] -> [Double] -> Double
tbMedianOf idxs xs = let s = sort [ xs !! i | i <- idxs ]
                     in s !! (length s `div` 2)
