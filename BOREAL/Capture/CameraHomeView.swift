import SwiftUI

/// The live-camera HOME screen — the app's root surface. Shows the live preview
/// with the Zig RGB-histogram exposure overlay, a round shutter as the PRIMARY
/// action (fires the 4-frame RAW bracket → onCapture), and an always-reachable
/// Import affordance.
///
/// HARD CONSTRAINT (the simulator has no camera): when the camera cannot start
/// (denied / no device / sim), this renders a fallback panel whose ONLY action
/// is "Import 4 DNGs" — the in-sim test path is never stranded. Import is also
/// available as a secondary button while the camera runs.
struct CameraHomeView: View {
    /// A pipeline/import error from the last attempt (RootView's .error phase),
    /// surfaced here so a failed process()/import isn't silently swallowed when
    /// the view bounces back to the live camera.
    var pipelineError: String? = nil
    /// Hand 4 captured RAW DNG blobs to the pipeline.
    let onCapture: ([Data]) -> Void
    /// Open the RootView-owned .fileImporter (the in-sim test path).
    let onImport: () -> Void

    @State private var camera = CameraController()
    @State private var camError: String?
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.running {
                liveCamera
            } else {
                noCameraFallback
            }
        }
        .task {
            // Restart the camera every time the home re-appears (e.g. coming back
            // from Review). On throw OR a non-running session, surface the error
            // so the fallback panel (with Import) shows instead of swallowing it.
            do {
                try await camera.start()
                if camera.running { camError = nil }
                else { camError = "Camera unavailable." }
            } catch {
                camError = "\(error)"
            }
        }
        .onDisappear { camera.stop() }
    }

    // ── Live camera (device) ─────────────────────────────────────────────────
    @ViewBuilder private var liveCamera: some View {
        CameraPreview(session: camera.session).ignoresSafeArea()

        // Live Zig exposure read-out, computed by bk_rgb_histograms on the video
        // feed (NOT in Swift) and published from CameraController. Display-referred
        // /255 — a relative pre-shutter exposure guide (see Kernel.liveHistograms).
        if let h = camera.liveHist {
            VStack {
                Spacer()
                HStack {
                    ClipDots(hist: h)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.black.opacity(0.45), in: Capsule())
                    Spacer()
                }
                RGBHistogramView(hist: h)
                    .frame(height: 56)
            }
            .padding(.horizontal)
            .padding(.bottom, 150)
            .allowsHitTesting(false)
        }

        VStack {
            HStack {
                Text("BOREAL")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.35), in: Capsule())
                Spacer()
                // Import stays reachable even while the camera runs.
                Button { onImport() } label: {
                    Image(systemName: "square.and.arrow.down").font(.title3.weight(.semibold))
                        .foregroundStyle(.white).padding(12)
                        .background(.black.opacity(0.4), in: Circle())
                }
            }
            .padding()

            // Surface a failed capture (camError, camera still running) or a
            // failed pipeline/import (pipelineError) — otherwise it's invisible.
            if let msg = pipelineError ?? camError {
                Text(msg)
                    .font(.footnote).foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.red.opacity(0.85), in: Capsule())
                    .padding(.horizontal)
            }

            Spacer()

            Button(action: shoot) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 5).frame(width: 78, height: 78)
                    Circle().fill(.white).frame(width: 64, height: 64)
                    if busy { ProgressView().tint(.black) }
                }
            }
            .disabled(busy)
            .padding(.bottom, 36)
        }
    }

    // ── No-camera / denied fallback (simulator, denied permission, no device) ──
    @ViewBuilder private var noCameraFallback: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56, weight: .thin))
                .foregroundStyle(.white.opacity(0.5))
            Text("BOREAL")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.white)
            Text(pipelineError ?? camError ?? "Starting camera…")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            Text("Import 4 RAW frames to fuse into\none HDR image + a Photoshop LUT.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
                .multilineTextAlignment(.center)

            // The ONLY action available when the camera can't start — never
            // strand the in-sim Import test path.
            Button { onImport() } label: {
                Label("Import 4 DNGs", systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.top, 8)
        }
        .padding(24)
    }

    private func shoot() {
        busy = true
        Task {
            do {
                let dngs = try await camera.captureBracket()
                camera.stop()
                onCapture(dngs)
            } catch {
                camError = "\(error)"
                busy = false
            }
        }
    }
}
