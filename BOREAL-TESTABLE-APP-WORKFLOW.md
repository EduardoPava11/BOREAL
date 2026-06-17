# BOREAL — Testable-on-Device Bring-up Workflow

**Goal:** a minimal app that **compiles**, **links the new Zig core**, and **runs on iPhone 17 Pro**,
exercising the RGBT → HDR-TIFF + LUT pipeline through a **simple UI**. Date: 2026-06-16.
Branch: `feat/rgbt-hdr-pivot`.

## 0. Current state (honest baseline)

- ✅ **Zig core complete + validated** (`decode→analyse/plan→fuse→demosaic→TIFF/LUT`), ~40 tests green,
  proven through the C ABI on the Mac (tifffile/libtiff/.cube readers).
- ✅ **Link plumbing is sound:** `scripts/build-zig.sh` cross-compiles per-triple `.a`; `project.yml`
  links `-lborealkernel` with per-SDK `LIBRARY_SEARCH_PATHS`; `BOREAL-Bridging-Header.h` → `BorealKernel.h`.
  New modules are auto-included (the `.a` is built from `root.zig`, which imports them).
- ⚠️ **The Swift app is still the OLD 64-frame pipeline** (`BorealApp → AppCoordinator → CameraView`,
  `.bcube`/GIF/Looks-Lab), and the working tree is mid-refactor (deleted `BurstSession`,
  `PreviewGenerator`; several modified). It does **not** call the new pipeline and may not compile as-is.
- ⚠️ **`DEVELOPMENT_TEAM` is empty** in `project.yml` → device signing will fail until set.

## 1. Strategy — minimal new surface, exclude the old (don't fix what we'll delete)

Rather than repair 42 WIP-entangled old-pipeline Swift files, **stand up a small new app target surface
and EXCLUDE the old Swift from the build.** This gets a green compile + device run fast; the old code is
pruned in Phase 5 once the new path is validated. New code lives in `BOREAL/MVP/`.

## 2. Simple UI/UX (one screen, a tiny state machine)

```
        ┌────────────────────────────────────────┐
        │              BOREAL                      │
        │                                          │
        │   ╭──────────────────────────────╮       │
        │   │     (preview thumbnail or     │      │   states:
        │   │      neutral placeholder)     │      │   • idle
        │   ╰──────────────────────────────╯       │   • capturing  (4 frames)
        │                                          │   • processing (fuse→demosaic→encode)
        │   status: "Ready"                        │   • done
        │                                          │   • error(msg)
        │   [  Capture 4  ]   [  Import DNGs  ]     │
        │   ───────── when done: ─────────         │
        │   [ Share TIFF ]   [ Share .cube ]       │
        │   [        New         ]                 │
        └──────────────────────────────────────────┘
```

- **Two entry paths.** `Capture 4` (device camera) AND `Import DNGs` (pick 4 `.dng` files). The Import
  path is the **testability lever** — it exercises the entire Zig pipeline with **no camera**, so it runs
  in the **simulator** and on device without capture plumbing. Build the Import path FIRST.
- **Outputs:** after processing, `Share TIFF` and `Share .cube` present a `UIActivityViewController`
  (AirDrop/Files). That's the whole "did it work?" loop — open the TIFF in Photoshop, drop the LUT in.
- **No** Looks Lab, grid, glass, GIF. One `View`, one `@Observable` view-model, five states.

## 3. Swift ↔ Zig wrapper (`BOREAL/MVP/Kernel.swift`)

A thin, safe Swift facade over the new C ABI (all symbols already exported + in `BorealKernel.h`):

```
enum Kernel {
  static func keepalive()                                   // force-link (referenced in App.init)
  static func decodeDNG(_ data: Data) -> Mosaic?            // bk_decode_dng_to_mosaic (+ wb_r/g/b)
  static func analyzeScene(_ rgb: [Float], w, h) -> SceneClips        // bk_analyze_scene
  static func planExposures(_ c: SceneClips, wb: (Float,Float,Float), extraShadow: Float) -> ExposurePlan
  static func fuse(_ frames: [[UInt16]], params: FuseParams) -> [Float]              // bk_fuse_mosaics
  static func demosaic(_ mosaic: [Float], w, h, cfa: UInt32) -> [Float]              // bk_demosaic_full
  static func writeTIFF(rgb: [Float], w, h, icc: Data?) -> Data                      // bk_write_tiff_f32
  static func buildCubeLUT(_ p: LookParams, grid: UInt32 = 64) -> Data               // bk_build_cube_lut + bk_emit_cube
}
```
Structs (`Mosaic`, `SceneClips`, `ExposurePlan`, `FuseParams`, `LookParams`) bridge 1:1 to the C structs.
`writeTIFF`/`buildCubeLUT` first call the `*_size` entrypoint, allocate, then fill.

