# DNG-Pair → 16×16×8 Hylomorphic HDR — Lead-Architect Design & Build Plan

Status: PLANNING ONLY (no code). Date: 2026-06-27.
Supersedes nothing; this is the reconciled design after three competing drafts were vetted adversarially.
Scope: turn a 2-frame EV bracket of iPhone Bayer-RAW DNGs into one `16×16×8` scene-linear HDR **model tile** (+ a `16×16×3` EDR thumbnail for sanity only). This is a **training/interchange artifact**, not a viewable photo.

---

## 0. What survived vetting, what got fixed

All three drafts converged on the same skeleton and got the same kill-shots. The reconciled decisions:

| Flagged problem | Verdict | Decision in this plan |
|---|---|---|
| Metal "justified by memory" | KILL | Metal is justified by **throughput / SIMT-direction only**. Memory is solved by **mosaic-domain integer pooling** (never demosaic to f32), which fits both modes on CPU. |
| f32 cross-backend bit-exactness impossible | KILL | **No float on the GPU.** Metal does only the **integer** mosaic-domain reduction (associative/commutative → provably bit-exact vs a Zig scalar oracle). All float (color/fuse/quantize) is single-implementation Zig. |
| Hylo possibly decorative + OctF(8-ary) on a 2D tile is a type mismatch | KILL | OctF is the **wrong** functor for BOREAL's 2D tile. The earned recursion is a **QuadF (b=4) spatial pyramid 16→8→4→2→1**. `zip`/`unzip` is the one genuinely earned natural transformation. A_7 / OctF / maximin-palette belong to **SixFour's 64³ cube** and are **NOT imported**. |
| Haskell/SixFour oracle in a Haskell-free, SixFour-off-limits repo | KILL | **No Haskell, no SixFour import.** Oracle = in-Zig scalar reference vs SIMD/Metal path, plus a checked-in static golden vector. |
| `?=8` dishonest past 6 | FIX | Tile is `16×16×8` as a **fixed format**; only **6 channels carry independent data** (2×RGB), channels 7–8 are **labeled derived conveniences**. Information bound = B bracket-bits, stated explicitly. |
| Kernel.swift "zero-copy AS-IS" contradiction (Swift Array already freed/realigned) | FIX | New `bk_decode_dng_into(...)` decodes **directly into a page-aligned, GPU-shared buffer** the Swift side owns. No Swift `[UInt16]` copy on this path. Stream-and-release frame0 before frame1. |
| u32 accumulator overflow on large sensors | FIX | Bound assert `block ≤ 504` for u32 sums (iPhone 48MP block=378 is safe); document the bound; widen to u64 if the format is ever generalized. |
| CFA absolute-parity bug when crop origin is odd | FIX | Phase is forced on **absolute sensor coords**: `ox=(crop_x+off)&~1`, derive channel labels from the `cfa` enum at the absolute-even origin. Golden-test **both** RGGB and BGGR. |
| Pool-before-fuse averages clipped + unclipped photosites | FIX | Pool is **saturation-aware per-CFA**: a photosite at/over `white_level` is excluded from its channel's cell sum (count-normalized), so a half-clipped cell is not silently grayed. |
| Block-stream demosaic border-clamp seam | N/A here | We **do not demosaic** on the tile path. Color matrix is applied at the 16×16 stage (768 values), so the 2px-halo seam never arises. |
| "16×16×3 viewable HDR" overclaim | FIX | Deliverable named honestly: a Mac-side **model tile**; the `16×16×3` is a debug thumbnail only. |

---

## 1. THE DATA ANSWER (up front)

### 1.1 Pair sizes

All "pair" = two frames. f32-RGB sizer is BOREAL-proven `W·H·3·4` (= 153,280,512 @ 4224×3024). **The shipped tile path never reaches the f32-RGB column** — it is shown only to prove why mosaic-domain pooling is the right call.

