-- ════════════════════════════════════════════════════════════════
-- GifIndex: laws for the GIF target — palette from the seed 16×16,
-- integer index maps, and the display path back to sRGB bytes.
--
--   G1 A2-bijection, operational: with the (injective, quantized)
--      seed palette, indexing the seed against itself is the
--      IDENTITY permutation — the 16×16 IS its own index map
--   G2 tie-break: duplicate palette entries resolve to the LOWEST
--      index (strict-less argmin)
--   G3 optimality: the chosen index is never beaten by any other
--      palette entry (LCG-probed)
--   G4 inverse consistency: sRGB → OKLab → sRGB round-trips within
--      1e-6 (validates Ottosson's inverse literals vs the forward)
--   G5 encode table: 4096 entries, monotone, anchors 0 → 0 and
--      1 → 255
--   G6 display anchors: quantized white lands at (255,255,255)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Word (Word8)
import Boreal.ColorPath (Lab (..), oklabFromLinearSRGB, quantizeLab)
import Boreal.GifTarget
import Boreal.Palette (cellsAll, palette)

-- The quantized seed palette: 256 Q16 OKLab triples, index = v·16+u.
seedQ16 :: [Q16Lab]
seedQ16 = [ quantizeLab (palette p) | p <- cellsAll ]

-- Deterministic LCG probes around the palette (integer Q16 space).
lcg :: Int -> Int
lcg s = s * 6364136223846793005 + 1442695040888963407

probes :: [Q16Lab]
probes = go (take 512 (map jitter (iterate lcg 99))) seedQ16
  where
    jitter s = (s `div` 65536) `mod` 6001 - 3000
    go (dl : da : db : rest) ((l, a, b) : cs) =
      (l + dl, a + da, b + db) : go rest cs
    go _ _ = []

-- G1: indexing the seed against itself is the identity.
lawSelfIndexIdentity :: Bool
lawSelfIndexIdentity =
  injective && indexMap seedQ16 seedQ16 == [0 .. 255]
  where injective =
          and [ dist2 p q > 0
              | (i, p) <- zip [0 :: Int ..] seedQ16
              , (j, q) <- zip [0 ..] seedQ16, i < j ]

-- G2: duplicates resolve to the lowest index.
lawTieLowest :: Bool
lawTieLowest =
  nearestIndex (c : c : c : drop 3 seedQ16) c == 0
  where c = head seedQ16

-- G3: the chosen entry is never beaten.
lawOptimal :: Bool
lawOptimal =
  and [ let best = nearestIndex seedQ16 p
        in all (\q -> dist2 (seedQ16 !! best) p <= dist2 q p) seedQ16
      | p <- take 64 probes ]

-- G4: forward ∘ inverse ≈ id on in-gamut colors.
lawInverseConsistency :: Bool
lawInverseConsistency =
  and [ let lab = oklabFromLinearSRGB r g b
            (r', g', b') = linearSrgbFromOklab lab
        in abs (r - r') < 1.0e-6 && abs (g - g') < 1.0e-6 && abs (b - b') < 1.0e-6
      | (r, g, b) <- [ (1, 1, 1), (0, 0, 0), (0.5, 0.25, 0.75)
                     , (0.9, 0.1, 0.2), (0.01, 0.99, 0.5) ] ]

-- G5: table shape, monotonicity, anchors.
lawTable :: Bool
lawTable =
  length srgbTable == 4096
    && head srgbTable == 0
    && last srgbTable == 255
    && and (zipWith (<=) srgbTable (drop 1 srgbTable))
    && srgb8FromLinear 0 == 0
    && srgb8FromLinear 1 == 255

-- G6: quantized white displays as pure white.
lawWhiteAnchor :: Bool
lawWhiteAnchor =
  rgb8 == (255, 255, 255)
  where rgb8 = srgb8FromOklabQ16 (quantizeLab (oklabFromLinearSRGB 1 1 1))

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " GifIndex: seed palette, index maps, display path"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("G1 seed self-indexing = identity (A2, operational)", lawSelfIndexIdentity)
    , ("G2 ties resolve to the lowest index",                lawTieLowest)
    , ("G3 argmin never beaten (LCG probes)",                lawOptimal)
    , ("G4 sRGB→OKLab→sRGB round-trip < 1e-6",              lawInverseConsistency)
    , ("G5 encode table: 4096, monotone, 0→0, 1→255",       lawTable)
    , ("G6 quantized white → (255,255,255)",                 lawWhiteAnchor)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b

-- silence -W unused warning for Word8 import used only in types
_unusedW8 :: Word8
_unusedW8 = 0
