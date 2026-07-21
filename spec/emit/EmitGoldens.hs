-- ════════════════════════════════════════════════════════════════
-- EmitGoldens — writes the golden fixtures the Swift kernel harness
-- asserts against (OneSix pattern: Haskell contract = Swift kernel).
--
-- Output: ../fixtures/
--   geometry.json         pipeline constants + device-verified
--                         sensor facts + the crop-case table
--                         (single source; Swift replays the cases)
--   palette_golden.json   256 OKLab seed colors + conversion refs
--                         (tolerance 1e-9 — transcendental ulps)
--   exposure_golden.json  EV ratio cases (exact ℚ + f64) and the
--                         dyadic cfaBin mosaic (bit-exact in f64)
--   ... (colorpath, giftarget, multiscale, gifwire, cycleset,
--        binomial, battle — see each section)
--
-- (The S-transform pyramid fixture was retired 2026-07-18 with its
-- law file — superseded by the multi-scale residual stack; git
-- history and archive/zig-kernel preserve it.)
-- Run from spec/:  runghc -W -package-env=- emit/EmitGoldens.hs
-- ════════════════════════════════════════════════════════════════

module Main where

import Data.List (elemIndex, intercalate)
import Data.Ratio (denominator, numerator)
import System.Directory (createDirectoryIfMissing)

import Boreal.Battle
import Boreal.BinContract
import Boreal.FuseMLE
import Boreal.PatchGrid
import Boreal.Binomial
import Boreal.ColorPath
import Boreal.CycleSet
import Boreal.DitherWalk
import Boreal.Exposure
import Boreal.Geometry
import Boreal.GifTarget
import Boreal.GifWire
import Boreal.MultiScale
import Boreal.Palette
import Boreal.TemporalBayer

outDir :: FilePath
outDir = "../fixtures"

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
  , ("bellNote", jStr "bellCounts = the B-law luminance allocation over 16 strata (sums to 256); bellTargets = bellPalette's 256 luminances in rank order — stratum k owns [k/16,(k+1)/16), L = (k + (pos+0.5)/cnt)/16, ends pinned to EXACT 0 and 1; these are the trainer's quantile targets (nn/v1 bell_quantile_targets), never retyped")
  , ("bellCounts",  jInts bellCounts)
  , ("bellTargets", jDbls [ labL (bellPalette i) | i <- [0 .. 255] ])
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
  , ("camera", jObj
      [ ("conventions", jObj
          [ ("nt",  jStr "NT law: composed camera->ProPhoto matrix maps AsShotNeutral to EQUAL channels (gray); relative spread < 1e-5")
          , ("fm",  jStr "FM path: M = XYZ_TO_PROPHOTO_D50 * FM * diag(g/asn_r, 1, g/asn_b) — ForwardMatrix consumes WHITE-BALANCED camera")
          , ("cm",  jStr "CM fallback (iPhone live path): camToXYZ = inv3(CM2 preferred); XYZw = camToXYZ*asn normalized Y=1; M = XYZ_TO_PROPHOTO_D50 * bradfordToD50(XYZw) * camToXYZ; NO wb diagonal (implicit WB — diag on an inverted CM = the 2026-07-19 magenta bug)")
          , ("inv3", jStr "cofactor expansion, invDet = 1/det then multiply, op shapes pinned in Boreal.ColorPath; rationals: each language computes num/den itself in f64")
          ])
      , ("deviceNote", jStr "iPhone 17 Pro frame_1 2026-07-19: NO ForwardMatrix; CM1 = StdA, CM2 = D65; exact SRATIONAL/RATIONAL pairs, flattened [n0,d0,n1,d1,...]")
      , ("deviceCM1rat", jInts (concat [ [fromIntegral n, fromIntegral d]
                                       | (n, d) <- iphone17CM1R ]))
      , ("deviceCM2rat", jInts (concat [ [fromIntegral n, fromIntegral d]
                                       | (n, d) <- iphone17CM2R ]))
      , ("deviceASNrat", jInts (concat [ [fromIntegral n, fromIntegral d]
                                       | (n, d) <- iphone17ASNR ]))
      , ("xyzToProphotoD50", jDbls (concat xyzToProphotoD50))
      , ("bradfordCone",     jDbls (concat bradfordCone))
      , ("d50White",         jDbls (let (x, y, z) = d50White in [x, y, z]))
      , ("camToXYZ",   jDbls (concat (inv3 (ratToM3 iphone17CM2R))))
      , ("camToPP_CM", jDbls (concat (cameraToProPhotoCM (ratToM3 iphone17CM2R)
                                                         (ratToTriple iphone17ASNR))))
      , ("camToPP_FMtest", jDbls (concat (cameraToProPhotoFM prophotoToXyzD50
                                                             (ratToTriple iphone17ASNR))))
      , ("neutralPP_CM", jDbls
          (let (r, g, b) = apply3 (cameraToProPhotoCM (ratToM3 iphone17CM2R)
                                                      (ratToTriple iphone17ASNR))
                                  (ratToTriple iphone17ASNR)
           in [r, g, b]))
      , ("neutralPP_FM", jDbls
          (let (r, g, b) = apply3 (cameraToProPhotoFM prophotoToXyzD50
                                                      (ratToTriple iphone17ASNR))
                                  (ratToTriple iphone17ASNR)
           in [r, g, b]))
      ])
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