| Stage | 12 MP (4224×3024) per-frame | 12 MP pair | 48 MP (8064×6048) per-frame | 48 MP pair |
|---|---:|---:|---:|---:|
| (a) DNG file | ~25 MB | ~50 MB | ~75 MB | ~150 MB |
| (b) u16 mosaic `W·H·2` | 25.5 MB | 51.1 MB | 97.5 MB | 195.1 MB |
| (c) f32 RGB demosaiced `W·H·3·4` *(not used)* | 153.3 MB | 306.6 MB | 585.3 MB | 1,170.5 MB |
| (d) centered-square **u16 mosaic** *(our working set)* | 18.1 MB (3008²) | 36.2 MB | 73.2 MB (6048²) | 146.3 MB |
| (d′) centered-square f32 RGB *(not used)* | 108.6 MB | 217.2 MB | 438.9 MB | 877.9 MB |
| (e) **final tile `16×16×8` f32** | 8,192 B | 8,192 B | 8,192 B | 8,192 B (mode-independent) |

**Peak working set on the shipped path = row (d) pair = 36 MB (12 MP) / 146 MB (48 MP).** Both fit comfortably under the ~300 MB ceiling **on CPU**, with no streaming gymnastics. The 878 MB / 1.17 GB f32 figures that previous drafts used to "force Metal" are the cost of a demosaic step we never take. **Metal therefore earns its place on throughput/architecture, not memory** (§3).

Centered square side: `side = floor(min(crop_w,crop_h)/32)·32`, centered, origin forced absolute-even.
- 12 MP: `min=3024 → side=3008` (32×94), block `188` (even), cells pool `188²=35,344` px (per channel `94²=8,836`).
- 48 MP: `min=6048 → side=6048` (32×189), block `378` (even), cells pool `378²=142,884` px (per channel `189²=35,721`).

Forcing `side` to a multiple of 32 makes `block=side/16` even, which (i) gives balanced per-cell CFA sample counts and (ii) keeps every cell origin even → uniform CFA phase. Cost vs the odd-block `189` design: ≤16 px of extra crop per side. Cheap, and it removes the alternating-parity normalization hazard entirely.

### 1.2 The chosen `?` = 8 (format), 6 of which carry data

**`? = 8` channels**, laid out per cell as:

```
[ R0, G0, B0,    // frame 0 (reference exposure) scene-linear, ProPhoto-ish, Q-fused
  R1, G1, B1,    // frame 1 (the +B EV frame) same space
  Lf,            // CH6: fused luma  — DERIVED (function of CH0..5), convenience only
  Br ]           // CH7: per-cell log2 exposure ratio / confidence — DERIVED
```

**Information justification (honest):**
- 1 EV = 1 stop = factor 2 = **exactly 1 bit**. The only *new* dynamic-range information the second frame adds is bounded by the realized bracket gap **B bits** (≈ 3 EV → 3 bits → 8 resolvable HDR levels), and only in cells where frame 0 clips highlights or hits its noise floor.
- Pooling `N` native photosites into a cell buys `0.5·log2(N)` ≈ **7.56 bits (12 MP) / 8.56 bits (48 MP)** of extra *precision on the cell mean* (sqrt-N noise averaging) — **precision, not range**.
- Therefore the **6 raw channels (2×RGB)** carry all independent signal; **CH6 (fused luma)** is a deterministic function of CH0–5 and **CH7 (log2 ratio)** is ≈ constant `B` per pair (per-cell only where clipping localizes it). Both are flagged in-format as **precomputed conveniences for the downstream model, not new depth.**
- `?=8` is the data-grounded format ceiling. `?=16` is unjustified padding; `?=64 / ?=256` are pure learned/redundant capacity and are **rejected**. `B` is **captured per pair** from EXIF `exposure_time·iso` ratio (already in `bk_mosaic_t`) and stored in the tile sidecar so downstream code knows how many of CH7's bits are real.

---

## 2. THE MODEL — the encoder as a hylomorphism

### 2.1 The pair as a product, and the ONE earned natural transformation

