-- ════════════════════════════════════════════════════════════════
-- BattleLaws: the battle, with nature as the evolution (level 1:
-- the interpretation of Bayer-structured data; trained on L).
--
--   BA1 territory conservation: any sequence of defections
--       preserves total population n — the battle redistributes,
--       never creates or destroys
--   BA2 pure-H stability: when the evidence IS the prior (fine ==
--       up(seed)), the home configuration is a fixed point — no
--       pixel has a strictly better option in its walk window
--       (ties DW4 and H4: the up-arrow's ideal is battle-stable)
--   BA3 neutrality = beauty: E[χ²] under multinomial drift is
--       EXACTLY 255 (exact ℚ) — the V1f band is the stationary
--       signature of neutral evolution, not an arbitrary target
--   BA4 the defection law: Δχ² = 512·(c_q − c_p + 1)/n, exact —
--       verified against recomputation from scratch; the walk can
--       maintain beauty incrementally in O(1) per move
--   BA5 the temporal delta round-trip: applyDelta a (frameDelta a
--       b) == b, exactly — the (x,y,t) deltas are surfaced as a
--       lossless defection list; churn is its length
--   BA6 selection is monotone: defecting toward a MORE-populated
--       option always raises χ² (monocultures cost beauty); toward
--       a strictly-less-populated one always lowers it
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.Battle
import Boreal.Binomial (chiSquare)

-- Deterministic index frames (LCG, 64² territory for speed).
lcgFrame :: Int -> Int -> [Int]
lcgFrame seed n =
  [ fromIntegral ((s `div` 65536) `mod` 256)
  | s <- take n (iterate lcg (fromIntegral seed)) ]
  where lcg s = s * 6364136223846793005 + 1442695040888963407 :: Integer

-- BA1
lawConservation :: Bool
lawConservation =
  sum (foldl step counts moves) == sum counts
  where
    counts = populations (lcgFrame 3 4096)
    moves  = [ (p, q) | p <- [0, 17, 255], q <- [4, 99, 200] ]
    step cs (p, q) = defect cs p q

-- BA2: on the pure-H frame every pixel's home is (weakly) optimal
--      within any window — here via the identity: the pure frame's
--      per-pixel choice equals home, so zero defections improve it
--      when evidence equals the prior (evidence distance 0 at home).
lawPureHStable :: Bool
lawPureHStable =
  chiSquare (populations pureH) == 0         -- pure-H is balanced
    && all (\(p, q) -> swapDeltaChi2 (populations pureH) p q > 0
                        || p == q)
           [ (p, q) | p <- [0, 7, 255], q <- [1, 8, 254], p /= q ]
  where pureH = concatMap (replicate 16) [0 .. 255]
        -- (any defection from perfect balance strictly costs beauty)

-- BA3
lawNeutralityIsBeauty :: Bool
lawNeutralityIsBeauty =
  all (\n -> neutralExpectedChi2 n == 255) [256, 4096, 65536]

-- BA4
lawDefectionClosedForm :: Bool
lawDefectionClosedForm =
  and [ let after = defect counts p q
        in chiSquare after - chiSquare counts == swapDeltaChi2 counts p q
      | (p, q) <- [ (3, 200), (0, 255), (17, 18), (99, 98) ] ]
  where counts = populations (lcgFrame 9 4096)

-- BA5
lawDeltaRoundTrip :: Bool
lawDeltaRoundTrip =
  applyDelta a (frameDelta a b) == b
    && churn a a == 0
    && churn a b == length (filter id (zipWith (/=) a b))
  where a = lcgFrame 5 4096
        b = lcgFrame 11 4096

-- BA6: from balance, moving mass toward the crowd costs beauty;
--      toward the sparse gains it — selection has a price signal.
lawSelectionMonotone :: Bool
lawSelectionMonotone =
  and [ swapDeltaChi2 skewed p q > 0
      | (p, q) <- [ (10, 0), (200, 0) ] ]        -- toward the crowd
    && and [ swapDeltaChi2 skewed 0 q < 0
           | q <- [ 10, 200 ] ]                   -- away from it
  where skewed = defect (defect (populations balanced) 1 0) 2 0
        balanced = concatMap (replicate 16) [0 .. 255]

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " Battle: nature as the evolution — level 1, on L"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("BA1 territory conserved under any defections",       lawConservation)
    , ("BA2 pure-H is battle-stable; defection costs beauty", lawPureHStable)
    , ("BA3 neutrality: E[χ²] = 255 exactly (ℚ)",            lawNeutralityIsBeauty)
    , ("BA4 defection closed form == recomputation, exact",   lawDefectionClosedForm)
    , ("BA5 (x,y,t) delta round-trip lossless; churn pinned", lawDeltaRoundTrip)
    , ("BA6 selection monotone: crowding costs, sparsity pays", lawSelectionMonotone)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