-- The generated SWIFT source for the normative table (Phase 5:
-- Swift + Metal is the kernel language; emitted source, never
-- hand-edited).
srgbTableSwift :: String
srgbTableSwift = unlines
  [ "// GENERATED by spec/emit/EmitGoldens.hs (Boreal.GifTarget.srgbTable)."
  , "// DO NOT EDIT — regenerate with `make -C spec gate`."
  , "// The sRGB u8 encode table is NORMATIVE DATA (like an ICC blob):"
  , "// lookup index = floor(c*4095 + 0.5) clamped to [0, 4095]."
  , ""
  , "extension BorealKernels {"
  , "    static let srgb8FromLinear4096: [UInt8] = ["
  ] ++ rows ++ "    ]\n}\n"
  where rows = concatMap row (chunk 16 (map show srgbTable))
        row xs = "        " ++ intercalate ", " xs ++ ",\n"
        chunk _ [] = []
        chunk n xs = take n xs : chunk n (drop n xs)

-- ── Multi-scale fixture (Phase 3: demosaic at every scale) ─────

multiscaleJson :: String
multiscaleJson = jObj
  [ ("conventions", jObj
      [ ("rung",     jStr "rung r = its OWN demosaic: per-CFA-channel exact mean over (side/r)^2 cells (RGGB: even,even=R; odd,odd=B; else G), then camera->ProPhoto matrix, then ProPhoto->OKLab->Q16 (colorpath conventions)")
      , ("stack",    jStr "residual stack per channel: rung16 ++ (rung2s - upsample2(rungS)) coarse->fine; upsample2 = exact 2x2 nearest replication (each row: values doubled, row emitted twice)")
      , ("layout",   jStr "prefix through rung r = sum of r'^2 for r' <= r; decode(prefix r) == THE rung-r demosaic (MS3)")
      , ("mosaic",   jStr "normalized [0,1) dyadic /16384 (exact in f32/f64); LCG s'=s*6364136223846793005+1442695040888963407 wrap; numerator = abs(floorDiv(s,65536)) mod 16384")
      ])
  , ("fixture", jObj
      [ ("seed",   show (7 :: Int))
      , ("side",   show msSide)
      , ("rungs",  jInts (rungsFor msSide))
      , ("matrix", jStr "identity (has_color = false path)")
      , ("mosaicF64", jDbls (map fromRational (concat msMosaic)))
      , ("bandsL", jInts (msBands (\(l, _, _) -> l)))
      , ("bandsA", jInts (msBands (\(_, a, _) -> a)))
      , ("bandsB", jInts (msBands (\(_, _, b) -> b))) ])
  ]
  where
    msSide = 128
    msMosaic = mkMosaicUnit 7 msSide
    msIdent = [[1, 0, 0], [0, 1, 0], [0, 0, 1]] :: M3
    msStack = rungStack msIdent msSide msMosaic
    msBands pick = encodeMS [ (r, pick planes) | (r, planes) <- msStack ]

