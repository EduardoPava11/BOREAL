-- ════════════════════════════════════════════════════════════════
-- ColorQuant: DNG → LAB — laws for the ProPhoto→OKLab→Q16 link
--
-- The device-proven decode path (Swift since M5) ends at linear
-- ProPhoto RGB.  These
-- laws pin the rest of the road into the pyramid's i32 domain:
--
--   CQ1 owned cbrt ≈ libm (1e-12) and inverts cubes
--   CQ2 anchors: ProPhoto white → OKLab (1,0,0); grays achromatic
--       — validates the Bradford D50→D65 composition end to end
--   CQ3 consistency: the XYZ(D65) route agrees with Ottosson's
--       direct sRGB route on test colors (matrix-precision tol)
--   CQ4 composed PROPHOTO_TO_LMS == the three-step application
--   CQ5 Q16 quantize: monotone, exact anchors, half-ULP error
--       bound, idempotent through dequantize
--   CQ6 mosaic normalization: black→0, white→1, exact affine (ℚ)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Ratio ((%))
import Boreal.ColorPath

-- Deterministic dyadic test values (exact in f32, f64, and JSON).
dyadics :: [Double]
dyadics = [ fromIntegral k / 1024 | k <- ks ]
  where ks = take 40 (iterate (\k -> (k * 2531 + 977) `mod` 4096) (1 :: Int))

-- CQ1: owned cbrt tracks libm within 1e-12 and inverts cubes.
lawOwnedCbrt :: Bool
lawOwnedCbrt = vsLibm && cubes && signs && zero
  where pts    = [1.0e-6, 0.001, 0.125, 0.5, 1, 1.5, 2, 8, 100, 65536] ++ dyadics
        vsLibm = and [ abs (ownedCbrt v - v ** (1 / 3))
                         <= 1.0e-12 * max 1 (v ** (1 / 3))
                     | v <- pts, v > 0 ]
        cubes  = and [ abs (ownedCbrt (y * y * y) - y) <= 1.0e-12 * y
                     | y <- [0.5, 1, 2, 3, 10] ]
        signs  = ownedCbrt (-8) == negate (ownedCbrt 8)
        zero   = ownedCbrt 0 == 0

-- CQ2: ProPhoto white and grays land where OKLab says they must.
lawProPhotoAnchors :: Bool
lawProPhotoAnchors = whiteOK && graysOK
  where Lab lw aw bw = oklabFromProPhotoLinear (1, 1, 1)
        whiteOK = abs (lw - 1) < 1.0e-3 && abs aw < 1.0e-3 && abs bw < 1.0e-3
        graysOK = and [ let Lab _ a b = oklabFromProPhotoLinear (g, g, g)
                        in abs a < 1.0e-3 && abs b < 1.0e-3
                      | g <- [0.05, 0.25, 0.5, 0.75] ]

-- CQ3: XYZ(D65) route ≈ Ottosson's direct sRGB route.
lawRouteConsistency :: Bool
lawRouteConsistency =
  and [ deltaE (oklabFromXyzD65 (apply3 srgbToXyzD65 (r, g, b)))
               (oklabFromLinearSRGB r g b)
          < 5.0e-4
      | (r, g, b) <- [ (1, 0, 0), (0, 1, 0), (0, 0, 1)
                     , (0.25, 0.5, 0.75), (0.8, 0.1, 0.4), (1, 1, 1) ] ]

-- CQ4: the baked composition equals the three-step application.
lawComposition :: Bool
lawComposition =
  and [ close (apply3 prophotoToLms v)
              (apply3 xyzD65toLms
                (apply3 bradfordD50toD65 (apply3 prophotoToXyzD50 v)))
      | r <- [0, 0.5, 1.25], g <- [0, 0.5, 1.25], b <- [0, 0.5, 1.25]
      , let v = (r, g, b) ]
  where close (a1, a2, a3) (b1, b2, b3) =
          abs (a1 - b1) < 1.0e-12 && abs (a2 - b2) < 1.0e-12
            && abs (a3 - b3) < 1.0e-12

