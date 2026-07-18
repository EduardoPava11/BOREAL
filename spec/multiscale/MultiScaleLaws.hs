-- ════════════════════════════════════════════════════════════════
-- MultiScaleLaws: the custom ISP's law set (GIF-ISP Phase 3).
--
--   MS1 round trip: decode(encode(rungs)) recovers EVERY rung
--       exactly — the residual stack loses nothing
--   MS2 accounting: the prefix through rung r is Σ r'² for r' ≤ r
--       (256, 1280, 5376 on the 128² fixture) — every prefix is a
--       rung, in the overcomplete layout's closed form
--   MS3 prefix decodes to THE RUNG-r DEMOSAIC — not a resize of a
--       finer image (supersedes EP3's floor-mean meaning for the
--       latent; the S-transform pyramid remains a valid kernel)
--   MS4a LINEAR nesting is EXACT (ℚ): a parent cfaBin cell equals
--       the mean of its four children — cfaBin telescopes
--   MS4b OKLab nesting is NOT exact but BOUNDED: the residual DC
--       per quad (cbrt's Jensen gap) stays inside a loose envelope
--       even on worst-case noise (regression pin; natural images
--       sit far inside it)
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.Exposure (CellRGB (..))
import Boreal.MultiScale

-- Identity color matrix: the has_color = false path.
ident :: [[Double]]
ident = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]

side :: Int
side = 128                     -- rungs {16, 32, 64}; k = {8, 4, 2}

mosaic :: [[Rational]]
mosaic = mkMosaicUnit 7 side

stack :: [(Int, ([Int], [Int], [Int]))]
stack = rungStack ident side mosaic

rungsHere :: [Int]
rungsHere = map fst stack

chanL :: [(Int, [Int])]
chanL = [ (r, l) | (r, (l, _, _)) <- stack ]

bandsL :: [Int]
bandsL = encodeMS chanL

-- MS1: decode recovers every rung, every channel.
lawRoundTrip :: Bool
lawRoundTrip =
  and [ decodeRung rungsHere (encodeMS ch) r == img
      | pick <- [ \(l, _, _) -> l, \(_, a, _) -> a, \(_, _, b) -> b ]
      , let ch = [ (r, pick planes) | (r, planes) <- stack ]
      , (r, img) <- ch ]

-- MS2: the layout's closed form.
lawAccounting :: Bool
lawAccounting =
  [ prefixLen rungsHere r | r <- rungsHere ] == [256, 1280, 5376]
    && length bandsL == 5376
    && rungsFor 512 == [16, 32, 64, 128, 256]
    && prefixLen (rungsFor 512) 256 == 87296

-- MS3: the prefix decodes to the independently computed rung
--      demosaic (decode path vs direct path).
lawPrefixIsRungDemosaic :: Bool
lawPrefixIsRungDemosaic =
  and [ decodeRung rungsHere bandsL r == l
      | (r, (l, _, _)) <- stack ]

-- MS4a: cfaBin telescopes EXACTLY in linear light (ℚ).
lawLinearNesting :: Bool
lawLinearNesting =
  and [ parent == meanOf4 children
      | let coarse = rungLinear side 16 mosaic
      , let fine   = rungLinear side 32 mosaic
      , (py, prow) <- zip [0 ..] coarse
      , (px, parent) <- zip [0 :: Int ..] prow
      , let children = [ fine !! (2 * py + dy) !! (2 * px + dx)
                       | dy <- [0, 1], dx <- [0, 1] ] ]
  where meanOf4 cs = scale (sum4 cs)
        sum4 = foldr1 (\(CellRGB a b c) (CellRGB d e f) ->
                         CellRGB (a + d) (b + e) (c + f))
        scale (CellRGB a b c) = CellRGB (a / 4) (b / 4) (c / 4)

-- MS4b: the OKLab residual DC per quad stays inside the envelope
--       (32768 Q16 = 0.5 — loose on purpose: uncorrelated noise is
--       the worst case for cbrt's Jensen gap; a natural image sits
--       far inside).  Regression pin, not a theorem.
lawOklabEnvelope :: Bool
lawOklabEnvelope =
  and [ abs dc <= 4 * 32768
      | (rPrev, prev) <- chanL
      , (r, img) <- chanL
      , r == 2 * rPrev
      , let up = upsample2 rPrev prev
      , let det = zipWith (-) img up
      , quad <- quadsOf r det
      , let dc = sum quad ]        -- 4·dc-bound: sum of a 2×2 quad
  where
    quadsOf r det =
      [ [ det !! ((2 * qy + dy) * r + (2 * qx + dx))
        | dy <- [0, 1], dx <- [0, 1] ]
      | qy <- [0 .. r `div` 2 - 1], qx <- [0 .. r `div` 2 - 1] ]

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " MultiScale: demosaic at every scale — the custom ISP"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("MS1 residual stack round-trips every rung exactly",   lawRoundTrip)
    , ("MS2 prefix layout: Σ r'² closed form (…87296 at 512)", lawAccounting)
    , ("MS3 prefix decodes to THE rung-r demosaic",           lawPrefixIsRungDemosaic)
    , ("MS4a linear nesting exact: cfaBin telescopes (ℚ)",    lawLinearNesting)
    , ("MS4b OKLab residual DC inside the noise envelope",    lawOklabEnvelope)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
