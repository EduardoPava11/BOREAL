-- ════════════════════════════════════════════════════════════════
-- Boreal.BinContract — THE BIN-COMMUTATION THEOREM.
--
-- The question this answers (the V1 engine's open boundary): the
-- encoder was trained at in_side = 256 — phase planes of a 512²
-- mosaic — but the device captures a 2048² crop. What mapping
-- 2048 → 512 feeds the model WITHOUT train/inference skew?
--
-- Answer: per-phase box binning, and it is not an approximation.
--
-- DEFINITION (β_b, per-phase box binning). For even-side mosaic m
-- and factor b, the binned mosaic β_b(m) has side S/b and
--   β_b(m)[Y,X] = mean of the b² SAME-PHASE photosites
--                 { m[2b·⌊Y/2⌋ + 2j + (Y mod 2),
--                     2b·⌊X/2⌋ + 2i + (X mod 2)] | 0 ≤ i,j < b }.
-- β_b preserves the CFA phase (a Bayer mosaic binned is a Bayer
-- mosaic — Jin-Hirakawa's binning model; quad-binned sensor readout
-- is the hardware special case b = 2).
--
-- THEOREM BC2 (bin-commutation: the ladder factors through β_b).
-- For every rung r whose BINNED cell k' = S/(b·r) is a whole number
-- of Bayer quads (k' ≥ 2, even — the house evenness law):
--
--     cfaBin (S/(b·r)) (β_b m)  =  cfaBin (S/r) m      (exactly, in ℚ)
--
-- PROOF. Fix a rung cell and a channel c. The cell's c-sites in m
-- partition into the binned superpixels lying inside the cell (the
-- alignment is exact because k' is a whole number of binned quads:
-- 2b·⌊·/2⌋ blocks nest inside k = b·k' blocks). Every superpixel
-- aggregates exactly b² c-sites — EQUAL cardinality — so the mean
-- of superpixel means with equal weights is the mean of the union:
--     (1/n)·Σ_j ( (1/b²)·Σ_{s∈P_j} v_s ) = (1/(n·b²))·Σ_s v_s.  ∎
--
-- COROLLARY BC3 (the ladder split — why 256/512 was the right cut).
-- rungsFor(S/b) = { r ∈ rungsFor S | r ≤ S/(2b) }: at the device
-- scale (S = 2048, b = 4) the binned ladder is EXACTLY the model
-- rungs {16 … 256}, and the render rung 512 is EXACTLY the
-- information binning drops. The model/render ceiling split and the
-- input binning are the same cut, seen twice.
--
-- COROLLARY BC5 (N3 on device). cfaBin 2 (β_b m) = cfaBin 2b m: the
-- encoder's verbatim k = 2 pick-the-colors baseline over its binned
-- input IS the model-ceiling rung of the full-resolution ladder —
-- the net's input contains its classic target on device exactly as
-- in training (CycleSet N3, transported through the theorem).
--
-- COROLLARY (the input contract, prose): feeding the encoder
-- φ(β_4(crop)) — phase planes of the 4×-binned 2048 crop — gives an
-- input whose ENTIRE classic ladder at the model rungs is bit-for-
-- bit the device ladder. The model competes with the classic seed
-- on identical ground truth; there is no geometric or radiometric
-- skew to hope away. β_b is linear and 1-homogeneous (BC4), so the
-- bias-free net's exposure equivariance (N4) survives binning.
--
-- HONEST BOUNDARY (documented, not proved): the theorem covers the
-- SIGNAL contract. The NOISE contract shifts — β_4 averages 16
-- photosites, so the device input is ~16× lower-variance than
-- native-scale synth training frames. That is a training-
-- distribution question (T3: match synth noise to the POST-BIN
-- level, or augment), not an inference-mapping question; the
-- mapping itself is settled by BC2.
--
-- F64 REALIZATION. The theorem is exact in ℚ. In f64 the two sides
-- differ only by summation association; on DYADIC inputs with
-- bounded denominators (the house fixture convention) every
-- intermediate is exactly representable, so the f64 equality is
-- BITWISE — which is how the Swift gate leg checks it.
-- ════════════════════════════════════════════════════════════════

module Boreal.BinContract where

import Boreal.Exposure (Mosaic)

-- β_b: per-phase box binning (exact ℚ). Requires side divisible
-- by 2b (whole binned quads).
binPhase :: Int -> Mosaic -> Mosaic
binPhase b m =
  [ [ mean [ m !! (2 * b * (yy `div` 2) + 2 * j + yy `mod` 2)
               !! (2 * b * (xx `div` 2) + 2 * i + xx `mod` 2)
           | j <- [0 .. b - 1], i <- [0 .. b - 1] ]
    | xx <- [0 .. side `div` b - 1] ]
  | yy <- [0 .. side `div` b - 1] ]
  where side = length m
        mean xs = sum xs / fromIntegral (length xs)

-- The fixture mosaic (shared by emit + the Swift harness leg's
-- regeneration convention): side 64, DYADIC values k/4096 from the
-- house LCG — value_k = ((s ≫ 16) mod 4096)/4096, s₀ = 24601, k
-- row-major (y, x). Dyadic ⇒ every f64 intermediate on BOTH theorem
-- sides is exactly representable ⇒ the gate checks BITWISE f64
-- equality (the ℚ theorem, realized). The Integer LCG here equals
-- wrapping-u64 regeneration: bits 16..27 of a positive s depend
-- only on its low 64 bits.
bcSide :: Int
bcSide = 64

bcB :: Int
bcB = 2

bcFixtureMosaic :: Mosaic
bcFixtureMosaic = chunk
  [ fromIntegral ((s `div` 65536) `mod` 4096) / 4096
  | s <- take (bcSide * bcSide) (iterate lcg 24601 :: [Integer]) ]
  where lcg s = s * 6364136223846793005 + 1442695040888963407
        chunk [] = []
        chunk xs = take bcSide xs : chunk (drop bcSide xs)

-- Plain per-plane box reduce (for the BC1 commutation check).
boxPlane :: Int -> [[Rational]] -> [[Rational]]
boxPlane b p =
  [ [ mean [ p !! (y * b + j) !! (x * b + i)
           | j <- [0 .. b - 1], i <- [0 .. b - 1] ]
    | x <- [0 .. side `div` b - 1] ]
  | y <- [0 .. side `div` b - 1] ]
  where side = length p
        mean xs = sum xs / fromIntegral (length xs)