- **Outer product** `P = Frame0 × Frame1` in Hask, with `π1,π2` and the universal pairing `⟨frame0,frame1⟩`. The pairing is the product's **universal arrow (a morphism)**, *not* a natural transformation. Do not call it one.
- **Inner zip (earned nat-trans).** For the pixel-grid functor `f` (representable / Naperian, `f a ≅ (p→a)`), `zip_{a,b} : (f a, f b) → f (a,b)` is the **lax-monoidal structure map**, a natural transformation `(f×f) ⇒ f∘(×)`. Because `f` is Naperian, `zip` is a natural **iso**, inverse `unzip = λfab.(fmap fst fab, fmap snd fab)`. **This is the only place "natural transformation" is licensed:** the two mosaics fuse into ONE grid of paired pixels; `unzip` is the pair of fmapped projections. The naturality square commutes for any pixel-wise map (our pool/fuse are pixel-wise on cells).

### 2.2 The delta as a hylomorphism — over QuadF, not OctF

The encode is `hylo alg coalg = cata alg . ana coalg`, fused (no `Fix` tree materialized). **The branch functor is a 2D quadtree `QuadF`, not SixFour's 8-ary `OctF`** (kill-shot fix: a 16×16 plane has 4 spatial children per node, not 8; mapping OctF onto a 2D tile was an unresolved type mismatch).

```
data QuadF l a = Leaf l | Node (V4 a)        -- b = 4, spatial 2×2 subdivision
seed s        = (depth d, PairScalar)        -- the zipped (frame0,frame1) per-cell payload
coalg : s -> QuadF PairScalar s              -- split a node into a coarse DC band Σ (rank-1 sum/
                                             --   barycenter = exposure-fused mean) + 3 mean-free
                                             --   detail children in ker Σ  (the 2D analogue of A_7)
ana coalg  : s -> Fix (QuadF PairScalar)     -- UNFOLD the depth-d pyramid 1→2²→4²→8²→16²
cata alg   : Fix (QuadF PairScalar) -> Tile  -- FOLD to the committed 16×16×8 tile
```

- **`ana` (anamorphism) — EARNED:** unfolds the spatial detail pyramid `16→8→4→2→1` of the zipped delta. `coalg` is the saturation-aware per-CFA **pool + Σ-fuse**: at each level it produces a coarse DC (the exposure-fused barycenter over the 4 children) plus 3 mean-free detail residuals living in `ker Σ`.
- **`cata` (catamorphism) — EARNED, and NOT the identity:** folds the pyramid back into the 16×16 grid while applying the per-cell `cam_to_pp` color matrix (768 values), the Q-quant ingest, and writing the 8 channels. Critic check: `alg ≠ coalg⁻¹` because `cata` does real work the `ana` did not (color transform + quantize + channel assembly + saturation-count normalization). So the hylo is **not** a decorative reshape; if it ever degenerates to `build∘flatten = id` it fails the golden in §5.
- **`hylo` — EARNED:** `cata alg . ana coalg` fused; the `Fix` pyramid is never allocated (the pool runs as a direct strided reduction). Direction is **ana-then-cata**. Do **not** call this a *metamorphism* (that is the reverse cata-then-ana = capture→reconstruct, deliberately not part of this encoder).

**Unearned jargon explicitly rejected:** `OctF`/`V8`/`A_7`/`RootLatticeDetail`/`OctreeGenome.palette`/`lawOctantBuildFlattenIsHylo` (all SixFour 64³ constructs — off-limits and a dimensional mismatch); "metamorphism"; calling `⟨frame0,frame1⟩` a natural transformation. Only `zip/unzip` (nat-iso), `ana`, `cata`, `hylo`, `coalg`/`alg`, and `QuadF`/`ker Σ` are licensed here.

### 2.3 "Maximum color dithering conjunction" — defined computably

The phrase was marketing in two of three drafts. Operationalized definition (and an honest demotion):

BOREAL's tile is **continuous f32 HDR**, not a 256-entry palette, so SixFour's *farthest-point maximin palette commit* does **not** transfer. The computable objective that actually maximizes carried color information across the bracket is the **saturation-aware max-distinct-level fuse**, defined per cell per channel `c`:

