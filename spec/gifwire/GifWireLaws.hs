-- ════════════════════════════════════════════════════════════════
-- GifWireLaws: the wire format laws (GIF-ISP Phase 4).
--
--   W1 magic "GIF89a" and trailer 0x3B
--   W2 the byte-length closed form (frame and whole file) — the
--      fixed-9-bit scheme's size is PREDICTABLE, no compression
--      variance
--   W3 round trip: decode(encode frames) recovers every frame and
--      the delay — across the 254-code re-CLEAR boundary
--   W4 the GCT embeds the palette verbatim
--   W5 the NETSCAPE2.0 infinite-loop extension is present
--
-- Fixture frames: frame 0 is [0..255] — the A2 identity frame (the
-- seed 16×16 rendered as itself); frame 1 is LCG noise.
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Data.Word (Word8)
import Boreal.ColorPath (quantizeLab)
import Boreal.GifTarget (srgb8FromOklabQ16)
import Boreal.GifWire
import Boreal.Palette (bellPalette)

side :: Int
side = 16

delayCs :: Int
delayCs = 20

gct :: [Word8]
gct = concat
  [ [r, g, b]
  | i <- [0 .. 255]
  , let (r, g, b) = srgb8FromOklabQ16 (quantizeLab (bellPalette i)) ]

frames :: [[Word8]]
frames = [identityFrame, noiseFrame]
  where
    identityFrame = map fromIntegral [0 .. 255 :: Int]
    noiseFrame =
      [ fromIntegral ((s `div` 65536) `mod` 256)
      | s <- take 256 (iterate lcg 41) ]
    lcg s = s * 6364136223846793005 + 1442695040888963407 :: Integer

gif :: [Word8]
gif = encodeGif side delayCs gct frames

-- W1
lawMagicTrailer :: Bool
lawMagicTrailer =
  take 6 gif == map (fromIntegral . fromEnum) "GIF89a"
    && last gif == 0x3B

-- W2: frame data length and whole-file length, closed form.
lawLength :: Bool
lawLength =
  length (frameData (head frames)) == frameDataLen (side * side)
    && length gif
         == 6 + 7 + 768 + 19
              + length frames * (8 + 10 + frameDataLen (side * side))
              + 1

-- W3: true inverse, including across the re-CLEAR boundary
--     (256 pixels > 254-code group).
lawRoundTrip :: Bool
lawRoundTrip =
  decodedFrames == frames && decodedDelay == delayCs
  where (decodedDelay, _, decodedFrames) = decodeGif gif

-- W4: the GCT is the palette, verbatim.
lawGctVerbatim :: Bool
lawGctVerbatim =
  gctOut == gct
  where (_, gctOut, _) = decodeGif gif

-- W5: infinite loop declared.
lawNetscape :: Bool
lawNetscape = isInfixOfW (map (fromIntegral . fromEnum) "NETSCAPE2.0") gif
  where
    isInfixOfW needle hay =
      any (\i -> take (length needle) (drop i hay) == needle)
          [0 .. length hay - length needle]

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " GifWire: GIF89a bytes — deterministic, predictable, looped"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("W1 magic GIF89a + trailer 0x3B",                  lawMagicTrailer)
    , ("W2 byte-length closed form (frame + file)",        lawLength)
    , ("W3 decode ∘ encode == id (across re-CLEAR)",      lawRoundTrip)
    , ("W4 GCT embeds the palette verbatim",               lawGctVerbatim)
    , ("W5 NETSCAPE2.0 infinite loop present",             lawNetscape)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
