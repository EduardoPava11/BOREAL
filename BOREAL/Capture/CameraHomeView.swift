import SwiftUI

/// The live-camera HOME screen — the app's root surface and first thing seen on
/// launch. Pure-black instrument styling: full-bleed preview, a tracked wordmark,
/// a translucent RGB-histogram read-out (computed live by the Zig kernel), and a
/// single round shutter that fires the 4-frame RAW bracket.
///
/// Three states avoid any launch "glimpse":
///   • starting  → black + wordmark + spinner (the brief async camera warm-up)
///   • running   → the live preview + overlays + shutter
///   • failed    → a clean fallback whose primary action is Import (the in-sim
///                 test path; never stranded when the camera can't start)
struct CameraHomeView: View {
    var pipelineError: String? = nil
    let onCapture: ([Data]) -> Void
    let onImport: () -> Void

    @State private var camera = CameraController()
    @State private var burst = BurstController()
    @State private var camError: String?
    @State private var busy = false
    @State private var labBusy = false
    @State private var labNote: String?
    @State private var reportURLs: [URL]?

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if camera.running {
                liveCamera
            } else if camError != nil || pipelineError != nil {
                fallback
            } else {
                starting
            }
        }
        .task {
            do {
                try await camera.start()
                camError = camera.running ? nil : "Camera unavailable."
            } catch {
                camError = "\(error)"
            }
        }
        .onDisappear { camera.stop() }
    }

    // ── Starting (clean black warm-up — no flash of the import panel) ─────────
    private var starting: some View {
        VStack(spacing: 16) {
            Wordmark(size: 24)
            ProgressView().tint(Theme.textDim)
        }
    }

    // ── Live camera ──────────────────────────────────────────────────────────
    @ViewBuilder private var liveCamera: some View {
        CameraPreview(session: camera.session).ignoresSafeArea()

        VStack(spacing: 0) {
            // Top bar: wordmark + Import.
            HStack {
                Wordmark(size: 15)
                Spacer()
                Button(action: onImport) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 8)

            if let msg = pipelineError ?? camError {
                Text(msg)
                    .font(.mono(12))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.red.opacity(0.85), in: Capsule())
                    .padding(.top, 10)
            }

            Spacer()

            // Live Zig exposure read-out (bk_rgb_histograms on the video feed).
            if let h = camera.liveHist {
                VStack(spacing: 6) {
                    HStack {
                        Text("RGB").font(.mono(10, .semibold)).foregroundStyle(Theme.textDim)
                        Spacer()
                        ClipDots(hist: h)
                    }
                    RGBHistogramView(hist: h).frame(height: 52)
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 18)
                .padding(.bottom, 20)
                .allowsHitTesting(false)
            }

            // Burst / report status read-out.
            if let status = burstStatus ?? labNote {
                Text(status)
                    .font(.mono(11))
                    .foregroundStyle(Theme.textDim)
                    .padding(.vertical, 4).padding(.horizontal, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 10)
            }
            if let urls = reportURLs {
                ShareLink(items: urls) {
                    Label("AirDrop 16-LAB report (\(urls.count) files)", systemImage: "square.and.arrow.up")
                        .font(.mono(11))
                        .padding(.vertical, 6).padding(.horizontal, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .padding(.bottom, 10)
            }

            // Shutter row: single 4-frame bracket (primary) + 64-burst (16×4).
            ZStack {
                Button(action: shoot) {
                    ZStack {
                        Circle().strokeBorder(Theme.text, lineWidth: 4).frame(width: 76, height: 76)
                        Circle().fill(Theme.text).frame(width: 62, height: 62)
                            .opacity(busy ? 0.4 : 1)
                        if busy { ProgressView().tint(.black) }
                    }
                }
                .disabled(busy || burst.isRunning)

                HStack {
                    Button(action: shootReport) {
                        Text("LAB")
                            .font(.mono(13))
                            .foregroundStyle(labBusy ? .black : Theme.text)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(labBusy ? Theme.text : .clear))
                            .overlay(Circle().strokeBorder(Theme.text, lineWidth: 2))
                    }
                    .disabled(busy || labBusy || burst.isRunning)
                    .padding(.leading, 34)
                    Spacer()
                    Button(action: shootBurst) {
                        Text("64")
                            .font(.mono(15))
                            .foregroundStyle(burst.isRunning ? .black : Theme.text)
                            .frame(width: 48, height: 48)
                            .background(
                                Circle().fill(burst.isRunning ? Theme.text : .clear)
                            )
                            .overlay(Circle().strokeBorder(Theme.text, lineWidth: 2))
                    }
                    .disabled(busy || labBusy || burst.isRunning)
                    .padding(.trailing, 34)
                }
            }
            .padding(.bottom, 40)
        }
    }

    // ── Failed / no-camera fallback (sim, denied, no device) ─────────────────
    private var fallback: some View {
        VStack(spacing: 14) {
            Spacer()
            Wordmark(size: 26)
            Text(pipelineError ?? camError ?? "Camera unavailable.")
                .font(.mono(12))
                .foregroundStyle(pipelineError != nil ? .red : Theme.textDim)
                .multilineTextAlignment(.center)
            Text("Capture 4 RAW frames, or import a set,\nto fuse one HDR image + a Photoshop LUT.")
                .font(.footnote)
                .foregroundStyle(Theme.textDim)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
            Spacer()
            Button(action: onImport) {
                Label("Import 4 DNGs", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
        .padding(24)
    }

    /// One line of burst state for the capsule read-out; nil hides it.
    private var burstStatus: String? {
        switch burst.phase {
        case .idle:
            return nil
        case .capturing(let cycle):
            return "cycle \(cycle)/\(BurstController.cycleCount)"
        case .draining:
            return "reducing \(burst.outcomes.count)/\(BurstController.cycleCount)…"
        case .done(let completed, let dropped):
            return dropped == 0 ? "burst ✓ \(completed) cycles"
                                : "burst ✓ \(completed) cycles (\(dropped) dropped)"
        case .failed(let why):
            return "burst ✗ \(why)"
        }
    }

    private func shootBurst() {
        Task { await burst.run(camera: camera) }
    }

    /// Capture ONE 4-DNG cycle, run the L2 chain on-device, and package the
    /// 16-LAB report (bands, palette, index maps, rung PNGs, source DNGs)
    /// for AirDrop — the ground-truth artifact for Mac-side analysis.
    private func shootReport() {
        labBusy = true
        labNote = "capturing cycle…"
        reportURLs = nil
        Task {
            do {
                let dngs = try await camera.captureBracket()
                let biases = camera.biases
                labNote = "reducing → 16-LAB report…"
                let result = await Task.detached(priority: .userInitiated) {
                    CycleReport.build(dngs: dngs, biases: biases)
                }.value
                switch result {
                case .success(let urls):
                    reportURLs = urls
                    labNote = "report ready — \(urls.count) files"
                case .failure(let why):
                    labNote = "report ✗ \(why)"
                }
            } catch {
                labNote = "report ✗ \(error)"
            }
            labBusy = false
        }
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
