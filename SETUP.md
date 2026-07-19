# BOREAL — Setup

> SUPERSEDED (banner added 2026-07-18): the mission described below —
> `.bcube` bundles + the Looks Lab k-means editor — is TWO product
> identities old (superseded by the RGBT-HDR pivot 2026-06-16, which was
> itself retired by the GIF-ISP refocus 2026-07-17). Current product:
> capture -> GIF per `BOREAL-GIF-ISP-WORKFLOW.md`; current model program:
> `BOREAL-COREAI-TRAINING-WORKFLOW.md`. The Zig core is gone (pure
> Swift + Metal since M5). Tooling notes below (xcodegen, sim build,
> signing) largely still apply; the pipeline description does not.

iOS 26+ app. Captures 16 sets × 4 RAW DNGs (= 64 frames) on iPhone, processes each set's quartet into a per-bin LAB statistical tensor, bundles the session into a single `.bcube` file. The Looks Lab editor re-quantizes that `.bcube` into a 64-frame GIF using PCA-seeded Lloyd-Max k-means under a weighted Mahalanobis distance — every UI control is a slider weight on a pure mathematical primitive (σ, cov, ρ, χ², ‖Δ‖) from the bcube.

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Xcode | 26.2+ (iOS 26 SDK + iPhone 17 Pro simulator) | from the App Store |
| xcodegen | 2.44+ | `brew install xcodegen` |
| zig | 0.16.0+ | `brew install zig` |

> The pre-build script auto-detects zig via `command -v zig`. If you installed zig somewhere unusual, set `ZIG_PATH=/path/to/zig` before any build.

## One-command bootstrap

```sh
make setup
```

Verifies the two CLI tools are installed and regenerates `BOREAL.xcodeproj` from `project.yml`. Run this after a fresh clone or any `project.yml` edit.

## Building

```sh
make build         # Debug simulator build (no signing)
make device        # Release build for generic iOS device
```

The first build does a cold Zig compile (~5 s for the static library); subsequent builds skip the Zig pre-build phase entirely if no `.zig` files changed.

## Testing

```sh
make test          # both Zig (72) and Swift (124+) suites
make test-zig      # just the Zig kernel
make test-xcode    # just the Swift app
```

The Zig tests exercise the per-bin statistical primitives (`binomial.zig`). The Swift tests exercise the format layers (`.bvox` v4 + `.bcube` v2) and the editor pipeline (`QuantizationEngine`, `PaletteEditor`, `ReRollEngine`).

## Cleaning

```sh
make clean         # wipes zig-out/, .zig-cache/, and Xcode DerivedData
```

## Editing

| You edited… | Then run… | Why |
|---|---|---|
| any `.swift` file in `BOREAL/` | `make build` | Xcode skips the Zig phase automatically |
| any `.zig` file in `zig/borealkernel/` | `make build` | Xcode re-runs `scripts/build-zig.sh` |
| `project.yml` | `make setup` | xcodegen has to regenerate the .xcodeproj |
| `BorealKernel.h` (the C bridging header) | `make build` | Swift sees changes on the next compile |
| `scripts/zig-source-inputs.xcfilelist` | `make setup` | only when adding/removing `.zig` files |

## Architecture overview (one paragraph)

The app is built on a single mathematical pivot: the **weighted 3×3 covariance matrix Σ_w** of the session's 65,536 LAB samples (16 sets × 4 frames × 4,096 spatial bins). Each user slider in the Looks Lab is a weight `w_i ∈ [0, 1]` on one pure `.bcube` primitive (σ_L, σ_a, σ_b, cov(L,a/b/ab), ρ_L, ‖ΔLAB‖, σ̄_L, ‖Δ̄LAB‖); the weights enter Σ_w via per-bin importance `m(bin) = 1 + Σᵢ wᵢ · πᵢ(bin)`. Σ_w then drives both palette derivation (PCA-seeded Lloyd-Max k-means in LAB space) and the index assignment metric (Mahalanobis distance `d²_M = (Δ)ᵀ Σ_w⁻¹ Δ`). Same Σ_w, same metric, consistent geometry end to end. No editorial labels in the surface — every primitive is a named statistical quantity.

The 4-frame combiner (μ, med, μ_w, tr) is a per-session user choice picked in the pre-burst settings sheet. It controls how each spatial bin's 4 temporal samples reduce to a per-bin center estimator before all higher moments (σ, γ₃, γ₄, χ², covariance, motion) are computed against that center. Mean is the MLE under Gaussian noise; median resists single-frame outliers; inverse-variance weighted is Kalman-style fusion; trimmed drops the value farthest from arithmetic μ.

## Capturing a session on iPhone

1. Open BOREAL on iPhone 17 Pro.
2. Tap the capture button. The session-config sheet appears.
3. Pick the 4-frame combiner and (currently `.neutral`-only) capture profile.
4. Tap "Start burst". 64 frames capture serially (~6 seconds total on A19).
5. Phase 2 processing runs in the background; the 16-dot status row fills in as each set's `.bvox` lands on disk.
6. Once the last set finishes, the `.bcube` is bundled to `<AppSupport>/BorealSession/session-<ts>.bcube` (~5.4 MB) and a "Share .bcube" + "Open in Looks Lab" pair appears in the share card.

## Inspecting a `.bcube` from a Mac

The session bundle is AirDroppable. On the receiving Mac:

```sh
python3 scripts/categorize-bcube.py path/to/session-*.bcube
```

Emits a 12-section text report: header integrity, per-set stats, global LAB histograms, spatial shape-class map, top temporal codes, χ² distribution, cross-correlations, fast covariance heatmap, slow block stats, fast-vs-slow motion comparison, Theorem-6 hierarchical decomposition, and the NN-label index for downstream training pretext tasks.

Standalone tool — `numpy` only, no BOREAL Swift dependencies.

## Project layout

```
BOREAL/
├── Makefile                         this file's quick targets
├── SETUP.md                         this doc
├── project.yml                      xcodegen spec
├── BOREAL.xcodeproj/                generated; do not edit by hand
├── BOREAL/                          Swift app sources
│   ├── App/                         BorealApp + AppCoordinator (state machine driver)
│   ├── Burst/                       pure-state reducer for capture
│   ├── Capture/                     AVFoundation interop
│   ├── Container/                   .bvox v4 + .bcube v2 file formats
│   ├── Models/                      data records (CapturedFrame, SessionSidecar)
│   ├── Phase2/                      SetProcessor (per-set lab.bvox writer)
│   ├── Processing/                  Bayer pipeline + math (BinomialEncoder,
│   │                                 SlowFoldEngine, QuantizationEngine,
│   │                                 PaletteEditor, ReRollEngine,
│   │                                 SessionConfig)
│   ├── Services/                    Storage, Logging
│   ├── UI/                          SwiftUI views (CameraView, LooksLabView, …)
│   ├── BorealKernel.h               C bridging header → Zig
│   └── Decoder.swift                Swift wrapper around the Zig C ABI
├── BOREALTests/                     unit tests
├── scripts/                         build-zig.sh, categorize-bcube.py,
│                                    zig-source-inputs.xcfilelist
└── zig/borealkernel/                Zig static-library source
    ├── build.zig                    Zig build spec
    ├── src/                         binomial.zig, dng.zig, bayer.zig, …
    └── tests/                       Zig unit tests
```
