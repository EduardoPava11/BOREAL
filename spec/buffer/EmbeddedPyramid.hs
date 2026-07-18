-- ════════════════════════════════════════════════════════════════
-- EmbeddedPyramid: the latent buffer where 16×16 is a PREFIX
--
-- Per frame the ceiling-rung image (256², one channel shown; L, a,
-- b each get their own pyramid) is stored as integer S-transform
-- coefficient bands:
--
--   [ 16² mean | 16→32 det | 32→64 det | 64→128 det | 128→256 det ]
--      = latent  ←———————————— back-trace fuel ————————————→
--
-- The S-transform pair is a BIJECTION on ℤ², so the bands ARE the
-- image, reorganized.  Back-trace 16→32→64→128→256 is exact
-- inverse transform — reading deeper into the same buffer.
-- Kernels live in Boreal.Pyramid (shared with the emitter).
--
--   EP1 quad transform is bijective on ℤ⁴
--   EP2 analyze ∘ synthesize == id at the ceiling rung
--   EP3 prefix-decode: top band == independent floor-mean path
--   EP4 band accounting: every prefix is a rung, Σ == 256²
--   EP5 σ = 0 ⟺ block-constant at latent-cell granularity
-- ════════════════════════════════════════════════════════════════

module Main where

import System.Exit (exitFailure)
import Control.Monad (unless)
import Boreal.Geometry (gridSide, ceilingRung, rungs)
import Boreal.Pyramid

-- ── Laws ───────────────────────────────────────────────────────

ceilingSide, baseSide :: Int
ceilingSide = ceilingRung     -- 256
baseSide    = gridSide        -- 16

-- EP1: quad transform bijective (dense small cube + LCG stress).
lawQuadBijective :: Bool
lawQuadBijective = denseOK && stressOK
  where denseOK  = and [ quadI (quadF q) == q
                       | a <- rng, b <- rng, c <- rng, d <- rng
                       , let q = (a, b, c, d) ]
        rng      = [-4 .. 4]
        stressOK = and [ quadI (quadF q) == q | q <- stress ]
        stress   = [ (a, b, c, d)
                   | [a, b, c, d] <- chunksOf4 (samples 7 4000) ]
        chunksOf4 (a:b:c:d:r) = [a, b, c, d] : chunksOf4 r
        chunksOf4 _           = []

-- EP2: full round-trip is the identity — fast checks at 64², one
--      full-ceiling check at 256².
lawRoundTrip :: Bool
lawRoundTrip = all rt [(1, 64), (2, 64), (3, ceilingSide)]
  where rt (seed, side) =
          let img       = mkImage seed side
              (top, ds) = analyzeTo baseSide img
          in synthesizeFrom top ds == img

-- EP3: prefix-decode — the stored top band IS the classic
--      floor-mean coarsening, computed by an independent path.
lawPrefixDecode :: Bool
lawPrefixDecode = all pd [(11, 64), (12, 64), (13, ceilingSide)]
  where pd (seed, side) =
          let img = mkImage seed side
          in fst (analyzeTo baseSide img) == coarsenTo baseSide img

-- EP4: band accounting — coefficient counts telescope so every
--      prefix is exactly a rung: 16², 32², 64², 128², 256².
lawBandAccounting :: Bool
lawBandAccounting =
  prefixSizes == map (\r -> r * r) rungs
    && last prefixSizes == ceilingSide * ceilingSide
  where (top, ds)     = analyzeTo baseSide (mkImage 21 ceilingSide)
        detailCount d = sum (map ((* 3) . length) d)
        prefixSizes   = scanl1 (+) (count top : map detailCount ds)
        count i       = sum (map length i)

-- EP5: σ (subtree detail energy) is zero iff the image is
--      block-constant at latent-cell granularity (16×16 blocks).
lawSigmaZero :: Bool
lawSigmaZero = flatZero && perturbedNonzero
  where blockConstant = [ [ 100 * (r `div` k) + (c `div` k)
                          | c <- [0 .. ceilingSide - 1] ]
                        | r <- [0 .. ceilingSide - 1] ]
        k             = ceilingSide `div` baseSide     -- 16×16 blocks
        energy img    = let (_, ds) = analyzeTo baseSide img
                        in sum [ abs lh + abs hl + abs hh
                               | d <- ds, row <- d, (lh, hl, hh) <- row ]
        flatZero      = energy blockConstant == 0
        perturbed     = bump blockConstant
        bump (r:rs)   = zipWith (+) (1 : repeat 0) r : rs
        bump []       = []
        perturbedNonzero = energy perturbed > 0

-- ── Harness ────────────────────────────────────────────────────

main :: IO ()
main = do
  putStrLn "══════════════════════════════════════════════════════════"
  putStrLn " EmbeddedPyramid: 16² latent = prefix; back-trace = exact"
  putStrLn "══════════════════════════════════════════════════════════"
  checkAll
    [ ("EP1 S-transform quad is a bijection on ℤ⁴",           lawQuadBijective)
    , ("EP2 synthesize ∘ analyze == id (64² and 256²)",       lawRoundTrip)
    , ("EP3 prefix-decode == independent floor-mean path",     lawPrefixDecode)
    , ("EP4 prefixes telescope 16²,32²,64²,128²,256²",        lawBandAccounting)
    , ("EP5 σ = 0 ⟺ block-constant at cell granularity",     lawSigmaZero)
    ]

checkAll :: [(String, Bool)] -> IO ()
checkAll cs = do
  results <- mapM one cs
  unless (and results) exitFailure
  putStrLn "ALL LAWS GREEN"
  where one (name, b) = do
          putStrLn ((if b then "  ✓ " else "  ✗ ") ++ name)
          pure b
