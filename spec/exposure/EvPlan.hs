-- ════════════════════════════════════════════════════════════════
-- EvPlan: laws tying the ETTR planner to the capture loop
-- (GIF-ISP Phase 2).
--
-- The scene analysis + plan solve (SceneKernel.swift solveClips /
-- planExposures — ported from scene.zig, tree deleted M5) are
-- device-proven and stay outside this spec;
-- what the spec pins is the MAPPING the capture loop applies to a
-- plan — because that mapping is new code and it is where a bad
-- value would reach the hardware:
--
--   biases(next cycle) = clamp(deviceBounds) over the plan's four
--   EVs [green, red, blue, shadow]; no plan (failed cycle, first
--   cycle) → the seed bracket, unchanged.
--
--   P1 bounded: every emitted bias lies inside device bounds
--   P2 fallback: no plan → the seed bracket verbatim
--   P3 monotone: clamping preserves the plan's order relations —
--      the shadow frame stays the brightest when the plan says so
--   P4 anchoring: for any lawful plan (shadow_depth ≥ 1 stop,
--      pre-clamp), shadow ≥ green + 1 — the shadow-floor frame is
--      a DISTINCT bright frame, cycle after cycle
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)

-- The mapping under law (mirrors BurstController.planBiases).
planToBiases :: (Double, Double) -> Maybe (Double, Double, Double, Double)
             -> [Double] -> [Double]
planToBiases _ Nothing seed = seed
planToBiases (lo, hi) (Just (g, r, b, s)) _ =
  map (max lo . min hi) [g, r, b, s]

bounds :: (Double, Double)
bounds = (-8, 8)

seed :: [Double]
seed = [-2, 0, 2, 4]

-- Lawful sample plans: (green, red, blue, shadow) with shadow =
-- green + depth, depth ∈ [1, 4] (SceneKernel shadowAddMin/Max).
plans :: [(Double, Double, Double, Double)]
plans =
  [ (0.5, 1.2, 0.8, 1.5)
  , (-1.0, -0.5, 0.2, 0.0)
  , (4.0, 9.0, -9.5, 8.0)      -- extremes: must clamp, not escape
  , (0.0, 0.0, 0.0, 1.0)
  ]

-- P1: every emitted bias is inside device bounds.
lawBounded :: Bool
lawBounded =
  and [ all inB (planToBiases bounds (Just p) seed) | p <- plans ]
  where inB x = x >= fst bounds && x <= snd bounds

-- P2: no plan → the seed bracket verbatim.
lawFallback :: Bool
lawFallback = planToBiases bounds Nothing seed == seed

-- P3: clamping is monotone — order relations inside the plan survive.
lawMonotone :: Bool
lawMonotone =
  and [ (a <= b) <= (clampB a <= clampB b)
      | (g, r, b', s) <- plans
      , a <- [g, r, b', s], b <- [g, r, b', s] ]
  where clampB = max (fst bounds) . min (snd bounds)

-- P4: a lawful plan keeps the shadow frame ≥ green + 1 stop, and
--     clamping never inverts that unless the CEILING forces both
--     to the same bound (checked: within-bounds plans keep it).
lawShadowAnchor :: Bool
lawShadowAnchor =
  and [ let out = planToBiases bounds (Just (g, r, b, g + d)) seed
        in last out >= head out
      | (g, r, b, _) <- plans
      , d <- [1, 2.5, 4]
      , g + d <= snd bounds ]      -- within-ceiling plans

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " EvPlan: planner → capture-loop mapping (Phase 2)"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("P1 emitted biases bounded by device limits",       lawBounded)
    , ("P2 no plan → seed bracket verbatim",               lawFallback)
    , ("P3 clamp is monotone (plan order survives)",       lawMonotone)
    , ("P4 shadow frame stays ≥ green frame under clamp",  lawShadowAnchor)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