```
levels(c) = number of distinct quantized values resolvable in channel c of the cell
fuse rule: for each cell, each CFA channel c:
   S0 = sum of frame0 photosites of channel c that are UNclipped (value < white_level)
   S1 = sum of frame1 photosites of channel c that are UNclipped, rescaled by 2^-B
   pick the source with the larger UNclipped count (more resolvable levels);
   if both partial, blend by unclipped-count weight (count-normalized mean).
objective J = Σ_cells Σ_c log2(levels_after_fuse(c))   -- maximize total resolvable color levels
```

This **maximizes the joint distinct-color content** of the tile (the honest reading of "maximum color dithering conjunction") and is exactly the data-justified `B`-bit gain: where frame 0 clips, the darker frame 1 restores distinct levels; where frame 1 is in noise, frame 0 dominates. It is computable, has a scalar reference, and is golden-testable.

> Note: `J` is a **selection/weighting objective inside `coalg`'s Σ-fuse**, not a search. There is no learned optimizer on the device path. "conjunction" and "maximum" are descriptive; the operational quantity is `J` = total resolvable color levels under the saturation-aware fuse. If a stricter k-center *dispersion* (maximin OKLab) palette is ever wanted, it lives downstream on the Mac over many tiles — out of scope for the kernel.

---

## 3. SWIFT + METAL SIMT CAPTURE + SQUARE CROP

### 3.1 Capture — 2-frame Bayer-RAW bracket (reuse the proven FSM)

Reuse `BOREAL/Capture/Camera.swift` `CameraController` **as-is** except:
- `biases` EV array `[-2,0,2,4]` (4) → **`[0, B]`** (2), where `B` is the chosen bracket gap (start `B=3`).
- `expected = 4` → `expected = 2`.
- Keep the `maxBracketedCapturePhotoCount >= 2` guard (already at `Camera.swift:155`), `isBayerRAWPixelFormat`, `photoQualityPrioritization = .speed` (mandatory for Bayer RAW), `isAppleProRAWEnabled = false`, continuation-based per-frame collection in `didFinishProcessingPhoto`.
- Returns `[Data]` in capture order (frame0 = reference EV 0, frame1 = +B). **Camera = compile-check-only** (sim has no camera) per the BOREAL rule.

`CameraHomeView.shoot()/onCapture` and any `frames[0..3]` hardwiring in `Kernel.swift fuse` must generalize `[4]→[2]`.

### 3.2 Decode — reuse `dng.zig`, but decode straight into GPU-shared memory

Kill-shot fix (no Swift `[UInt16]` copy, no double-buffering blow-up):

New thin export, sibling of `bk_decode_dng_to_mosaic`:
```
// Zig (root.zig) — decode directly into caller-owned, page-aligned, MTLBuffer-shared storage.
export fn bk_decode_dng_into(
    bytes: [*]const u8, len: usize,
    out_samples: [*]u16,            // caller-allocated, width*height u16 (page-aligned MTLBuffer.contents)
    out_meta: *MosaicMeta           // width,height,cfa,black,white,crop_*,wb,exif (NO samples ptr)
) c_int;
// Caller must size out_samples via a first metadata-only probe, or allocate worst-case (48MP).
```
Swift flow (stream-and-release, peak = 2 × square u16 = 146 MB @ 48 MP):
1. probe meta → allocate `MTLBuffer` of `W·H·2` (`.storageModeShared`) for frame0.
2. `bk_decode_dng_into(dng0, …, buf0.contents, &meta0)`.
3. probe/alloc `buf1`, decode frame1.
4. dispatch the pool kernel reading `buf0,buf1` → `sums` buffer.
5. release `buf0,buf1`.

`Kernel.swift decodeDNG()` (the `Array(UnsafeBufferPointer)` + `bk_free_mosaic` facade) is **retained for the non-Metal / debug path** but is **not** on the tile path (that was the contradiction). The tile path uses `bk_decode_dng_into`.

### 3.3 The Metal compute kernel — integer mosaic-domain centered-square pool+zip

