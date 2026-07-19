-- ════════════════════════════════════════════════════════════════
-- Boreal.ColorPath — DNG → LAB: the missing link, specified.
--
-- The device-proven decode path (now Swift — the Zig origin is
-- deleted, M5) already reaches LINEAR PROPHOTO RGB
-- (decode → fuse → demosaic → cam_to_pp).  This module pins the
-- rest: ProPhoto(D50) → XYZ → Bradford → XYZ(D65) → LMS → OKLab,
-- then Q16 quantization into the pyramid's i32 domain.
--
-- EVERYTHING HERE IS BIT-EXACT CROSS-LANGUAGE, including cbrt:
--
-- OWNED CBRT (normative):  libm cbrt differs across languages by
-- ulps, which would break quantization ties.  So BOREAL owns it:
--   x = f · 2^e, f ∈ [1,2)  (IEEE exponent/mantissa, exact)
--   y0 = 0.75 + f/4
--   y  ← (2·y + f/(y·y)) / 3       exactly 4 Newton iterations
--   cbrt x = scaleFloat (e div 3) (y · CORR[e mod 3])
--   CORR = {1, 2^(1/3), 2^(2/3)}   (f64 literals)
--   x = 0 → 0;  x < 0 → −cbrt(−x).  Same IEEE f64 ops everywhere.
--
-- MATRIX CONVENTION (normative): apply = row·vec, evaluated
-- m0·v0 + m1·v1 + m2·v2 left-to-right, NO FMA.  Composition
-- PROPHOTO_TO_LMS = M1_XYZ · (BRADFORD · PROPHOTO_TO_XYZ_D50),
-- innermost first, same dot order.  Computation in f64 end to end
-- (f32 pipeline samples widen exactly).
--
-- QUANTIZE (normative): Q16, q(x) = floor(x·65536 + 0.5) as i32;
-- dequantize q = q/65536.
-- ════════════════════════════════════════════════════════════════

module Boreal.ColorPath where

-- ── Lab + ΔE (single home; Boreal.Palette re-exports) ──────────

data Lab = Lab { labL :: Double, labA :: Double, labB :: Double }

deltaE :: Lab -> Lab -> Double
deltaE (Lab l1 a1 b1) (Lab l2 a2 b2) =
  sqrt ((l1 - l2) ^ two + (a1 - a2) ^ two + (b1 - b2) ^ two)
  where two = 2 :: Int

-- ── Owned deterministic cbrt ───────────────────────────────────

cbrt2, cbrt4 :: Double
cbrt2 = 1.2599210498948731647672106072782   -- 2^(1/3)
cbrt4 = 1.5874010519681994747517056392723   -- 2^(2/3)

ownedCbrt :: Double -> Double
ownedCbrt x
  | x == 0    = 0
  | x < 0     = negate (ownedCbrt (negate x))
  | otherwise =
      let (sig, ex) = decodeFloat x        -- x = sig·2^ex, sig ∈ [2^52, 2^53)
          f  = encodeFloat sig (-52)       -- f ∈ [1,2), exact
          e  = ex + 52
          it y = (2 * y + f / (y * y)) / 3
          y4 = it (it (it (it (0.75 + f / 4))))
          corr = case e `mod` 3 of
                   0 -> 1.0
                   1 -> cbrt2
                   _ -> cbrt4
      in scaleFloat (e `div` 3) (y4 * corr)

-- ── Matrices (row-major 3×3) ───────────────────────────────────

type M3 = [[Double]]

apply3 :: M3 -> (Double, Double, Double) -> (Double, Double, Double)
apply3 [r0, r1, r2] (x, y, z) = (dot r0, dot r1, dot r2)
  where dot [m0, m1, m2] = m0 * x + m1 * y + m2 * z
        dot _            = error "apply3: malformed row"
apply3 _ _ = error "apply3: malformed matrix"

mul3 :: M3 -> M3 -> M3
mul3 a b =
  [ [ (a !! i !! 0) * (b !! 0 !! j)
        + (a !! i !! 1) * (b !! 1 !! j)
        + (a !! i !! 2) * (b !! 2 !! j)
    | j <- [0 .. 2] ]
  | i <- [0 .. 2] ]

-- ROMM/ProPhoto RGB → XYZ (D50).  Rows sum to D50 white.
prophotoToXyzD50 :: M3
prophotoToXyzD50 =
  [ [0.7976749, 0.1351917, 0.0313534]
  , [0.2880402, 0.7118741, 0.0000857]
  , [0.0,       0.0,       0.8252100] ]

