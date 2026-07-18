import SwiftUI

/// The GIF-ISP pipeline model (BOREAL-GIF-ISP-WORKFLOW.md Phase 0).
///
/// The app is capture → GIF. 4 RAW DNGs (one EV cycle, captured or imported)
/// run the 16-LAB chain into a CycleReport: bands, the seed palette, per-rung
/// GIF index maps, and an AirDrop-able bundle. The HDR-TIFF + LUT surface
/// this model used to drive is retired (preserved on `archive/hdr-lut`).
@MainActor
@Observable
final class PipelineModel {
    enum Phase { case idle, processing, done, error(String) }

    var phase: Phase = .idle
    var status: String = "Capture or import 4 RAW DNGs."
    var report: CycleReport.Report?

    var isBusy: Bool { if case .processing = phase { true } else { false } }

    func reset() {
        phase = .idle
        status = "Capture or import 4 RAW DNGs."
        report = nil
    }

    /// Import path (the simulator-testability lever): 4 DNG file URLs.
    func process(_ urls: [URL]) {
        guard urls.count == 4 else {
            phase = .error("Select exactly 4 DNG files — you picked \(urls.count).")
            return
        }
        phase = .processing
        status = "Reading DNGs…"
        Task {
            let datas: [Data]? = await Task.detached(priority: .userInitiated) {
                var out: [Data] = []
                for u in urls {
                    let scoped = u.startAccessingSecurityScopedResource()
                    defer { if scoped { u.stopAccessingSecurityScopedResource() } }
                    guard let d = try? Data(contentsOf: u) else { return nil }
                    out.append(d)
                }
                return out
            }.value
            guard let datas else {
                phase = .error("Could not read the selected files.")
                return
            }
            runReport(datas: datas)
        }
    }

    /// Capture path: 4 already-in-memory DNG blobs (one cycle).
    func process(datas: [Data]) {
        guard datas.count == 4 else {
            phase = .error("Expected 4 RAW frames — got \(datas.count).")
            return
        }
        runReport(datas: datas)
    }

    private func runReport(datas: [Data]) {
        phase = .processing
        status = "Reducing → 16-LAB → GIF target…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                CycleReport.build(dngs: datas, biases: [])
            }.value
            switch result {
            case .success(let r):
                report = r
                status = "seed 16×16 → rungs \(r.indexMaps.keys.sorted().map(String.init).joined(separator: "/"))"
                phase = .done
            case .failure(let e):
                phase = .error(e.message)
            }
        }
    }
}