**Why Metal at all (honest):** not memory (CPU already fits). Reasons: (1) throughput on the SIMT pool of up to 2×48 MP photosites, (2) the project's stated SIMT direction, (3) it is the *one* stage that is embarrassingly parallel AND integer-only, so it is the *only* float-free stage where a GPU result can be made **provably bit-exact** vs a Zig oracle. Every reason that is *not* about parallel integer reduction stays on CPU.

**Boundary rule:** Metal does **only** the integer reduction (CFA-channel sums + unclipped counts, both frames, one dispatch). It outputs integers. **All float** (rescale-by-2^-B, color matrix, fuse `J`, Q-quant, channel assembly, hylo `cata`) happens afterward in single-implementation Zig.

Kernel signature (sketch):
```metal
// One threadgroup per 16×16 OUTPUT CELL  -> grid = (16,16,1) threadgroups.
// Threads in group cooperatively reduce a block×block region of BOTH frames.
kernel void pool_square_zip(
    device const ushort* mosaic0   [[buffer(0)]],  // frame0 u16, full sensor, row-major
    device const ushort* mosaic1   [[buffer(1)]],  // frame1 u16
    constant PoolParams& P         [[buffer(2)]],  // width, ox, oy, side, block, cfa, white_level
    device uint*  outSums          [[buffer(3)]],  // [16*16 * 8]  (R,Gr,Gb,B)×2 frames, u32
    device uint*  outCounts        [[buffer(4)]],  // [16*16 * 8]  unclipped photosite counts
    uint2 cell  [[threadgroup_position_in_grid]],
    uint2 lid   [[thread_position_in_threadgroup]],
    uint2 ldim  [[threads_per_threadgroup]])
{
    // absolute, CFA-phase-locked block origin:
    uint bx = P.ox + cell.x * P.block;          // P.ox = (crop_x + (crop_w-side)/2) & ~1  (absolute even)
    uint by = P.oy + cell.y * P.block;          // P.oy likewise even
    // local partials, one per CFA channel, per frame:
    uint partial[8] = {0}, pcount[8] = {0};
    for (uint y = lid.y; y < P.block; y += ldim.y)
      for (uint x = lid.x; x < P.block; x += ldim.x) {
        uint chan = cfa_channel(P.cfa, (bx+x)&1, (by+y)&1);   // R/Gr/Gb/B from ABSOLUTE parity + cfa enum
        ushort v0 = mosaic0[(by+y)*P.width + (bx+x)];
        ushort v1 = mosaic1[(by+y)*P.width + (bx+x)];
        if (v0 < P.white_level) { partial[chan]   += v0; pcount[chan]   += 1; }
        if (v1 < P.white_level) { partial[chan+4] += v1; pcount[chan+4] += 1; }
      }
    // threadgroup reduction of partial[]/pcount[] (simd_sum + threadgroup memory),
    // thread 0 writes outSums[cellIdx*8 + k], outCounts[...] .
}
```
- **Bit-exactness:** `uint` (u32) add is associative & commutative and has no rounding, so any threadgroup/simd reduction order equals a serial Zig loop. The pool is verifiable against a Zig scalar oracle. **No float touches the GPU.**
- **Overflow bound (FIX):** max channel sum = `(block/2)² · (white_level-1)`. 48 MP: `189² · 16382 = 5.85e8 < 2³²`. Safe. **Assert `block ≤ 504`** (`side ≤ 8064`) at dispatch; if the format is ever generalized past that, widen `outSums` to u64. Documented.
- **CFA absolute-parity (FIX):** `P.ox,P.oy` are forced even on **absolute** sensor coords; `cfa_channel` reads the `cfa` enum (BGGR on iPhone 17 Pro main wide → `(even,even)=B`). This is golden-tested for **both** RGGB and BGGR.
- **Saturation-aware (FIX):** clipped photosites (`>= white_level`) are excluded from sum AND count, so the later count-normalized mean never grays a half-clipped cell.

### 3.4 Ownership split (the discipline)

