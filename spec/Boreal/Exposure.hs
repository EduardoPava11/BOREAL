-- ════════════════════════════════════════════════════════════════
-- Boreal.Exposure — exact EV ratios (mirror of bk_relative_exposures)
-- and the classic CFA-binned path over ℚ.
--
-- E = ISO · t / N².  Ratios against the darkest frame; fallbacks
-- to {1,…} on bad metadata or near-equal spread; clamp [1, 256].
-- Test mosaics are DYADIC rationals (denominator 128) so their
-- f64 images and binned means are exactly representable — the
-- emitted goldens are bit-exact for a float port.
-- ════════════════════════════════════════════════════════════════

module Boreal.Exposure where

import Data.Ratio ((%))

-- ── Relative exposures ─────────────────────────────────────────

equalExposureRatio :: Rational
equalExposureRatio = 10353 % 10000          -- 0.05 stop

maxExposureRatio :: Rational
maxExposureRatio = 256                      -- 8-stop corruption guard

-- (exposure time t, ISO, f-number N) per frame → ratios e_t ≥ 1,
-- darkest = 1.
relExposures :: [(Rational, Rational, Rational)] -> [Rational]
relExposures frames
  | any (\(t, _, _) -> t <= 0) frames = ones
  | emin <= 0                         = ones
  | spread <= equalExposureRatio      = ones
  | otherwise                         = map clamp ratios
  where es      = [ iso * t / (n * n) | (t, iso, n) <- frames ]
        emin    = minimum es
        emax    = maximum es
        spread  = emax / emin
        ratios  = map (/ emin) es
        clamp e = max 1 (min maxExposureRatio e)
        ones    = map (const 1) frames

-- ── The classic CFA-binned path (exact, over ℚ) ────────────────

type Mosaic = [[Rational]]                  -- RGGB, row-major

data CellRGB = CellRGB Rational Rational Rational
  deriving (Eq)

cellR, cellG, cellB :: CellRGB -> Rational
cellR (CellRGB r _ _) = r
cellG (CellRGB _ g _) = g
cellB (CellRGB _ _ b) = b

instance Num CellRGB where
  CellRGB a b c + CellRGB d e f = CellRGB (a + d) (b + e) (c + f)
  CellRGB a b c * CellRGB d e f = CellRGB (a * d) (b * e) (c * f)
  abs (CellRGB a b c)    = CellRGB (abs a) (abs b) (abs c)
  signum (CellRGB a b c) = CellRGB (signum a) (signum b) (signum c)
  negate (CellRGB a b c) = CellRGB (negate a) (negate b) (negate c)
  fromInteger n          = CellRGB (fromInteger n) (fromInteger n) (fromInteger n)

scaleCell :: Rational -> CellRGB -> CellRGB
scaleCell k (CellRGB r g b) = CellRGB (k * r) (k * g) (k * b)

-- Bin a mosaic into cells of side k (k even): per-CFA-channel
-- exact means.  RGGB: (even,even)=R, (odd,odd)=B, else G.
cfaBin :: Int -> Mosaic -> [[CellRGB]]
cfaBin k mosaic =
  [ [ cell cy cx | cx <- [0 .. w `div` k - 1] ]
  | cy <- [0 .. h `div` k - 1] ]
  where h = length mosaic
        w = length (head mosaic)
        cell cy cx =
          let sites = [ (r, c, (mosaic !! r) !! c)
                      | r <- [cy * k .. cy * k + k - 1]
                      , c <- [cx * k .. cx * k + k - 1] ]
              mean xs = sum xs / fromIntegral (length xs)
              rs = [ x | (r, c, x) <- sites, even r, even c ]
              bs = [ x | (r, c, x) <- sites, odd r, odd c ]
              gs = [ x | (r, c, x) <- sites, even r /= even c ]
          in CellRGB (mean rs) (mean gs) (mean bs)

scaleMosaic :: Rational -> Mosaic -> Mosaic
scaleMosaic k = map (map (k *))

addMosaic :: Mosaic -> Mosaic -> Mosaic
addMosaic = zipWith (zipWith (+))

-- Deterministic DYADIC ℚ test mosaic (LCG numerators / 128).
lcgQ :: Integer -> Integer
lcgQ s = s * 6364136223846793005 + 1442695040888963407

mkMosaic :: Integer -> Int -> Mosaic
mkMosaic seed side =
  chunk side [ (v `mod` 16383) % 128 | v <- take (side * side) vals ]
  where vals = map (abs . (`div` 65536)) (iterate lcgQ seed)
        chunk _ [] = []
        chunk n xs = take n xs : chunk n (drop n xs)