-- Bradford chromatic adaptation D50 → D65.
bradfordD50toD65 :: M3
bradfordD50toD65 =
  [ [ 0.9555766, -0.0230393, 0.0631636]
  , [-0.0282895,  1.0099416, 0.0210077]
  , [ 0.0122982, -0.0204830, 1.3299098] ]

-- Linear sRGB → XYZ (D65), for the consistency law only.
srgbToXyzD65 :: M3
srgbToXyzD65 =
  [ [0.4124564, 0.3575761, 0.1804375]
  , [0.2126729, 0.7151522, 0.0721750]
  , [0.0193339, 0.1191920, 0.9503041] ]

-- OKLab M1: XYZ (D65) → LMS  (Björn Ottosson).
xyzD65toLms :: M3
xyzD65toLms =
  [ [0.8189330101,  0.3618667424, -0.1288597137]
  , [0.0329845436,  0.9293118715,  0.0361456387]
  , [0.0482003018,  0.2643662691,  0.6338517070] ]

-- OKLab M2: cbrt-LMS → Lab  (Björn Ottosson).
lmsToLab :: M3
lmsToLab =
  [ [0.2104542553,  0.7936177850, -0.0040720468]
  , [1.9779984951, -2.4285922050,  0.4505937099]
  , [0.0259040371,  0.7827717662, -0.8086757660] ]

-- Ottosson's direct linear-sRGB → LMS (higher-precision literals;
-- used by the palette).
srgbToLms :: M3
srgbToLms =
  [ [0.4122214708, 0.5363325363, 0.0514459929]
  , [0.2119034982, 0.6806995451, 0.1073969566]
  , [0.0883024619, 0.2817188376, 0.6299787005] ]

-- The ONE composed matrix the kernel bakes: ProPhoto-linear → LMS.
-- Order pinned: innermost (BRADFORD · PROPHOTO) first.
prophotoToLms :: M3
prophotoToLms = mul3 xyzD65toLms (mul3 bradfordD50toD65 prophotoToXyzD50)

-- ── OKLab constructors ─────────────────────────────────────────

oklabFromLms :: (Double, Double, Double) -> Lab
oklabFromLms (l, m, s) =
  let (bigL, a, b) = apply3 lmsToLab (ownedCbrt l, ownedCbrt m, ownedCbrt s)
  in Lab bigL a b

oklabFromLinearSRGB :: Double -> Double -> Double -> Lab
oklabFromLinearSRGB r g b = oklabFromLms (apply3 srgbToLms (r, g, b))

oklabFromXyzD65 :: (Double, Double, Double) -> Lab
oklabFromXyzD65 = oklabFromLms . apply3 xyzD65toLms

oklabFromProPhotoLinear :: (Double, Double, Double) -> Lab
oklabFromProPhotoLinear = oklabFromLms . apply3 prophotoToLms

-- ── Q16 quantization into the pyramid's i32 domain ─────────────

qOne :: Int
qOne = 65536

quantizeQ16 :: Double -> Int
quantizeQ16 x = floor (x * 65536 + 0.5)

dequantizeQ16 :: Int -> Double
dequantizeQ16 q = fromIntegral q / 65536

quantizeLab :: Lab -> (Int, Int, Int)
quantizeLab (Lab l a b) = (quantizeQ16 l, quantizeQ16 a, quantizeQ16 b)

-- ── Linear-light box reduce (L2 step 6; the ONE new L2 kernel) ─

-- Interleaved RGB, row-major; factor k divides width and height.
-- CONVENTION (normative): per output pixel and channel, ONE f64
-- accumulator, samples added in row-major order within the k×k
-- block (sy outer, sx inner), then multiplied by 1/k² (exact for
-- power-of-two k).  Averaging happens in LINEAR light, before any
-- transfer function — that is why this step precedes OKLab.
boxReduceRgb :: Int -> Int -> Int -> [Double] -> [Double]
boxReduceRgb w h k rgb =
  concat
    [ [ meanAt ch oy ox | ch <- [0 .. 2] ]
    | oy <- [0 .. h `div` k - 1], ox <- [0 .. w `div` k - 1] ]
  where
    inv = 1 / fromIntegral (k * k)
    meanAt ch oy ox =
      foldl (\acc i -> acc + rgb !! i) 0
        [ 3 * ((oy * k + sy) * w + (ox * k + sx)) + ch
        | sy <- [0 .. k - 1], sx <- [0 .. k - 1] ]
        * inv

-- ── Mosaic normalization (the seam to the device-proven side) ──

-- lin = (raw − black) / (white − black), exact over ℚ.
normalizeSample :: Rational -> Rational -> Rational -> Rational
normalizeSample black white raw = (raw - black) / (white - black)