| Layer | Owns | Must NOT do |
|---|---|---|
| **Swift (thin facade)** | capture FSM, MTLBuffer staging, dispatch, sidecar I/O | any pixel math |
| **Metal SIMT** | the **integer** centered-square pool+zip → CFA sums + counts | any float |
| **Zig SIMD** | `dng.zig`/`ljpeg.zig` decode; the **scalar+SIMD reference pooler (oracle + non-Metal fallback)**; ALL float (2^-B rescale, `cam_to_pp` matmul, `J`-fuse, Q-quant, hylo `cata`, channel assembly); golden harness | — |

Single float implementation = the only way the byte-exact claim is honest. Metal is bit-checked against the Zig integer oracle; the float stage has exactly one implementation so there is nothing to diverge.

---

## 4. REUSE vs NEW — verdict

**Verdict: FORK / REVIVE BOREAL. Do not greenfield.** Rebuilding a 14-bit big-endian, LJPEG-tiled, BGGR DNG decoder is months of risk for zero gain; it exists, is device-proven, and matches every claim.

### Reused AS-IS (verified present)
- `zig/borealkernel/src/dng.zig` — `parse()`: full u16 mosaic + `crop_x/y/w/h` + CFA + black/white + wb + `cam_to_pp[9]` + EXIF. Decoder for **both** DNGs, zero changes. (One **addition**: the new `bk_decode_dng_into` thin export wraps this to write into caller storage — `parse()` itself untouched.)
- `zig/borealkernel/src/ljpeg.zig` — `decode()`: SOF3 `Nf=2/P=12/Pt=1` iPhone tile decoder.
- `zig/borealkernel/src/root.zig` — C-ABI `bk_decode_dng_to_mosaic`, `bk_free_mosaic`, `bk_mosaic_t` extern struct (kept for debug path).
- `zig/borealkernel/src/color.zig` — `cameraToProPhoto`, `invert3` (applied at the 16×16 stage, 768 values).
- `BOREAL/Capture/Camera.swift` — bracket FSM (only `biases`/`expected` change, §3.1).
- `BOREAL/Pipeline/Kernel.swift decodeDNG()` — retained debug-path facade.
- `bayer.zig` `sumEvenOdd` + per-CFA even/odd accumulation **idea** (pattern reused; the hardwired 2944/46/64 constants and top-left crop are NOT used).

### NEW (this project)
- `bk_decode_dng_into(...)` thin export (decode into caller/GPU-shared storage) + `MosaicMeta` struct.
- Metal `pool_square_zip` kernel + `PoolParams`.
- Zig **scalar+SIMD reference pooler** (oracle + non-Metal fallback) — same math as the Metal kernel.
- Zig **hylo encoder** (`coalg` Σ-fuse `J` + `cata` color/quant/assembly) → `16×16×8` f32 tile.
- New orchestration export `bk_pair_to_tile16(dng0,len0,dng1,len1,B,*tile)` (composes decode→pool→encode) + `bk_status` plumbing.
- Tile sidecar writer (B, mode, wb, square geometry) + `16×16×3` EDR debug thumbnail emit.

---

## 5. PHASED BUILD SEQUENCE (each phase independently verifiable)

**Verification tiers:** **SIM** = `xcodebuild` sim compile (camera = compile-check-only). **IMPORT** = run the Zig kernel / a tiny host harness on **real DNG files** off-device (the honest "Import-path run"). **DEVICE** = build+run on a real iPhone (user-driven, signing per the device memory).

### Phase 0 — Square-crop geometry + CFA hazard, pure Zig, no I/O
- Implement `centered_square(crop_x,crop_y,crop_w,crop_h) → {ox,oy,side,block}` with `side=floor(min/32)·32`, **absolute-even** `ox,oy`, `block=side/16` (even).
- Implement `cfa_channel(cfa, ax&1, ay&1)` for RGGB **and** BGGR.
- **VERIFY (IMPORT):** unit test — feed odd `crop_x` and assert the forced-even origin keeps `(ox&1,oy&1)=(0,0)` and that BGGR maps `(even,even)→B`. **This is the named square-crop CFA hazard; it is gated here first.**

