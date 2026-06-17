# BOREAL — Final Review Workflow + Executed Pass

**Date:** 2026-06-16. Branch: `feat/rgbt-hdr-pivot`. Scope: the MVP app (Swift `BOREAL/MVP/*`),
the owned Zig core, and the build/integration — the state about to be tested on iPhone 17 Pro.

## A. Review method (the workflow)

Six dimensions, each with a pass/fail gate. Run top-to-bottom; a HIGH finding blocks device testing,
a MEDIUM blocks *trusting the output*, a LOW is hygiene.

| # | Dimension | What to check |
|---|-----------|---------------|
| 1 | **FFI correctness** | Swift↔Zig: buffer lengths, pointer lifetimes, ownership/free ordering, struct-size parity |
| 2 | **Pipeline correctness** | data flow decode→fuse→demosaic→TIFF/LUT; the exposure model; CFA mapping |
| 3 | **Concurrency** | Swift 6 strict concurrency: Sendable across the off-main boundary, no actor capture |
| 4 | **Resource/memory** | peak allocation on device, large buffers, scoped-resource access |
| 5 | **UX readiness** | states, feedback, errors, user-facing strings |
| 6 | **Build/integration** | project generation, signing, excluded code, test target, arch pinning |

## B. Executed findings (this pass)

### Fixed now
- **[FIXED] Stale permission strings.** `NSCameraUsageDescription` still said "captures 64 RAW frames to
  build a single GIF89a"; the unused `NSPhotoLibraryAddUsageDescription` ("saves the finished GIF89a")
  was also present. Updated the camera string to the HDR purpose and removed the Photos key (the MVP
  shares via `ShareLink`, never writes to Photos). **Root-caused:** these live in `project.yml`'s
  `info.properties` — `make setup` *regenerates* `Info.plist`, so the plist must never be hand-edited.
  Rebuilt: `** BUILD SUCCEEDED **`.

### HIGH — blocks device testing
- **[H1] `DEVELOPMENT_TEAM` is empty.** Device signing will fail until set (user-supplied team id +
  Apple ID in Xcode → Accounts + `-allowProvisioningUpdates`). Known; tracked in the bring-up workflow §6.

### MEDIUM — blocks trusting the output
- **[M1] Fusion exposure is hard-coded `(1,1,1,1)`.** Correct for *same-exposure* imports (denoise merge),
  but importing a real **EV bracket** would skip radiometric alignment and silently produce a wrong
  merge. Until exposure-time metadata is extracted from the DNG (or the capture path supplies the plan),
  **gate the Import path to same-exposure sets** or surface a warning. This is the #1 "looks fine, is
  wrong" trap. (Capture path will supply real `exposures` in Phase 3.)
- **[M2] Peak memory on the full-sensor path.** For 12 MP (4224×3024): the 4 `samples` arrays (~102 MB)
  are held *through* fusion, plus fused f32 (~51 MB) + RGB f32 (~153 MB) + the TIFF `Data` (~153 MB) →
  ~450 MB+ transient. Fine on iPhone 17 Pro, risky under memory pressure / on older devices. Mitigation:
  free the 4 `samples` right after `fuse`, and free `fused` right after `demosaic`. Validate on device.
- **[M3] `BOREALTests` target is stale.** It still compiles `BOREALTests/` against the now-excluded old
  app code, so `make test` (Xcode) will fail. **`make build` is unaffected** (test bundles aren't built
  by the build action). Update or disable in Phase 5.

### LOW — hygiene / robustness
- **[L1] 42 old Swift files remain in the tree** (excluded from the build, several with WIP edits). Dead
  weight and a confusion risk; delete in Phase 5 once the new path is validated end-to-end.
- **[L2] `buildCubeLUT` uses a fixed 16 MB text buffer.** A 64³ cube needs ~7 MB so it's safe, but a
  larger grid would overflow → `bk_emit_cube` returns 0 → a silent empty `.cube`. Size the buffer from
  `grid` (or assert) for robustness.
- **[L3] `UIRequiredDeviceCapabilities` includes `still-camera`** though the Phase-1 Import path doesn't
  use the camera. Harmless on iPhone 17 Pro; correct once the capture path lands (Phase 3).
- **[L4] Stale `dng.zig` header comment** ("uncompressed 16-bit RGGB only") — the decoder does tiled
  LJPEG + BGGR now. Cosmetic.

### Strengths confirmed (not just absence of bugs)
- **FFI is sound:** mosaic scalar fields are copied out *before* `bk_free_mosaic`; all pointers are
  scoped inside `withUnsafe*`; every C↔Zig struct size was verified equal (`bk_mosaic_t` 64 B, etc.).
- **Concurrency is clean under Swift 6 `complete`:** the off-main pipeline (`Task.detached`) reports
  progress via an `AsyncStream` **continuation** (Sendable) — never capturing the `@MainActor` model;
  `Output`/`PreviewImage` are `Sendable`.
- **Core is proven, not just present:** ~40 Zig tests green incl. SIMD≡scalar parity gates; the full
  `fuse→demosaic→TIFF` chain validated through the C ABI by `tifffile` + libtiff; the 64³ `.cube` by a
  real bake.

## C. Sign-off checklist

| Gate | State |
|------|-------|
| Zig core tests green (`zig build test`) | ✅ |
| App compiles + links Zig (sim, arm64) | ✅ |
| UI usable: preview + staged progress + metadata + share | ✅ |
| User-facing permission strings accurate | ✅ (fixed this pass) |
| Set `DEVELOPMENT_TEAM` for device | ⬜ (user) — [H1] |
| Same-exposure import guard / bracket exposure metadata | ⬜ — [M1] |
| Run Import path in simulator with real DNGs | ⬜ (Phase 2) |
| Memory check on device | ⬜ — [M2] |
| `BOREALTests` updated/disabled | ⬜ — [M3] |

## D. Verdict

**READY for Phase-2 simulator testing of the Import path.** The FFI, concurrency, and build are sound,
the UI is usable, and the permission strings are now honest. **NOT yet** (a) device-installable — signing
[H1] — nor (b) correct for *bracketed* imports — exposures hard-coded [M1]; treat Phase-2 imports as
same-exposure sets until [M1] is addressed. No correctness defects found in the FFI or the pipeline wiring.
