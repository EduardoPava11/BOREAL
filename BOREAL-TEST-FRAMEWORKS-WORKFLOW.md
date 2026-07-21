# BOREAL Test-Frameworks Workflow — the flow of proof

North star: **one capture (or one command) → every verdict, readable in
one place.** The repo already holds nine kinds of testing; the flow
problem is that they're invoked from five entry points and the field
artifacts (the bundles Daniel shares) require a Mac session to
interpret. This workflow categorizes what exists, then plans: a single
replay CLI, bundle v3 (the files-I-share upgrade), and the PREVIEW —
one self-contained page per capture that shows the picture and the
verdicts together.

Status: PLAN (written 2026-07-19 on Daniel's direction: "categorize
them, then make a plan to improve the logs — the files I share. I also
need a preview."). Nothing below is implemented yet except what's
marked EXISTS.

---

## 1. The taxonomy — nine frameworks, five categories

**A. SPEC LAWS (truth by property/theorem)** — EXISTS
   Haskell law suites under `spec/*/`, run by `make -C spec test`:
   geometry CS, palette bell, exposure EV+MF (MLE fuse), colorpath
   CQ+NT (the magenta law), giftarget, multiscale MS, gifwire,
   cycleset N, binomial, hierarchy H, max-signal theorem, ditherwalk
   DW, tessgrid, battle, temporalbayer TB, bincontract BC (the
   bin-commutation theorem). 18 files. Exact ℚ where possible,
   pinned-order f64 elsewhere.

**B. CANON + CROSS-LANGUAGE PARITY (truth by bit-exactness)** — EXISTS
   - Golden emitter (`spec/emit` → `fixtures/*.json`): single source.
   - Python oracle (`spec/oracle`): independent recomputation, bitwise.
   - Swift harness (`spec/verify-swift`, macOS swiftc): kernels
     bit/byte-exact + Metal GPU parity + ported self-tests.
   - BOREALTests (XCTest, iOS sim, NO app host): the same parity legs
     through Xcode's iOS toolchain + app-level pins (rotation,
     upscalePlane). Catches target-membership/bundling drift.
   - Trainer parity G-a (`nn/v1/goldens_test.py`): numpy bit-exact.
   Two precision classes, both explicit: ISP = bitwise; learned path
   (V1 engine) = tolerance vs `v1h_forward_golden`.

**C. SELF-TESTS (in-kernel vectors)** — EXISTS
   fuseSelfTest / sceneSelfTest / dngSelfTest, run by both B-harnesses.
   The weakest class (vectors, not laws) — flagged for promotion into
   A/B when touched (G7 is exactly this: EvPlan has self-test only).

**D. JUDGES + EXPERIMENTS (truth by measurement, not pass/fail)** —
   PARTIALLY EXISTS
   - `scripts/e1-crossover` (box vs HA reference) — checked in.
   - `nn/v1/battle.py` (model vs classic) — checked in.
   - THE GAP: this session produced ~8 ad-hoc scratchpad harnesses
     (bundle replay, fuse A/B, noise-envelope fit, RC chroma-rung
     experiment, portrait proof). All were rewritten from scratch each
     time and none is reproducible. This is the biggest flow leak.

**E. FIELD TELEMETRY (truth from the device)** — EXISTS (v2)
   The bundle: report.json / burst.json (fuse marker, ntSpread,
   frames[] facts, temporal block, perf + timeline), log.txt (the
   narrative), frames.bin/fractal.bin, PNGs/GIFs, single-cycle DNGs.
   Self-checks on device: NT, fuse path, rails. THE GAPS: no schema
   version, no build/device stamp, bands as ~10 MB of JSON text, no
   integrity manifest, no human-viewable summary (the preview).

## 2. The plan

### TF0 — `tools/replay`: one CLI, every Mac verdict
Promote the scratchpad harnesses into a checked-in Swift CLI compiled
against `BOREAL/Kernels` (same pattern as spec/verify-swift):

    tools/replay/main.swift, subcommands:
      verify  <bundle-dir>   bit-exact Mac replay of the device cycle
                             (decode → MLE fuse → stack → palette) vs
                             report.json; prints per-artifact verdicts
      render  <dngs…>        current-pipeline render (512 portrait PNG
                             + cycle GIF) — "what would the app show"
      noise   <dngs…>        mean-variance envelope fit vs NoiseProfile
                             tags (the §7 experiment, reproducible)
      abfuse  <dngs…>        classic vs MLE fuse deltas by decile
      e1      <dngs…>        wraps scripts/e1-crossover semantics
    Makefile: `make replay ARGS="verify ~/Downloads/BOREAL-…"`.