-- CQ5: Q16 quantization laws.
lawQuantize :: Bool
lawQuantize = monotone && anchors && errBound && idem
  where xs = [-1.5, -0.7, -0.001, 0, 1.0e-5, 0.3, 0.9999, 1, 1.7] ++ dyadics
        monotone = and [ quantizeQ16 a <= quantizeQ16 b
                       | a <- xs, b <- xs, a <= b ]
        anchors  = quantizeQ16 0 == 0
                     && quantizeQ16 1 == qOne
                     && quantizeQ16 (-1) == negate qOne
        errBound = and [ abs (dequantizeQ16 (quantizeQ16 x) - x)
                           <= 0.5 / 65536 + 1.0e-12
                       | x <- xs ]
        idem     = and [ quantizeQ16 (dequantizeQ16 (quantizeQ16 x))
                           == quantizeQ16 x
                       | x <- xs ]

-- CQ7: box reduce preserves constants exactly and is 1-homogeneous.
lawBoxReduceBasics :: Bool
lawBoxReduceBasics = constPreserved && homogeneous
  where flat = concat (replicate (16 * 16) [0.25, 0.5, 0.75])
        constPreserved =
          boxReduceRgb 16 16 8 flat == concat (replicate 4 [0.25, 0.5, 0.75])
        img = take (16 * 16 * 3) (cycle dyadics)
        homogeneous =
          boxReduceRgb 16 16 8 (map (* 4) img)
            == map (* 4) (boxReduceRgb 16 16 8 img)

-- CQ8: the f64 path equals an exact ℚ mean on dyadic inputs (the
--      inputs are chosen so no f64 rounding can occur — the golden
--      is therefore bit-exact even through an f32 output).
lawBoxReduceExact :: Bool
lawBoxReduceExact =
  map toRational (boxReduceRgb 16 16 8 img) == exactMeans
  where img = take (16 * 16 * 3) (cycle dyadics)
        imgQ = map toRational img
        exactMeans =
          concat
            [ [ sum [ imgQ !! (3 * ((oy * 8 + sy) * 16 + (ox * 8 + sx)) + ch)
                    | sy <- [0 .. 7], sx <- [0 .. 7] ] / 64
              | ch <- [0 .. 2] ]
            | oy <- [0 .. 1], ox <- [0 .. 1] ]

-- CQ6: mosaic normalization is the exact affine map (ℚ).
lawNormalize :: Bool
lawNormalize = anchors && affine
  where black = 512 % 1
        white = 16383 % 1
        n     = normalizeSample black white
        anchors = n black == 0 && n white == 1
        affine  = and [ n r1 - n r2 == (r1 - r2) / (white - black)
                      | r1 <- [600, 1000, 8000], r2 <- [700, 12000] ]

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " ColorQuant: ProPhoto → OKLab → Q16, bit-exact by design"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("CQ1 owned cbrt ≈ libm (1e-12), inverts cubes",     lawOwnedCbrt)
    , ("CQ2 ProPhoto white → (1,0,0); grays achromatic",   lawProPhotoAnchors)
    , ("CQ3 XYZ route ≈ direct sRGB route (ΔE < 5e-4)",    lawRouteConsistency)
    , ("CQ4 composed PROPHOTO_TO_LMS == three-step path",  lawComposition)
    , ("CQ5 Q16: monotone, anchors, ½-ULP bound, idem",    lawQuantize)
    , ("CQ6 normalization: black→0, white→1, affine (ℚ)",  lawNormalize)
    , ("CQ7 box reduce: constants exact, 1-homogeneous",   lawBoxReduceBasics)
    , ("CQ8 box reduce f64 == exact ℚ mean on dyadics",    lawBoxReduceExact)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
