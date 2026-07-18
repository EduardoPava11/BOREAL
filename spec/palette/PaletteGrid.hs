-- ════════════════════════════════════════════════════════════════
-- PaletteGrid: 256 = 16×16, grid position ≡ palette color,
-- with a Kohonen-SOM topology so dithering is free in latent space
--
--   L1 home-centering   the spatial distribution of index p is
--                       centered at cell p (palette IS layout)
--   L2 neighbor-Lipschitz  ΔE between grid-adjacent colors ≤ K
--   L3 dither-locality  dithering = small VECTOR DISPLACEMENT in
--                       grid coordinates; ΔE cost ≤ K·(path len)
--
-- Color space: OKLab.  Palette + conversion live in Boreal.Palette
-- (shared with the emitter).  The dither-law render here runs at
-- 64² (4×4 px per cell) — a law apparatus resolution, independent
-- of the pyramid's 256² ceiling.
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.ColorPath (quantizeLab)
import Boreal.Geometry (gridSide)
import Boreal.GifTarget (indexMap)
import Boreal.Palette

-- ── Rendering: index fields and displacement dither ────────────

renderSide :: Int
renderSide = 64                            -- law render; 4×4 px per cell

pxPerCell :: Int
pxPerCell = renderSide `div` gridSide

-- Home render: every pixel of cell p carries index p.
homeIndex :: (Int, Int) -> Cell
homeIndex (x, y) = (x `div` pxPerCell, y `div` pxPerCell)

clampCell :: Cell -> Cell
clampCell (u, v) = (c u, c v)
  where c t = max 0 (min (gridSide - 1) t)

-- Deterministic LCG displacements bounded by radius r (Chebyshev).
lcg :: Int -> Int
lcg s = s * 6364136223846793005 + 1442695040888963407

displacements :: Int -> Int -> [(Int, Int)]
displacements seed r =
  pair (map toD (iterate lcg seed))
  where toD s = (abs s `div` 65536) `mod` (2 * r + 1) - r
        pair (a : b : rest) = (a, b) : pair rest
        pair _              = []

ditherIndex :: Int -> Int -> (Int, Int) -> Cell
ditherIndex seed r (x, y) =
  let (du, dv) = head (displacements (seed + 977 * y + x) r)
      (u, v)   = homeIndex (x, y)
  in clampCell (u + du, v + dv)

pixels :: [(Int, Int)]
pixels = [ (x, y) | y <- [0 .. renderSide - 1], x <- [0 .. renderSide - 1] ]

-- Centroid (in CELL units) of the pixels carrying index p.
centroid :: ((Int, Int) -> Cell) -> Cell -> Maybe (Double, Double)
centroid field p =
  case [ (x, y) | (x, y) <- pixels, field (x, y) == p ] of
    [] -> Nothing
    ps -> Just ( mean [ (fromIntegral x + 0.5) / fromIntegral pxPerCell | (x, _) <- ps ]
               , mean [ (fromIntegral y + 0.5) / fromIntegral pxPerCell | (_, y) <- ps ] )
  where mean xs = sum xs / fromIntegral (length xs)

homeCenter :: Cell -> (Double, Double)
homeCenter (u, v) = (fromIntegral u + 0.5, fromIntegral v + 0.5)

-- ── Laws ───────────────────────────────────────────────────────

-- L2 first (L1/L3 lean on it conceptually): grid neighbors are
-- perceptual neighbors, and the palette is injective.
lawNeighborLipschitz :: Bool
lawNeighborLipschitz = allEdgesBounded && injective
  where allEdgesBounded =
          and [ deltaE (palette p) (palette q) <= kNeighbor
              | p@(u, v) <- cellsAll
              , q <- [(u + 1, v), (u, v + 1)]
              , inGrid q ]
        inGrid (u, v) = u < gridSide && v < gridSide
        injective =
          and [ deltaE (palette p) (palette q) > 1.0e-6
              | p <- cellsAll, q <- cellsAll, p < q ]