Exit gate: every analysis performed ad hoc this session is one
command; a fresh bundle's full Mac read (verify + render + noise) is
< 1 minute of typing.

### TF1 — Bundle v3: the files-I-share upgrade
1. **preview.html — THE PREVIEW (see §3).** One self-contained file
   per bundle, first in the share list.
2. **bands.bin**: move the stack out of report.json (Int32 LE + layout
   note, like frames.bin). report.json drops ~10 MB → ~1 MB; parsing
   and AirDrop get proportionally faster. `tools/replay verify` reads
   both formats during the transition.
3. **Provenance stamps** in report.json/burst.json: `schema: 3`,
   `build` (app version + git hash via Info.plist), `device` (model,
   OS), `capturedAt` (ISO 8601), `orientation: portrait-cw`.
4. **manifest.json**: file list + byte sizes + SHA-256 — partial
   AirDrops become detectable instead of confusing.
5. **log.txt v2**: keep the narrative; add a `META` header block
   (build/device/settings), per-cycle section markers for bursts, and
   requested-vs-delivered exposure lines (planner audit).
6. Naming: `BOREAL-YYYYMMDD-HHMMSS` directories (epoch seconds are
   unreadable in a Downloads folder full of bundles).

Exit gate: a shared bundle is self-identifying (who built it, on what,
when), integrity-checkable, half the size, and carries its own preview.

### TF2 — Close the two open gate gaps (they are test-framework gaps)
- **G4 (round-trip law)**: BOREALTests gains
  `testGIFSystemDecoderRoundTrip` — encode a fixture cycle, decode
  with ImageIO (CGImageSource), assert pixel-for-pixel equality with
  our own decode. XCTest is the natural home (ImageIO is right there).
- **G7 (EvPlan fixture)**: emit `evplan_golden.json` from the P1-P4
  mapping laws; oracle + both harness legs replay it. Promotes the
  ETTR planner from self-test (class C) to law+golden (class A/B).

### TF3 — The in-app preview gaps (registered G1/G2)
- G1: σ heat overlay toggle in GifPreviewView (σ and σ_time grids are
  already portrait-consistent; render as translucent 16×16 tint).
- G2: route the 64-burst into the preview surface (today share-only).
Device-first check applies; one surface, no new screens.

### TF4 — One command
`make test-all`: spec gate → xcodebuild test → `tools/replay verify`
against a checked-in reference bundle (a small pinned capture — the
field-telemetry regression test the repo has never had).

## 3. The preview (TF1.1, specified)

`preview.html`, generated on device into every bundle, fully
self-contained (all images base64-embedded, no network, no JS
dependencies — it must render in a Files-app tap or a Mac double-click
forever):

  HEADER   BOREAL · capturedAt · device · build · schema
  VERDICTS a traffic-light row, straight from the JSON the page
           embeds: NT (spread vs 1e-5) · fuse path · ĝ · footprint vs
           350 MB law · thermal end-state · rails summary
  HERO     cycle.gif (the product, animating, portrait)
  LADDER   rung strip 16→512 (small PNGs) + the palette 16×16 grid
  HEAT     σ and σ_time as 16×16 heat tiles beside the hero — the
           alias/motion story at a glance (this is G1's math, rendered
           in HTML first where it's cheap)
  PERF     stage table + the timeline as an inline SVG Gantt (the
           serial-decode picture that took a Python session to see,
           visible in every bundle)
  FRAMES   per-frame facts table (ISO, shutter, S/O, blExp, rails)

Cost: the PNGs already exist in the bundle; base64 adds ~35%; total
preview ≈ 1-2 MB. Implementation is string templating in
CycleReport/assembleBundle — no new dependencies.

Order: TF0 → TF1 (preview first within it) → TF2 → TF3 → TF4.
TF0/TF1 are Mac+app work available now; TF3 wants a device session;
TF2 is pure gate work, any time.