-- ── GIF wire fixture (Phase 4: the ISP's native output) ────────

gifwireJson :: String
gifwireJson = jObj
  [ ("conventions", jObj
      [ ("lzw",    jStr "minCodeSize 8; fixed 9-bit codes packed LSB-first; stream = CLEAR(256) ++ index groups of <=254 with CLEAR between ++ EOI(257); code width never grows; sub-blocks <=255 bytes + 0x00 terminator")
      , ("file",   jStr "GIF89a; LSD packed 0xF7 (GCT, 256); GCT 768 bytes; NETSCAPE2.0 loop 0 (infinite); per frame GCE(delay, no transparency) + descriptor(full canvas, no LCT) + LZW; trailer 0x3B")
      , ("length", jStr "codes = 1 + n + (ceil(n/254)-1) + 1; dataB = ceil(9*codes/8); frameB = 1 + dataB + ceil(dataB/255) + 1")
      ])
  , ("fixture", jObj
      [ ("side",    show gwSide)
      , ("delayCs", show gwDelay)
      , ("palette", jInts (map fromIntegral gwGct))
      , ("frames",  jArr [ jInts (map fromIntegral f) | f <- gwFrames ])
      , ("gifBytes", jInts (map fromIntegral (encodeGif gwSide gwDelay gwGct gwFrames))) ])
  ]
  where
    gwSide  = 16
    gwDelay = 20
    gwGct = concat
      [ [r, g, b]
      | i <- [0 .. 255]
      , let (r, g, b) = srgb8FromOklabQ16 (quantizeLab (bellPalette i)) ]
    gwFrames =
      [ map fromIntegral [0 .. 255 :: Int]
      , [ fromIntegral ((s `div` 65536) `mod` 256)
        | s <- take 256 (iterate gwLcg 41) ] ]
    gwLcg s = s * 6364136223846793005 + 1442695040888963407 :: Integer

-- ── Cycle-set fixture (Phase 6: the NN's input contract) ───────

cyclesetJson :: String
cyclesetJson = jObj
  [ ("conventions", jObj
      [ ("phases",  jStr "POSITIONAL, CFA-agnostic: phase 0 = (even,even), 1 = (even,odd), 2 = (odd,even), 3 = (odd,odd); plane_p[y][x] = mosaic[2y+py][2x+px]; exact bijection")
      , ("tensor",  jStr "cycle tensor = 4 EV-normalized frames x 4 phases = 16 channels, frame-major: channel = 4*frame + phase; frames in capture order (green,red,blue,shadow once the ETTR plan governs)")
      , ("meaning", jStr "RGGB: phase 0=R, 1=G, 2=G, 3=B; BGGR: phase 0=B, 3=R; color meaning is metadata, never geometry")
      , ("keystone", jStr "cfaBin k=2 == { phase0, (phase1+phase2)/2, phase3 } per cell EXACTLY (RGGB) — the input contains the finest classic baseline verbatim (law N3)")
      , ("normalization", jStr "each frame divided by its own relative exposure BEFORE decomposition (CQ6/EV4) — the tensor map is 1-homogeneous, exposure equivariance is inherited")
      ])
  , ("fixture", jObj
      [ ("seed", show (11 :: Int))
      , ("side", show (16 :: Int))
      , ("mosaicF64", jDbls (map fromRational (concat csMosaic)))
      , ("phases", jArr
          [ jInts [ q16FromUnit v | row <- p, v <- row ]
          | p <- phasePlanes csMosaic ])
      , ("note", jStr "phases here are Q16-quantized (floor(v*65536+0.5)) purely to keep the golden integer-exact; the trainer decomposes the f32 mosaic positionally and must match after the same quantization")
      ])
  ]
  where
    csMosaic = mkMosaicUnit 11 16
    q16FromUnit v = quantizeQ16 (fromRational v)

-- ── Binomial fixture (the V1 objective statistic) ──────────────

binomialJson :: String
binomialJson = jObj
  [ ("conventions", jObj
      [ ("chi2", jStr "chi^2 = sum_j (c_j - n/256)^2 * 256 / n over the 256-count usage histogram; 0 = balanced (the A2 permutation at n=256); one-color collapse = 255*n; frame sizes 256*4^k make chi^2 dyadic => f64 bit-exact")
      , ("v1",   jStr "V1 is judged by this number (with the bell and dE): balanced usage = maximal index-stream entropy = the palette earns all 256 codes")
      ])
  , ("fixtures", jArr
      [ binFx "identity" [0 .. 255]
      , binFx "collapse256" (replicate 256 0)
      , binFx "lcg4096" (binLcg 7 4096)
      , binFx "lcg65536" (binLcg 9 65536)
      ])
  ]
  where
    binFx name xs = jObj
      [ ("name", jStr name)
      , ("n", show (length xs))
      , ("indices", if length xs <= 4096 then jInts xs else jStr "lcg")
      , ("seed", show (binSeed name))
      , ("counts", jInts (usageHistogram xs))
      , ("chi2F64", show (fromRational (indexChiSquare xs) :: Double))
      ]
    binSeed n = case n of
      "lcg4096"  -> 7 :: Int
      "lcg65536" -> 9
      _          -> 0
    binLcg seed n =
      [ fromIntegral ((s `div` 65536) `mod` 256)
      | s <- take n (iterate (\x -> x * 6364136223846793005
                                      + 1442695040888963407) (fromIntegral seed :: Integer)) ]

-- ── Battle fixture (BA5: the temporal delta primitive) ─────────

battleJson :: String
battleJson = jObj
  [ ("conventions", jObj
      [ ("delta", jStr "frameDelta a b = [(pos, new)] at positions where a and b differ, ascending; applyDelta a (frameDelta a b) == b EXACTLY (BA5); churn = list length")
      , ("patchMajor", jStr "the fractal record's ordering: patch (v,u) outer row-major, inner (j,i) row-major - H2/PatchGrid; pos = (v*16+u)*256 + (j*16+i) on the 256x256 ceiling")
      , ("homeShare", jStr "homeShare = (1/256) * sum over patches p of the share of patch p's pixels equal to p on the (16x16)x(16x16) ceiling (H laws) = own/65536 — power-of-two denominator, so the expected f64 is EXACT; the index frame is regenerated counts-free from the baLcg convention: idx_k = (s_k div 65536) mod 256 row-major, s_{k+1} = s_k*6364136223846793005 + 1442695040888963407, s_0 = seed, Haskell Integer (never wraps); the extracted byte is bits 16..23 of a positive s, which depend only on the low 64 bits — wrapping-u64 regeneration is exactly equivalent")
      ])
  , ("fixture", jObj
      [ ("a",        jInts frA)
      , ("b",        jInts frB)
      , ("deltaPos", jInts (map fst dl))
      , ("deltaNew", jInts (map snd dl))
      , ("churn",    show (churn frA frB))
      ])
  , ("patchMajorSpots", jArr (map spotJson pmSpots))
  , ("homeShare", jObj
      [ ("seed",     show hsSeed)
      , ("n",        show (side256 * side256))
      , ("expected", show (fromRational (homeShare hsFrame) :: Double))
      ])
  ]
  where
    frA = baLcg 5 4096
    frB = baLcg 11 4096
    dl  = frameDelta frA frB
    baLcg seed n =
      [ fromIntegral ((s `div` 65536) `mod` 256)
      | s <- take n (iterate (\x -> x * 6364136223846793005
                                      + 1442695040888963407)
                             (fromIntegral (seed :: Int) :: Integer)) ]
    -- Spot positions COMPUTED from PatchGrid's own ordering (never
    -- retyped): pos = where `patches` places ceiling index
    -- unfactorIdx((v,u),(j,i)) in its concatenated output.
    pmIdentity = concat (patches [0 .. side256 * side256 - 1])
    spotJson (v, u, j, i) =
      let src = unfactorIdx ((v, u), (j, i))
          pos = maybe (error "patchMajor spot not in the ordering") id
                      (elemIndex src pmIdentity)
      in jObj [ ("v", show v), ("u", show u)
              , ("j", show j), ("i", show i)
              , ("pos", show pos) ]
    pmSpots :: [(Int, Int, Int, Int)]
    pmSpots =
      [ (0, 0, 0, 0), (0, 0, 0, 1), (0, 0, 1, 0), (0, 1, 0, 0)
      , (1, 0, 0, 0), (3, 5, 7, 9), (9, 7, 5, 3), (7, 7, 7, 7)
      , (0, 15, 0, 15), (15, 0, 15, 0), (0, 15, 15, 0), (15, 0, 0, 15)
      , (1, 2, 3, 4), (12, 10, 8, 6), (5, 11, 2, 14), (15, 15, 15, 15) ]
    hsSeed  = 13 :: Int
    hsFrame = baLcg hsSeed (side256 * side256)

-- ── Walk fixture (P1: the FS walk loop, DW7/DW8) ───────────────

walkJson :: String
walkJson = jObj
  [ ("conventions", jObj
      [ ("path",      jStr "serpentine: even rows left->right, odd rows right->left; emission serpentine, stored ROW-MAJOR")
      , ("pick",      jStr "windowPick r on CORRECTED value (target + carry, Q16 ints, never clamped); window row-major dv-outer du-ascending, cells clamped to the 16x16 grid; STRICT-LESS argmin")
      , ("split",     jStr "FS shares (7,3,5,1)/16 floor-div; remainder joins the EAST share; per channel")
      , ("neighbors", jStr "walk order: east,(sw,s,se) next row; kernel MIRRORS horizontally on odd rows; out-of-frame shares DROPPED and summed per channel")
      , ("conservation", jStr "sum(target) - sum(palette[emitted]) == droppedSum per channel, exact (DW8)")
      , ("jitter",    jStr "target = pure-H upscale of the palette + LCG jitter: s' = s*6364136223846793005 + 1442695040888963407 (unbounded Integer); delta = (s' div 65536) mod 4001 - 2000; three draws per pixel (L,a,b)")
      ])
  , ("r",        show (2 :: Int))
  , ("side",     show wSide)
  , ("jitterSeed", show (7 :: Int))
  , ("paletteL", jInts [ l | (l, _, _) <- wPal ])
  , ("paletteA", jInts [ a | (_, a, _) <- wPal ])
  , ("paletteB", jInts [ b | (_, _, b) <- wPal ])
  , ("targetL",  jInts [ l | (l, _, _) <- wTgt ])
  , ("targetA",  jInts [ a | (_, a, _) <- wTgt ])
  , ("targetB",  jInts [ b | (_, _, b) <- wTgt ])
  , ("indices",  jInts wIdx)
  , ("dropped",  jInts [ dl, da, db ])
  ]
  where
    wSide = 16 :: Int
    wPal = [ quantizeLab (bellPalette i) | i <- [0 .. 255] ]
    wTgt = jitterTargetFor wPal 7 wSide
    (wIdx, (dl, da, db)) = fsWalk 2 wPal wTgt

-- ── Geometry fixture ───────────────────────────────────────────

geometryJson :: String
geometryJson = jObj
  [ ("conventions", jObj
      [ ("sensor",     jStr "DECODED DNG mosaic (post-DefaultCrop) — what every kernel receives; device-verified 2026-07-17 c386663; pre-crop tile raster is rasterPreCrop, decoder-internal only")
      , ("crop",       jStr "canonical side = largest 256*2^j <= min(w,h), capped at canonicalSide; null when min(w,h) < 256; origin = ((dim-side) div 2) & ~1 (even snap preserves CFA phase)")
      , ("cropCases",  jStr "replayed verbatim by the Swift harness against BorealKernels.canonicalSide/cropOrigin")
      ])
  , ("sensor",           jInts [sensorW, sensorH])
  , ("rasterPreCrop",    jInts [rasterW, rasterH])
  , ("deviceVerified", jObj
      [ ("cfa",     show cfaIndex)
      , ("cfaName", jStr "BGGR")
      , ("black",   show blackLevel)
      , ("white",   show whiteLevel)
      , ("adcBits", show adcBits)
      ])
  , ("canonicalSide",    show canonicalSide)
  , ("gridSide",         show gridSide)
  , ("cellSide",         show cellSide)
  , ("quadsPerCellSide", show quadsPerCellSide)
  , ("rungs",            jInts rungs)
  , ("ceilingRung",      show ceilingRung)
  , ("renderRung",       show renderRung)
  , ("burstFrames",      show burstFrames)
  , ("cycleFrames",      show cycleFrames)
  , ("cycles",           show cycles)
  , ("latentChannels",   show latentChannels)
  , ("cropCases", jArr [ cropCaseJson w h | (w, h) <- cropCases ])
  ]
  where
    cropCaseJson w h = case canonicalSideFor w h of
      Nothing -> jObj [ ("w", show w), ("h", show h)
                      , ("side", "null") ]
      Just s  -> jObj [ ("w", show w), ("h", show h)
                      , ("side", show s)
                      , ("x0", show (cropOrigin w s))
                      , ("y0", show (cropOrigin h s)) ]

-- ── Main ───────────────────────────────────────────────────────

-- ── MleFuse fixture (MF laws — D11: inverse-variance bracket fuse) ─

mlefuseJson :: String
mlefuseJson = jObj
  [ ("conventions", jObj
      [ ("model", jStr "var(y) = S*y + O on the DNG-normalized signal (NoiseProfile tag 51041); x_i = y_i/e_i; w_i = e_i^2/(S_i*max(y_i,0) + O_i), ZERO when y_i >= clip; fused = sum(w*x)/sum(w); all censored -> darkest frame's x (first minimal e)")
      , ("order", jStr "f64 end to end; sums accumulate in frame order, single left-fold from 0; expression shapes pinned in Boreal.FuseMLE")
      , ("provenance", jStr "profiles are DEVICE FACTS: iPhone 17 Pro tag 51041 per frame, 2026-07-19 cycle (incl. the dual-conversion-gain break at ISO 1250); scene x dyadic k/4096 from the house LCG, s0 = 4242; observations y = e*x noise-free (censoring engages where e*x >= clip)")
      ])
  , ("clip",     show mfClip)
  , ("ev",       jDbls mfEV)
  , ("profiles", jDbls (concat [ [s, o] | (s, o) <- mfProfiles ]))
  , ("lcgSeed",  show (4242 :: Int))
  , ("scene",    jDbls mfScene)
  , ("fused",    jDbls mfFused)
  ]

-- ── TemporalBayer fixture (TB laws — THE PIVOT's cycle statistics) ─

temporalbayerJson :: String
temporalbayerJson = jObj
  [ ("conventions", jObj
      [ ("stats", jStr "per rung bin, per channel: weighted mean mu = sum_j e_j*m_j / sum_j e_j and residual v = sum_j e_j*(m_j - mu)^2 / (J-1); channel means y-outer x-inner per cell, cells row-major, left-fold from 0; frame sums j ascending; f64 end to end (f32 mosaics widen exactly)")
      , ("gain",  jStr "ghat = UPPER MEDIAN (sort ascending, index n/2) of v/(mu/N) over bins-ascending x channels R,G,B; N_R = N_B = (k/2)^2, N_G = 2(k/2)^2, k = side/rung EVEN (whole-Bayer-period law); mu <= 0 contributes ratio 0; UNCALIBRATED constant-factor estimator (see TB2)")
      , ("d",     jStr "per bin: q1 = mR - mG, q2 = mB - mG; D = ((sum_j e_j*(q1_j - q1bar)^2)/((J-1)*(nR+nG)) + (sum_j e_j*(q2_j - q2bar)^2)/((J-1)*(nB+nG)))/2 with n_c = ghat*mu_c/N_c; V <= 0 gives D = 0; noise-only content -> D ~ 1, alias/chroma-motion -> D >> 1")
      , ("sigmaTime", jStr "seed-grid aggregation: mean of D over each (rung/seed)^2 block, row-major")
      , ("fixture", jStr "side 64 RGGB, 4 frames at EV [1,4,16,64], sub-pixel tremor shifts, shot noise var g0*scene/e_j via house LCG, EVERY sample quantized to k/4096 (exact in f32/f64/JSON); regions: x<32,y<32 gray zone plate (alias), x<32,y>=32 flat gray (quiet), x>=32 color ramp (equal slopes, constant offsets -> chroma exactly shift-invariant)")
      ])
  , ("side",    show tbSide)
  , ("cfa",     show (0 :: Int))
  , ("ceiling", show tbCeiling)
  , ("seed",    show tbSeed)
  , ("ev",      jDbls tbEV)
  , ("g0",      show tbGain0)
  , ("shifts",  jDbls (concat [ [dx, dy] | (dx, dy) <- tbShifts ]))
  , ("mosaics", jArr (map jDbls tbFrames))
  , ("muR",     jDbls (tbMuR tbFixtureStats))
  , ("muG",     jDbls (tbMuG tbFixtureStats))
  , ("muB",     jDbls (tbMuB tbFixtureStats))
  , ("ghat",    show (tbGain tbFixtureStats))
  , ("D",       jDbls (tbD tbFixtureStats))
  , ("sigmaTime", jDbls (tbSigmaTime tbFixtureStats))
  , ("medians", jObj
      [ ("zone",  show (tbMedianOf tbZoneBins (tbD tbFixtureStats)))
      , ("color", show (tbMedianOf tbColorBins (tbD tbFixtureStats)))
      ])
  ]

-- ── BinContract fixture (BC laws — THE BIN-COMMUTATION THEOREM) ────

bincontractJson :: String
bincontractJson = jObj
  [ ("conventions", jObj
      [ ("theorem", jStr "BC2: cfaBin(S/(b*r)) . beta_b == cfaBin(S/r) EXACTLY in Q at every rung whose binned cell is a whole even quad count — the ladder factors through per-phase binning; beta_b is a sufficient statistic for the model rungs")
      , ("binning", jStr "beta_b: binned[Y,X] = mean of the b^2 same-phase photosites in the aligned 2b x 2b block (phase preserved: a binned Bayer mosaic is a Bayer mosaic; b=2 is quad-binned sensor readout)")
      , ("mosaic",  jStr "NOT stored — regenerate: side 64, value_k = ((s>>16) mod 4096)/4096, s0 = 24601, wrapping-u64 house LCG, k row-major (y,x); DYADIC => every f64 intermediate exact => both theorem sides compare BITWISE in the harness")
      , ("noise",   jStr "HONEST BOUNDARY: the theorem settles the SIGNAL contract only; binning drops input noise ~b^2-fold vs native-scale synth training frames — a T3 training-distribution question, not an inference-mapping question")
      ])
  , ("side",    show bcSide)
  , ("b",       show bcB)
  , ("lcgSeed", show (24601 :: Int))
  , ("binned",  jDbls (map fromRational (concat (binPhase bcB bcFixtureMosaic))))
  , ("deviceContract", jObj
      [ ("cropSide",   show (2048 :: Int))
      , ("b",          show (4 :: Int))
      , ("binnedSide", show (512 :: Int))
      , ("inSide",     show (256 :: Int))
      , ("modelRungs", jInts [16, 32, 64, 128, 256])
      , ("renderRung", show (512 :: Int))
      , ("note", jStr "phi(beta_4(crop)) = the encoder input: phase planes (CycleSet) of the 4x-binned 2048 crop; by BC2 its classic ladder at the model rungs is bit-for-bit the device ladder, and the render rung 512 is exactly the information binning drops")
      ])
  ]

main :: IO ()
main = do
  createDirectoryIfMissing True outDir
  emit "geometry.json"         geometryJson
  emit "palette_golden.json"   paletteJson
  emit "exposure_golden.json"  exposureJson
  emit "colorpath_golden.json" colorpathJson
  emit "giftarget_golden.json" giftargetJson
  emit "multiscale_golden.json" multiscaleJson
  emit "gifwire_golden.json" gifwireJson
  emit "cycleset_golden.json" cyclesetJson
  emit "binomial_golden.json" binomialJson
  emit "battle_golden.json" battleJson
  emit "walk_golden.json" walkJson
  emit "temporalbayer_golden.json" temporalbayerJson
  emit "bincontract_golden.json" bincontractJson
  emit "mlefuse_golden.json" mlefuseJson
  writeFile "../BOREAL/Kernels/SRGBTable.swift" srgbTableSwift
  putStrLn "  wrote ../BOREAL/Kernels/SRGBTable.swift (generated)"
  putStrLn "GOLDENS EMITTED"
  where emit name content = do
          let path = outDir ++ "/" ++ name
          writeFile path (content ++ "\n")
          putStrLn ("  wrote " ++ path)
