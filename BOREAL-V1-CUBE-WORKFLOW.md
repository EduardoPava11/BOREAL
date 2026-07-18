# BOREAL V1-Cube Workflow — improve the app, model-first

STATUS: NOT SETTLED (Daniel, 2026-07-17): de-Bayer is a TILING problem.
BOREAL-TILING-INVESTIGATIONS.md (I0-I8) must resolve before the K-laws
and the cube's tiling shapes harden. I0 already found real signal:
up-tile anisotropy and fine-scale chroma aliasing in the device bundle.
The frozen/open split is listed at the end of the investigations doc.

Aligned with Daniel 2026-07-17. Target unchanged: 64 DNGs in sets of 4.
The product grows into the PIXEL CUBE:

    latent cube    16 x 16 x 16   (16 cycles x the 16x16 seed)
    product cube  256 x 256 x 256 (256 GIF frames x 256x256 pixels)
    value cube     16^3 -> 256^3  (12-bit sensor samples -> 24-bit RGB
                                   — the measurement lens; confirmed by
                                   the first device run: white = 4095)

The natural harmonic, found by putting a log-16 lens on capture ->
encoding: EVERYTHING IS 16^k AND EVERY LEVEL-UP IS SQUARING —
256^k = (16^k)^2. V1's proven (16x16)x(16x16) = 256x256 is k=2; the
cube is k=3: each latent VOXEL owns a 16x16x16 space-time sub-cube.
Time factors like space: 256 frames = 16 cycles (outer) x 16 generated
frames (inner); 64 captured exposures -> x4 temporal generation, which
"model inputs and outputs GIF frames" licenses.

THE LOG (Daniel's clarification): a LOGBOOK — instrument what the
iPhone is doing through DNG capture -> encoding, to debug and to let
the real telemetry reveal the rhythm. Not a transform; an instrument.

Priority: MODEL-FIRST. The regimen (BOREAL-TRAINING-REGIMEN-WORKFLOW)
governs training; this workflow makes the app serve it.

---

## C0 — The capture->encoding log (the instrument; build FIRST)

On-device structured telemetry for every cycle and burst, two sinks:
os.Logger (live: `log stream --predicate 'subsystem ==
"com.daniel.boreal"'`) and a `trace` section in the report/burst JSON.

Per frame:   decode ms + status, dims, black/white/cfa (12-bit and
             BGGR learnings made visible), EXIF triple.
Per cycle:   crop/fuse/msEncode/indexMap ms; EV planned vs EXIF-actual
             vs next plan (the ETTR loop observable); chi^2 ladder,
             ceiling homeShare, sigma summary; bytes produced.
Per burst:   cycle cadence (capture vs reduction overlap — the real
             harmonic rhythm), watchdog margin, thermal state, memory
             high-water, total wall time; GIF assembly ms + size.

Exit: one captured burst yields a trace that answers "what did the
phone do, stage by stage, in numbers" — the Phase-5 performance
numbers we never measured arrive as a side effect.

## C1 — Model-first: V1 to dominance, then into the app

- Run the regimen R1 -> R4 on synth + the first real bundle (already
  in hand; ceiling chi^2 20205.6 / homeShare 0.1583 are the numbers
  to beat).
- Corpus growth: the app auto-saves a report bundle per burst (C4),
  every capture becomes R5 training data with its baseline attached.
- Ship: V1 seed replaces the classic seed BEHIND the classic fallback
  (gates G-b..G-e; determinism policy unchanged — the exact substrate
  quantizes/projects/indexes/encodes).

## C2 — Cube laws (lift k=2 -> k=3; spec-first as always)

- K1: (16^3) x (16^3) = 256^3 factorization bijection (voxel (c,v,u)
  owns sub-cube (frame,y,x) — outer = cycle, inner = 16 frames).
- K2: voxel homeShare (3D) + cube chi^2: balanced usage at the cube =
  each color owns one sub-cube's VOLUME (65536 px x 16 frames / 256).
- K3: up(latent cube) == pure-H product cube (H4 lifted to 3D — the
  deterministic temporal up-arrow is frame-hold replication).
- K4: value-cube accounting: 12-bit mosaic (16^3 levels) -> Q16 OKLab
  -> 8-bit indices -> 24-bit display (256^3): the measurement cube's
  exact quantization ledger end to end.

## C3 — The 256-frame product (the cube exists before the model)

- Contract: burst GIF = 256 frames x 256^2 at 5 cs (12.8 s loop,
  ~19 MB — the closed-form length scales linearly).
- Day-one classic path: each captured frame held x4 (K3's
  deterministic inner up-arrow) — the cube ships with classic content
  immediately, lawful and boring.
- The model's temporal job (V2 door, now in-contract): each cycle's 4
  EV frames -> 16 generated frames (x4 generation, GIF -> GIF); V1's
  frozen interfaces untouched; K-laws gate the upgrade exactly as MS
  laws gated the spatial one.

## C4 — App improvements in the model's service

- Auto-bundle: every burst writes its report bundle (corpus by use).
- Preview: the cycle strip becomes a cube scrubber (frames axis) when
  C3 lands; binomial/homeShare readouts surfaced per capture.
- Capture hardening from device facts: 12-bit white levels and BGGR
  are now first-class in tests; ETTR plan vs actual visible in the
  log; signing documented.

## Order + gates

  C0 log  ->  C2 K-laws  ->  C3 classic cube  ->  C1 training to
  dominance (parallel throughout)  ->  V1 into the app  ->  temporal
  generation.

  Every step: spec gate green, device replay green on new bundles,
  laws judge / soft losses train.