-- L1: home render centers every index EXACTLY at its cell.  Under
-- radius-r dither, every OCCURRENCE of index p lies within
-- Chebyshev r of cell p (exact), so every present centroid lies
-- within r + ½ of home (the ½ is pixel-granularity slack — a
-- sparse index can sit at a neighboring cell's far edge).
lawHomeCentering :: Bool
lawHomeCentering = exactAtHome && occurrencesBounded && centroidBounded
  where exactAtHome =
          and [ centroid homeIndex p == Just (homeCenter p) | p <- cellsAll ]
        r = 1
        field = ditherIndex 42 r
        occurrencesBounded =
          and [ let (u, v)   = field (x, y)
                    (hu, hv) = homeIndex (x, y)
                in max (abs (u - hu)) (abs (v - hv)) <= r
              | (x, y) <- pixels ]
        centroidBounded =
          and [ case centroid field p of
                  Nothing       -> True          -- index unused: vacuous
                  Just (cx, cy) ->
                    let (hx, hy) = homeCenter p
                    in max (abs (cx - hx)) (abs (cy - hy))
                         <= fromIntegral r + 0.5 + 1.0e-9
              | p <- cellsAll ]

-- L3: displacement dither is perceptually bounded — for any
-- displacement d with |d|∞ ≤ 2, ΔE(home, displaced) ≤ K·(|du|+|dv|)
-- (triangle inequality along a grid path of unit steps).
lawDitherLocality :: Bool
lawDitherLocality =
  and [ deltaE (palette p) (palette q)
          <= kNeighbor * fromIntegral (abs du + abs dv) + 1.0e-9
      | p@(u, v) <- cellsAll
      , du <- [-2 .. 2], dv <- [-2 .. 2]
      , let q = (u + du, v + dv)
      , inGrid q ]
  where inGrid (a, b) = a >= 0 && a < gridSide && b >= 0 && b < gridSide

-- ── Bell-allocation laws (the 256² luminance requirement) ──────

-- B1: the bell shape is exact — Σ = 256, symmetric, the sequence.
lawBellShape :: Bool
lawBellShape =
  bellCounts == [1, 1, 2, 4, 8, 16, 32, 64, 64, 32, 16, 8, 4, 2, 1, 1]
    && sum bellCounts == 256
    && bellCounts == reverse bellCounts

-- B2: the ends are EXACT black and EXACT white — through Q16 too.
lawBellAnchors :: Bool
lawBellAnchors =
  labL (bellPalette 0) == 0 && labA (bellPalette 0) == 0
    && labL (bellPalette 255) == 1 && labB (bellPalette 255) == 0
    && quantizeLab (bellPalette 0) == (0, 0, 0)
    && quantizeLab (bellPalette 255) == (65536, 0, 0)

-- B3: luminance is monotone in index, and every interior color
--     lies inside its own stratum's band [k/16, (k+1)/16).
lawBellStrata :: Bool
lawBellStrata = monotone && owned
  where ls = [ labL (bellPalette i) | i <- [0 .. 255] ]
        monotone = and (zipWith (<=) ls (drop 1 ls))
        owned = and
          [ let (k, _, _) = bellStratum i
                l = labL (bellPalette i)
            in l >= fromIntegral k / 16 && l < fromIntegral (k + 1) / 16
          | i <- [1 .. 254] ]

-- B4: the bell seed is injective and self-indexes as the identity
--     (A2 survives the bell allocation).
lawBellIdentity :: Bool
lawBellIdentity =
  injective && indexMap q16 q16 == [0 .. 255]
  where q16 = [ quantizeLab (bellPalette i) | i <- [0 .. 255] ]
        injective = and [ p /= q
                        | (i, p) <- zip [0 :: Int ..] q16
                        , (j, q) <- zip [0 ..] q16, i < j ]

-- Sanity: the OKLab reference is anchored — white is (1,0,0) and
-- gray is achromatic (golden values for ports to pin).
lawOklabAnchors :: Bool
lawOklabAnchors = whiteOK && grayOK
  where Lab lw aw bw = oklabFromLinearSRGB 1 1 1
        whiteOK = abs (lw - 1) < 5.0e-4 && abs aw < 5.0e-4 && abs bw < 5.0e-4
        Lab _ ag bg = oklabFromLinearSRGB 0.5 0.5 0.5
        grayOK  = abs ag < 5.0e-4 && abs bg < 5.0e-4

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " PaletteGrid: 16×16 SOM palette — home, Lipschitz, dither"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("L2 neighbor-Lipschitz (ΔE ≤ K on edges) + injective", lawNeighborLipschitz)
    , ("L1 home-centering exact; r=1 dither stays within r",  lawHomeCentering)
    , ("L3 dither-locality: ΔE ≤ K·(|du|+|dv|), |d|∞ ≤ 2",   lawDitherLocality)
    , ("B1 bell shape: the sequence, Σ = 256, symmetric",     lawBellShape)
    , ("B2 bell ends exact black/white, through Q16",          lawBellAnchors)
    , ("B3 L monotone; every color owns its stratum band",     lawBellStrata)
    , ("B4 bell seed injective; self-indexing = identity",     lawBellIdentity)
    , ("OKLab anchors: white → (1,0,0), gray achromatic",     lawOklabAnchors)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