### Phase 1 — FIRST STEP: Zig scalar reference pooler + the byte-exact golden
- Implement the **scalar** mosaic-domain pool (saturation-aware per-CFA sums + counts) over a centered square. No SIMD yet, no Metal.
- Build a **synthetic mosaic** generator (known constant + ramp + a deliberately half-clipped cell) and **commit a static golden** `16×16×8` integer-sums vector as test data (in-repo, no Haskell, no SixFour).
- **VERIFY (IMPORT):** scalar pool over the synthetic mosaic == committed golden, exactly. Establishes the oracle every later stage is checked against.

### Phase 2 — Zig hylo encoder (float) → `16×16×8` tile
- `coalg` Σ-fuse with the `J` objective (saturation-aware, count-normalized, 2^-B rescale from EXIF) + `cata` (`cam_to_pp` matmul, Q-quant, 8-channel assembly incl. derived CH6/CH7).
- `bk_pair_to_tile16` orchestration over `bk_decode_dng_into`.
- **VERIFY (IMPORT):** run on a **real iPhone DNG pair** off-device; check tile is finite, CH6==f(CH0..5) within tolerance, CH7≈B, and the half-clipped synthetic cell shows frame-1 recovery (J restored levels). Pin a float **tolerance** spec (this stage is single-impl Zig, so the guarantee is "one implementation," not cross-backend exactness).

### Phase 3 — Metal `pool_square_zip`, bit-checked vs the Phase-1 oracle
- Port the integer pool to Metal SIMT (threadgroup reduction). Add the `block ≤ 504` dispatch assert.
- **VERIFY (IMPORT/DEVICE):** Metal integer sums == Phase-1 Zig oracle, **byte-for-byte**, for both RGGB and BGGR synthetic mosaics and a real pair. (Integer associativity guarantees this; if it ever diverges, the kernel has a real bug.)

### Phase 4 — Capture FSM `[4]→[2]` + app wiring, SIM compile
- Edit `Camera.swift` biases→`[0,B]`, expected→2; generalize `CameraHomeView`/`Kernel.swift` fuse `[4]→[2]`; wire `bk_pair_to_tile16`; sidecar + EDR thumbnail.
- **VERIFY (SIM):** `xcodebuild` sim **compiles** (camera does nothing in sim, per rule). No runtime camera claim.

### Phase 5 — Device bring-up
- Build+run on a real iPhone 17 Pro (signing `QFTX3897B7`, `-allowProvisioningUpdates` per device memory). Capture a real bracket, produce a tile, dump sidecar + thumbnail.
- **VERIFY (DEVICE):** end-to-end pair → `16×16×8` tile on hardware; spot-check against the Phase-2 IMPORT tile from the same scene type. Confirm peak memory ≈ 146 MB (48 MP) / 36 MB (12 MP).

### Phase 6 — Hardening
- 12 MP vs 48 MP mode switch (geometry only; tile format identical). Per-channel golden for both CFA patterns landed. Document the B-capture and the overflow bound. Optional: retire the unused `bayer.zig` 2944/64 constants if nothing else references them.

---

## Appendix — explicit honesty ledger
- **`?=8` is a format; 6 channels carry data.** CH6/CH7 are derived; the sidecar records `B` so downstream knows CH7's real bit budget.
- **Byte-exact is scoped:** exact across **integer pool** (Zig oracle == Metal). The **float** encode is single-implementation (one Zig path), guaranteed by *having no second implementation*, checked to a stated tolerance — not claimed bit-exact across backends.
- **No SixFour, no Haskell, no OctF/A_7/maximin-palette** on this path (off-limits + dimensional mismatch). The earned categorical content is exactly: `zip/unzip` (nat-iso), `QuadF` ana/cata/hylo, `ker Σ` detail.
- **Metal is throughput/architecture, not memory.** Mosaic-domain integer pooling is what fits the budget; it would fit on CPU alone.