## 4. Build wiring changes (`project.yml`)

1. **Sources:** include `BOREAL/MVP/**`; **exclude** the old app dirs from the target
   (`App`, `Burst`, `Capture`*, `Container`, `Models`, `Phase2`, `Processing`, `UI`, `Services`*) —
   keep only what the MVP imports (`Capture/` survives once the camera path is wired in Phase 3).
   Net for Phase 1 (Import path): exclude everything old; the MVP needs no camera.
2. **`DEVELOPMENT_TEAM`:** set to the real team ID (user supplies; see §6).
3. **Info.plist usage strings:** replace the stale "64 RAW frames → GIF" text:
   `NSCameraUsageDescription = "BOREAL captures 4 RAW frames to build an HDR image."`
   Drop `NSPhotoLibraryAddUsageDescription` unless we write to Photos. Keep `still-camera` capability
   only once the Capture path lands (Phase 3); the Import-only Phase-1 app doesn't need it.
4. Run `make setup` after every `project.yml` edit (regenerates the `.xcodeproj`).

## 5. Phase plan (gates; compile-check ≠ run, per the device rule)

| Phase | Deliverable | Gate (where it's checked) |
|------:|-------------|---------------------------|
| 1 | ✅ **DONE.** `BOREAL/MVP/{Kernel,BorealApp,ContentView}.swift` + `project.yml` sources → `BOREAL/MVP` only. **`** BUILD SUCCEEDED **`** for arm64 iOS Simulator — Swift compiles, bridging header resolves, `-lborealkernel` links. ⚠️ build arm64 sims with `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES` (the Zig sim `.a` is arm64-only; a generic x86_64 slice fails to link). |
| 2 | Import 4 DNGs → `decode→analyse→plan→fuse→demosaic→TIFF+LUT` → Share | **runs in simulator** (no camera): import sample DNGs, share outputs |
| 3 | Wire salvaged `Capture/`+`Burst/` → 4-frame burst at planned exposures | `make build`; **on device** (camera) — user runs |
| 4 | `DEVELOPMENT_TEAM` + signing → install on iPhone 17 Pro | **device build + launch** (user) |
| 5 | Delete the old Swift (un-exclude becomes un-needed); update `SETUP.md` | `make build` green with old files removed |

> Phases 1–2 are fully verifiable WITHOUT a device (compile in sim + run the Import path in sim).
> Only Phases 3–4 need the iPhone 17 Pro, because only the camera can't be simulated.

## 6. Run on iPhone 17 Pro — checklist

1. **Signing (one-time):** in `project.yml` set `DEVELOPMENT_TEAM: <TEAMID>` (Apple Developer team id),
   `make setup`. Keep `CODE_SIGN_STYLE: Automatic`.
2. In **Xcode → Settings → Accounts**, add the Apple ID that owns that team (this is the human step
   Claude can't do).
3. Build to device:
   `xcodebuild -project BOREAL.xcodeproj -scheme BOREAL -destination 'platform=iOS,name=<your iPhone>' -allowProvisioningUpdates build`
   (or open in Xcode, pick the iPhone 17 Pro, ⌘R). `-allowProvisioningUpdates` lets Xcode mint the
   provisioning profile.
4. On the iPhone: **Settings → General → VPN & Device Management** → trust the developer cert.
5. First camera launch: grant the camera permission prompt.
6. Zig sanity at launch: `App.init` calls `Kernel.keepalive()` — if the `.a` didn't link, you get a
   launch-time symbol error immediately (cheap linkage canary, same trick as the old app).

## 7. Testability matrix

| Layer | How to test | Needs device? |
|---|---|---|
| Zig kernel | `zig build test` (~40 tests) + C-ABI harness | No (Mac) |
| Swift ↔ Zig link | `make build` links `-lborealkernel`; `keepalive()` at launch | No (sim compile) |
| Full pipeline (decode→…→TIFF/LUT) | **Import-DNGs path in the simulator** | No (sim) |
| Camera capture (4-frame burst) | run the Capture path | **Yes** |
| Output fidelity | open TIFF in Photoshop; apply `.cube` | No (desktop) |

## 8. Open decisions

1. **First-test capture:** fixed bracket (simplest) vs full ETTR scene-analysis loop. → **Default: fixed
   bracket in Phase 3**; wire ETTR (`analyzeScene`/`planExposures`) once the basic burst runs on device.
2. **ICC profile:** ship a ProPhoto/linear ICC blob now, or emit TIFF without one initially? → **Default:
   no ICC for Phase 1–2** (Photoshop assigns working space); add the blob in Phase 4.
3. **Old Swift:** exclude-then-delete (this plan) vs refactor in place. → **Default: exclude then delete.**
