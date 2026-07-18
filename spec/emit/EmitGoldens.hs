-- ════════════════════════════════════════════════════════════════
-- EmitGoldens — writes the golden fixtures the Zig kernel tests
-- assert against (OneSix pattern: Haskell contract = Zig kernel).
--
-- Output: ../zig/borealkernel/fixtures/
--   geometry.json         pipeline constants (single source)
--   pyramid_golden.json   S-transform bands, exact arrays at 32²
--                         and 64²; FNV-1a-64 checksums at 256²
--   palette_golden.json   256 OKLab seed colors + conversion refs
--                         (tolerance 1e-9 — transcendental ulps)
--   exposure_golden.json  EV ratio cases (exact ℚ + f64) and the
--                         dyadic cfaBin mosaic (bit-exact in f64)
--
-- Checksum stream convention (normative): i32 little-endian bytes;
-- stream = top band row-major, then per detail level COARSE→FINE,
-- per quad row-major, (LH, HL, HH) interleaved.  FNV-1a 64-bit:
-- offset 14695981039346656037, prime 1099511628211.
-- Run from spec/:  runghc -W -package-env=- emit/EmitGoldens.hs
-- ════════════════════════════════════════════════════════════════

module Main where

import Data.Bits (shiftR, xor, (.&.))
import Data.List (foldl', intercalate)
import Data.Ratio (denominator, numerator)
import Data.Word (Word32, Word64)
import System.Directory (createDirectoryIfMissing)

import Boreal.ColorPath
import Boreal.Exposure
import Boreal.Geometry
import Boreal.GifTarget
import Boreal.Palette
import Boreal.Pyramid

outDir :: FilePath
outDir = "../zig/borealkernel/fixtures"

-- ── Tiny JSON writer ───────────────────────────────────────────

jStr :: String -> String
jStr s = '"' : s ++ "\""

jArr :: [String] -> String
jArr xs = "[" ++ intercalate "," xs ++ "]"

jObj :: [(String, String)] -> String
jObj kvs = "{" ++ intercalate "," [ jStr k ++ ":" ++ v | (k, v) <- kvs ] ++ "}"

jInts :: [Int] -> String
jInts = jArr . map show

jDbls :: [Double] -> String
jDbls = jArr . map show

jRat :: Rational -> String
jRat r = jArr [show (numerator r), show (denominator r)]

-- ── FNV-1a 64 over i32 little-endian bytes ─────────────────────

fnv1a64 :: [Int] -> Word64
fnv1a64 = foldl' step 14695981039346656037 . concatMap toBytes
  where toBytes v =
          let w = fromIntegral v :: Word32
          in [ fromIntegral ((w `shiftR` s) .&. 0xff) :: Word64
             | s <- [0, 8, 16, 24] ]
        step h b = (h `xor` b) * 1099511628211

-- ── Pyramid fixtures ───────────────────────────────────────────

bandStream :: Image -> [Detail] -> [Int]
bandStream top ds =
  concat top
    ++ concat [ concat [ [lh, hl, hh] | row <- d, (lh, hl, hh) <- row ]
              | d <- ds ]

pyramidExact :: Int -> Int -> String
pyramidExact seed side = jObj
  [ ("name",  jStr ("lcg_s" ++ show seed ++ "_side" ++ show side))
  , ("seed",  show seed)
  , ("side",  show side)
  , ("base",  show gridSide)
  , ("image", jInts (concat img))
  , ("top",   jInts (concat top))
  , ("levels", jArr
      [ jObj [ ("detailSide", show (length d))
             , ("lh", jInts [ x | row <- d, (x, _, _) <- row ])
             , ("hl", jInts [ x | row <- d, (_, x, _) <- row ])
             , ("hh", jInts [ x | row <- d, (_, _, x) <- row ]) ]
      | d <- ds ])
  ]
  where img       = mkImage seed side
        (top, ds) = analyzeTo gridSide img

pyramidChecksum :: Int -> Int -> String
pyramidChecksum seed side = jObj
  [ ("name",          jStr ("lcg_s" ++ show seed ++ "_side" ++ show side))
  , ("seed",          show seed)
  , ("side",          show side)
  , ("base",          show gridSide)
  , ("imageFnv1a64",  jStr (show (fnv1a64 (concat img))))
  , ("bandsFnv1a64",  jStr (show (fnv1a64 (bandStream top ds))))
  , ("topFirstRow8",  jInts (take 8 (head top)))
  ]
  where img       = mkImage seed side
        (top, ds) = analyzeTo gridSide img

pyramidJson :: String
pyramidJson = jObj
  [ ("conventions", jObj
      [ ("st",          jStr "l = floor((a+b)/2), h = a-b; inverse a = l + floor((h+1)/2), b = a-h")
      , ("quadOrder",   jStr "horizontal pairs first, then vertical (row-first)")
      , ("detailOrder", jStr "levels coarse->fine; per quad row-major (LH,HL,HH)")
      , ("lcg",         jStr "s' = s*6364136223846793005 + 1442695040888963407 (wrapping i64); sample = floorDiv(s,65536) euclidMod 4097 - 2048")
      , ("checksum",    jStr "FNV-1a 64 over i32 LE bytes; stream = top row-major ++ levels coarse->fine per quad (LH,HL,HH)")
      ])
  , ("fixtures", jArr [ pyramidExact 101 32, pyramidExact 202 64 ])
  , ("checksumFixtures", jArr [ pyramidChecksum 303 ceilingRung ])
  ]

-- ── Palette fixture ────────────────────────────────────────────

paletteJson :: String
paletteJson = jObj
  [ ("gridSide",   show gridSide)
  , ("ordering",   jStr "index = v*16 + u (u = col = hue, v = row = lightness)")
  , ("kNeighbor",  show kNeighbor)
  , ("seedChroma", show seedChroma)
  , ("tolerance",  show (1.0e-9 :: Double))
  , ("L", jDbls [ labL (palette p) | p <- cellsAll ])
  , ("a", jDbls [ labA (palette p) | p <- cellsAll ])
  , ("b", jDbls [ labB (palette p) | p <- cellsAll ])
  , ("oklabReference", jArr
      [ jObj [ ("linearSRGB", jDbls [r, g, b])
             , ("oklab", let Lab l a bb = oklabFromLinearSRGB r g b
                         in jDbls [l, a, bb]) ]
      | (r, g, b) <- refInputs ])
  ]
  where refInputs =
          [ (1, 1, 1), (0, 0, 0), (0.5, 0.5, 0.5)
          , (1, 0, 0), (0, 1, 0), (0, 0, 1), (0.25, 0.5, 0.75) ]

-- ── Exposure fixture ───────────────────────────────────────────

evCase :: String -> [(Rational, Rational, Rational)] -> String
evCase name frames = jObj
  [ ("name", jStr name)
  , ("frames", jArr
      [ jObj [ ("t", jRat t), ("iso", jRat iso), ("fnum", jRat n) ]
      | (t, iso, n) <- frames ])
  , ("expected",    jArr (map jRat es))
  , ("expectedF64", jDbls (map fromRational es))
  ]
  where es = relExposures frames

exposureJson :: String
exposureJson = jObj
  [ ("equalExposureRatio", jRat equalExposureRatio)
  , ("maxExposureRatio",   jRat maxExposureRatio)
  , ("cases", jArr
      [ evCase "bracket"
          [ (1 / 250, 100, 178 / 100), (1 / 60, 100, 178 / 100)
          , (1 / 15, 200, 178 / 100), (1 / 8, 400, 178 / 100) ]
      , evCase "sixStop"
          [ (1 / 256, 100, 2), (1 / 64, 100, 2)
          , (1 / 16, 100, 2), (1 / 4, 100, 2) ]
      , evCase "tenStopClamped"
          [ (1 / 1024, 100, 2), (1 / 60, 100, 2)
          , (1 / 30, 100, 2), (1, 100, 2) ]
      , evCase "badMeta"
          [ (0, 100, 2), (1 / 60, 100, 178 / 100)
          , (1 / 15, 200, 178 / 100), (1 / 8, 400, 178 / 100) ]
      , evCase "nearEqual"
          (replicate 4 (1 / 60, 100, 2))
      ])
  , ("cfaBin", jObj
      [ ("k",          show (4 :: Int))
      , ("side",       show (8 :: Int))
      , ("mosaicSeed", show (5 :: Int))
      , ("note",       jStr "dyadic /128 values: f64 image and means are bit-exact")
      , ("mosaicF64",  jDbls (map fromRational (concat mosaic)))
      , ("cellsR",     jDbls [ fromRational (cellR c) | row <- bins, c <- row ])
      , ("cellsG",     jDbls [ fromRational (cellG c) | row <- bins, c <- row ])
      , ("cellsB",     jDbls [ fromRational (cellB c) | row <- bins, c <- row ]) ])
  ]
  where mosaic = mkMosaic 5 8
        bins   = cfaBin 4 mosaic

-- ── Color path fixture (BIT-EXACT: owned cbrt, pinned op order) ─

colorpathJson :: String
colorpathJson = jObj
  [ ("conventions", jObj
      [ ("cbrt",     jStr "x = f*2^e, f in [1,2) via IEEE bits; y0 = 0.75 + f/4; y = (2*y + f/(y*y))/3 exactly 4 times; result = scalb(y * CORR[e mod 3], e div 3); CORR = {1, 2^(1/3), 2^(2/3)} f64 literals; 0 -> 0; negative -> odd symmetry")
      , ("matrix",   jStr "row-major 3x3; apply = m0*v0 + m1*v1 + m2*v2 left-to-right, no FMA; f64 end to end (f32 inputs widen exactly)")
      , ("compose",  jStr "PROPHOTO_TO_LMS = M1_XYZ * (BRADFORD_D50_D65 * PROPHOTO_TO_XYZ_D50), innermost first, same dot order")
      , ("quantize", jStr "Q16: q(x) = floor(x*65536 + 0.5) as i32; dequantize q = q/65536")
      , ("boxReduce", jStr "per output pixel+channel: one f64 accumulator, samples added row-major within the kxk block (sy outer, sx inner), then multiplied by 1/(k*k); LINEAR light, before OKLab")
      ])
  , ("qOne", show qOne)
  , ("matrices", jObj
      [ ("prophotoToXyzD50", jDbls (concat prophotoToXyzD50))
      , ("bradfordD50toD65", jDbls (concat bradfordD50toD65))
      , ("xyzD65toLms",      jDbls (concat xyzD65toLms))
      , ("lmsToLab",         jDbls (concat lmsToLab))
      , ("srgbToLms",        jDbls (concat srgbToLms))
      , ("prophotoToLms",    jDbls (concat prophotoToLms)) ])
  , ("cbrt", jArr
      [ jObj [ ("x", show x), ("y", show (ownedCbrt x)) ]
      | x <- cbrtInputs ])
  , ("boxReduce", jObj
      [ ("width", show (16 :: Int))
      , ("height", show (16 :: Int))
      , ("factor", show (8 :: Int))
      , ("rgb", jDbls boxImg)
      , ("out", jDbls (boxReduceRgb 16 16 8 boxImg)) ])
  , ("samples", jArr
      [ jObj [ ("prophoto", jDbls [r, g, b])
             , ("oklab", let Lab l a bb = oklabFromProPhotoLinear (r, g, b)
                         in jDbls [l, a, bb])
             , ("q16", let (ql, qa, qb) =
                             quantizeLab (oklabFromProPhotoLinear (r, g, b))
                       in jInts [ql, qa, qb]) ]
      | (r, g, b) <- sampleTriples ])
  ]
  where
    cbrtInputs = [0, 1, 2, 8, 0.125, 0.001953125, 3.375, 65536]
                   ++ take 8 dyadics
    -- Dyadic k/1024 in [0,4): exact in f32, f64, and JSON decimal.
    dyadics = [ fromIntegral k / 1024 :: Double | k <- ks ]
      where ks = iterate (\k -> (k * 2531 + 977) `mod` 4096) (1 :: Int)
    sampleTriples = take 32 (triples dyadics)
      where triples (a : b : c : rest) = (a, b, c) : triples rest
            triples _                  = []
    boxImg = take (16 * 16 * 3) dyadics

-- ── GIF target fixture (palette, index maps, display path) ─────

seedQ16 :: [Q16Lab]
seedQ16 = [ quantizeLab (palette p) | p <- cellsAll ]

gifProbes :: [Q16Lab]
gifProbes = go (map jitter (iterate lcgG 99)) seedQ16
  where
    lcgG s = s * 6364136223846793005 + 1442695040888963407
    jitter s = (s `div` 65536) `mod` 6001 - 3000
    go (dl : da : db : rest) ((l, a, b) : cs) =
      (l + dl, a + da, b + db) : go rest cs
    go _ _ = []

giftargetJson :: String
giftargetJson = jObj
  [ ("conventions", jObj
      [ ("indexing", jStr "argmin over sum of squared Q16 deltas (i64); STRICT-LESS update => ties resolve to the LOWEST index")
      , ("inverse",  jStr "OKLab -> linear sRGB via Ottosson inverse literals; cube = y*y*y pinned; dot m0*v0+m1*v1+m2*v2 left-to-right, no FMA; f64")
      , ("table",    jStr "sRGB u8 encode is NORMATIVE DATA: 4096 entries, lookup index = floor(c*4095 + 0.5) clamped to [0,4095]; ports embed the table, never call pow")
      ])
  , ("oklabToLms", jDbls
      [ 0.3963377774, 0.2158037573
      , -0.1055613458, -0.0638541728
      , -0.0894841775, -1.2914855480 ])   -- a,b coeffs per row; L coeff = 1
  , ("lmsToSrgb", jDbls
      [ 4.0767416621, -3.3077115913, 0.2309699292
      , -1.2684380046, 2.6097574011, -0.3413193965
      , -0.0041960863, -0.7034186147, 1.7076147010 ])
  , ("srgbTable", jInts (map fromIntegral srgbTable))
  , ("palette", jObj
      [ ("q16L", jInts [ l | (l, _, _) <- seedQ16 ])
      , ("q16a", jInts [ a | (_, a, _) <- seedQ16 ])
      , ("q16b", jInts [ b | (_, _, b) <- seedQ16 ])
      , ("rgb8", jInts (concat
          [ [fromIntegral r, fromIntegral g, fromIntegral b]
          | (r, g, b) <- map srgb8FromOklabQ16 seedQ16 ])) ])
  , ("indexFixture", jObj
      [ ("probes", jObj
          [ ("q16L", jInts [ l | (l, _, _) <- gifProbes ])
          , ("q16a", jInts [ a | (_, a, _) <- gifProbes ])
          , ("q16b", jInts [ b | (_, _, b) <- gifProbes ]) ])
      , ("indices", jInts (indexMap seedQ16 gifProbes))
      , ("selfIndices", jInts (indexMap seedQ16 seedQ16)) ])
  ]

-- The generated Zig source for the normative table (SixFour
-- spec-codegen pattern: emitted source, never hand-edited).
srgbTableZig :: String
srgbTableZig = unlines
  [ "//! GENERATED by spec/emit/EmitGoldens.hs (Boreal.GifTarget.srgbTable)."
  , "//! DO NOT EDIT — regenerate with `make -C spec gate`."
  , "//! The sRGB u8 encode table is NORMATIVE DATA (like an ICC blob):"
  , "//! lookup index = floor(c*4095 + 0.5) clamped to [0, 4095]."
  , ""
  , "pub const SRGB8_FROM_LINEAR_4096 = [4096]u8{"
  ] ++ rows ++ "};\n"
  where rows = concatMap row (chunk 16 (map show srgbTable))
        row xs = "    " ++ intercalate ", " xs ++ ",\n"
        chunk _ [] = []
        chunk n xs = take n xs : chunk n (drop n xs)

-- ── Geometry fixture ───────────────────────────────────────────

geometryJson :: String
geometryJson = jObj
  [ ("sensor",           jInts [sensorW, sensorH])
  , ("canonicalSide",    show canonicalSide)
  , ("gridSide",         show gridSide)
  , ("cellSide",         show cellSide)
  , ("quadsPerCellSide", show quadsPerCellSide)
  , ("rungs",            jInts rungs)
  , ("ceilingRung",      show ceilingRung)
  , ("burstFrames",      show burstFrames)
  , ("cycleFrames",      show cycleFrames)
  , ("cycles",           show cycles)
  , ("latentChannels",   show latentChannels)
  ]

-- ── Main ───────────────────────────────────────────────────────

main :: IO ()
main = do
  createDirectoryIfMissing True outDir
  emit "geometry.json"         geometryJson
  emit "pyramid_golden.json"   pyramidJson
  emit "palette_golden.json"   paletteJson
  emit "exposure_golden.json"  exposureJson
  emit "colorpath_golden.json" colorpathJson
  emit "giftarget_golden.json" giftargetJson
  writeFile "../zig/borealkernel/src/srgb_table.zig" srgbTableZig
  putStrLn "  wrote ../zig/borealkernel/src/srgb_table.zig (generated)"
  putStrLn "GOLDENS EMITTED"
  where emit name content = do
          let path = outDir ++ "/" ++ name
          writeFile path (content ++ "\n")
          putStrLn ("  wrote " ++ path)
