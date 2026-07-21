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

-- ── Camera → ProPhoto: the DNG matrix composition (CQ9/CQ10) ───
--
-- THE MAGENTA LAW (NT, normative): whatever tags a DNG carries, the
-- composed camera→ProPhoto matrix MUST map AsShotNeutral to EQUAL
-- ProPhoto channels (gray).  This is the illuminant-independent
-- regression that catches every WB/matrix composition error — the
-- 2026-07-19 device magenta (neutral → (1.78, 0.92, 1.70)) was a
-- violation of exactly this law.
--
-- Two source shapes (DNG spec):
--   FM path — ForwardMatrix maps WHITE-BALANCED camera to XYZ(D50):
--     M = XYZ_TO_PROPHOTO_D50 · FM · diag(g/asn_r, 1, g/asn_b)
--   CM fallback — ColorMatrix maps XYZ(calib illum) → camera; iPhone
--   DNGs carry ONLY CM1 (StdA) + CM2 (D65).  Prefer CM2; then:
--     camToXYZ = inv3 CM
--     XYZ_w    = camToXYZ · asn, normalized Y = 1  (the scene white)
--     M        = XYZ_TO_PROPHOTO_D50 · bradfordToD50 XYZ_w · camToXYZ
--   NO wb diagonal in the CM path: white balance is IMPLICIT — the
--   inverted CM carries the real neutral to the scene white and the
--   Bradford adaptation carries that to D50.  Bolting diag(wb) onto
--   an inverted CM applies white balance twice (the magenta bug).
--
-- OP ORDER (normative, bit-exact cross-language): inv3 = cofactor
-- expansion exactly as written below (invDet = 1/det, then each
-- entry = cofactor · invDet); mul3/apply3 as above; column scaling
-- and diagonal construction as written.  Full CCT interpolation
-- between CM1/CM2 is out of scope (documented simplification: CM2).

-- XYZ (D50) → ProPhoto linear (Lindbloom inverse literals — the
-- house values, ex color.zig).
xyzToProphotoD50 :: M3
xyzToProphotoD50 =
  [ [ 1.3459434, -0.2556075, -0.0511118]
  , [-0.5445988,  1.5081673,  0.0205351]
  , [ 0.0,        0.0,        1.2118128] ]

-- Bradford cone response (the classic CAT literals).
bradfordCone :: M3
bradfordCone =
  [ [ 0.8951,  0.2664, -0.1614]
  , [-0.7502,  1.7135,  0.0367]
  , [ 0.0389, -0.0685,  1.0296] ]

-- D50 white, derived from the ONE source of truth: ProPhoto rows
-- sum to D50 white, so this is prophotoToXyzD50 · (1,1,1).
d50White :: (Double, Double, Double)
d50White = apply3 prophotoToXyzD50 (1, 1, 1)

-- 3×3 inverse, cofactor expansion, PINNED op shapes.
inv3 :: M3 -> M3
inv3 [[m0, m1, m2], [m3, m4, m5], [m6, m7, m8]] =
  [ [(m4 * m8 - m5 * m7) * iv, (m2 * m7 - m1 * m8) * iv, (m1 * m5 - m2 * m4) * iv]
  , [(m5 * m6 - m3 * m8) * iv, (m0 * m8 - m2 * m6) * iv, (m2 * m3 - m0 * m5) * iv]
  , [(m3 * m7 - m4 * m6) * iv, (m1 * m6 - m0 * m7) * iv, (m0 * m4 - m1 * m3) * iv] ]
  where det = m0 * (m4 * m8 - m5 * m7) - m1 * (m3 * m8 - m5 * m6)
                + m2 * (m3 * m7 - m4 * m6)
        iv  = 1 / det
inv3 _ = error "inv3: malformed matrix"

-- Bradford adaptation: arbitrary white → D50.
bradfordToD50 :: (Double, Double, Double) -> M3
bradfordToD50 w = mul3 (inv3 bradfordCone) (mul3 diag bradfordCone)
  where (cwX, cwY, cwZ) = apply3 bradfordCone w
        (cdX, cdY, cdZ) = apply3 bradfordCone d50White
        diag = [ [cdX / cwX, 0, 0], [0, cdY / cwY, 0], [0, 0, cdZ / cwZ] ]

-- FM path: M = P · FM · diag(green-normalized WB multipliers).
cameraToProPhotoFM :: M3 -> (Double, Double, Double) -> M3
cameraToProPhotoFM fm (ar, ag, ab) = mul3 xyzToProphotoD50 fmWB
  where (mr, mg, mb) = (ag / ar, 1, ag / ab)
        fmWB = [ [r0 * mr, r1 * mg, r2 * mb] | [r0, r1, r2] <- fm ]

-- CM fallback: implicit WB via the scene white + Bradford to D50.
cameraToProPhotoCM :: M3 -> (Double, Double, Double) -> M3
cameraToProPhotoCM cm asn = mul3 xyzToProphotoD50 (mul3 brad camToXYZ)
  where camToXYZ     = inv3 cm
        (xw, yw, zw) = apply3 camToXYZ asn
        brad         = bradfordToD50 (xw / yw, 1, zw / yw)

-- ── Device facts: iPhone 17 Pro color tags (frame_1, 2026-07-19) ─
--
-- EXACT SRATIONAL/RATIONAL pairs from the DNG — every language
-- computes num/den itself so the doubles agree bitwise.  This DNG
-- carries NO ForwardMatrix (CM fallback is the live path on device).

iphone17CM1R, iphone17CM2R :: [(Integer, Integer)]
iphone17CM1R =
  [ (30917, 23785), (-15491, 23931), (-32079, 138332)
  , (-14161, 31063), (39702, 26231), (-5828, 216193)
  , (-4343, 108172), (6649, 46096), (38417, 60034) ]
iphone17CM2R =
  [ (23439, 24499), (-46959, 123674), (-15473, 119683)
  , (-66223, 156922), (161308, 123231), (5846, 65367)
  , (-8383, 84491), (6997, 33292), (20525, 43929) ]

iphone17ASNR :: [(Integer, Integer)]
iphone17ASNR = [(29791, 70950), (1, 1), (73143, 144911)]

ratToM3 :: [(Integer, Integer)] -> M3
ratToM3 ps = [ [d a, d b, d c] | [a, b, c] <- chunk3 ps ]
  where d (n, m) = fromIntegral n / fromIntegral m
        chunk3 (a : b : c : rest) = [a, b, c] : chunk3 rest
        chunk3 _ = []

ratToTriple :: [(Integer, Integer)] -> (Double, Double, Double)
ratToTriple [(a, b), (c, d), (e, f)] =
  ( fromIntegral a / fromIntegral b
  , fromIntegral c / fromIntegral d
  , fromIntegral e / fromIntegral f )
ratToTriple _ = error "ratToTriple: need 3 pairs"

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
