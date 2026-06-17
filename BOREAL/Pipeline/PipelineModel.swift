import SwiftUI
import UIKit

@MainActor
@Observable
final class PipelineModel {
    enum Phase { case idle, processing, done, error(String) }

    var phase: Phase = .idle
    var status: String = "Pick 4 RAW DNGs of the same scene."
    var output: Output?
    var previewImage: UIImage?
    var frameCards: [FrameCard] = []
    var grade: Kernel.GradeParams = .default

    var isBusy: Bool { if case .processing = phase { true } else { false } }

    struct Output: Sendable {
        let tiffURL: URL
        let cubeURL: URL
        let width: Int
        let height: Int
        let tiffBytes: Int
        let cubeBytes: Int
        let linearThumb: Kernel.LinearThumb
        let framePreviews: [Kernel.FramePreview]
    }

    /// One frame's exposure card, ready for display (thumbnail already a UIImage).
    struct FrameCard: Identifiable {
        let index: Int
        var id: Int { index }
        let image: UIImage?
        let hist: Kernel.ChannelHistogram
        let stops: Float?
    }

    func reset() {
        phase = .idle
        status = "Pick 4 RAW DNGs of the same scene."
        output = nil
        previewImage = nil
        frameCards = []
        grade = .default
    }

    /// Re-render the hero preview with the current grade (cheap — small thumb).
    /// The on-screen look uses the SAME operator the exported .cube bakes.
    func refreshPreview() {
        guard let out = output else { return }
        previewImage = Self.image(from: Kernel.renderGraded(out.linearThumb, look: grade.look))
    }

    /// Re-bake the .cube file with the current grade (heavier — do on slider
    /// release, not every tick). Off-main; updates the LUT-size status on return.
    func rebakeCube() {
        guard let out = output else { return }
        let look = grade.look
        let url = out.cubeURL
        Task {
            let bytes = await Task.detached(priority: .userInitiated) { () -> Int in
                let cube = Kernel.buildCubeLUT(look: look)
                try? cube.write(to: url)
                return cube.count
            }.value
            self.status = "\(out.width)×\(out.height)  ·  TIFF \(Self.fmt(out.tiffBytes))  ·  LUT \(Self.fmt(bytes))"
        }
    }

    func process(_ urls: [URL]) {
        guard urls.count == 4 else {
            phase = .error("Select exactly 4 DNG files — you picked \(urls.count).")
            return
        }
        phase = .processing
        status = "Starting…"

        run { progress in try Self.runPipeline(urls, progress: progress) }
    }

    /// Process 4 already-in-memory DNG blobs (the capture path).
    func process(datas: [Data]) {
        guard datas.count == 4 else {
            phase = .error("Expected 4 RAW frames — got \(datas.count).")
            return
        }
        phase = .processing
        status = "Starting…"
        run { progress in try Self.runPipeline(datas, progress: progress) }
    }

    /// Shared off-main runner + main-actor completion for both import and capture.
    private func run(_ work: @escaping @Sendable (@escaping @Sendable (String) -> Void) throws -> Output) {
        let (stream, cont) = AsyncStream<String>.makeStream()
        let progressTask = Task { for await s in stream { self.status = s } }
        Task {
            do {
                let out = try await Task.detached(priority: .userInitiated) {
                    try work { cont.yield($0) }
                }.value
                cont.finish()
                await progressTask.value
                self.output = out
                self.grade = .default
                self.previewImage = Self.image(from: Kernel.renderGraded(out.linearThumb, look: self.grade.look))
                self.frameCards = out.framePreviews.map {
                    FrameCard(index: $0.index, image: Self.image(from: $0.thumb), hist: $0.hist, stops: $0.stops)
                }
                self.status = "\(out.width)×\(out.height)  ·  TIFF \(Self.fmt(out.tiffBytes))  ·  LUT \(Self.fmt(out.cubeBytes))"
                self.phase = .done
            } catch {
                cont.finish()
                self.phase = .error("\(error)")
            }
        }
    }

    /// Import path: read 4 DNG files (security-scoped), then run the core pipeline.
    nonisolated static func runPipeline(_ urls: [URL], progress: @Sendable (String) -> Void) throws -> Output {
        var datas: [Data] = []
        for (i, url) in urls.enumerated() {
            progress("Reading \(i + 1)/4…")
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            datas.append(try Data(contentsOf: url))
        }
        return try runPipeline(datas, progress: progress)
    }

    /// Core off-main pipeline: decode ×4 → fuse → colour → demosaic → preview + TIFF + LUT.
    nonisolated static func runPipeline(_ datas: [Data], progress: @Sendable (String) -> Void) throws -> Output {
        blog.info("runPipeline: \(datas.count) frames, sizes \(datas.map { $0.count })")
        var frames: [Kernel.Frame] = []
        for (i, data) in datas.enumerated() {
            progress("Decoding \(i + 1)/4…")
            let d = Kernel.decodeDNG(data)
            guard let f = d.frame else {
                throw Kernel.Failure.decode("frame \(i + 1): \(Kernel.statusName(d.status)) [\(d.status)]")
            }
            frames.append(f)
        }
        let w = frames[0].width, h = frames[0].height
        guard frames.allSatisfy({ $0.width == w && $0.height == h }) else {
            blog.error("dimension mismatch: \(frames.map { "\($0.width)x\($0.height)" })")
            throw Kernel.Failure.dimensionMismatch
        }
        blog.info("decoded 4 frames \(w)×\(h); fusing → colour → TIFF/LUT")
        progress("Reading exposure…")
        // Per-frame relative exposure ratios from the SAME Zig source of truth the
        // fuse consumes (darkest = 1.0), so the EV label can't diverge from the
        // merge. log2(e_t) is exactly EV above the darkest frame.
        var et: [Float] = [frames[0].exposureTime, frames[1].exposureTime, frames[2].exposureTime, frames[3].exposureTime]
        var isoArr: [Float] = [frames[0].iso, frames[1].iso, frames[2].iso, frames[3].iso]
        var fnArr: [Float] = [frames[0].fNumber, frames[1].fNumber, frames[2].fNumber, frames[3].fNumber]
        var ev = [Float](repeating: 1, count: 4)
        bk_relative_exposures(&et, &isoArr, &fnArr, &ev)
        // {1,1,1,1} = fallback / no real bracket → show no EV label on any card.
        let noBracket = ev.allSatisfy { $0 == 1.0 }
        let stops: [Float?] = ev.map { noBracket ? nil : log2($0) }
        // Per-frame RGB histograms + thumbnails BEFORE fusion — once fused, each
        // frame's individual exposure is gone. This is the RGBT exposure read-out.
        let framePreviews = frames.enumerated().map { i, f in
            Kernel.framePreview(f, index: i, stops: stops[i])
        }
        progress("Fusing 4 frames…")
        guard let fused = Kernel.fuse(frames) else { throw Kernel.Failure.fuseFailed }
        progress("Demosaicing…")
        var rgb = Kernel.demosaic(fused, width: w, height: h, cfa: frames[0].cfa)
        // Camera-native linear RGB → ProPhoto linear (WB + DNG colour matrix), in
        // Zig. No-op when the DNG carried no usable matrix (then no ICC either).
        let colorManaged = frames[0].hasColor
        if colorManaged {
            progress("Colour transform…")
            Kernel.applyColor(&rgb, width: w, height: h, matrix: frames[0].camToPP)
        }
        progress("Rendering preview…")
        // Retain a small scene-linear thumbnail so the grade can be re-applied
        // live (the hero is rendered from this on the main actor).
        let linearThumb = Kernel.makeLinearThumb(rgb: rgb, width: w, height: h, isProPhoto: colorManaged)
        progress("Encoding HDR TIFF…")
        // Tag the master with a linear-ProPhoto ICC only when the data is actually
        // ProPhoto; otherwise leave it untagged (camera-native) rather than mis-tag.
        // The TIFF is the UNGRADED scene-linear master; the look lives in the .cube.
        let icc = colorManaged ? Kernel.linearProPhotoICC() : nil
        let tiff = Kernel.writeTIFF(rgb: rgb, width: w, height: h, icc: icc)
        progress("Building LUT…")
        let cube = Kernel.buildCubeLUT(look: Kernel.GradeParams.default.look)

        let dir = FileManager.default.temporaryDirectory
        let tiffURL = dir.appendingPathComponent("BOREAL.tiff")
        let cubeURL = dir.appendingPathComponent("BOREAL.cube")
        try tiff.write(to: tiffURL)
        try cube.write(to: cubeURL)
        return Output(tiffURL: tiffURL, cubeURL: cubeURL, width: w, height: h,
                      tiffBytes: tiff.count, cubeBytes: cube.count, linearThumb: linearThumb,
                      framePreviews: framePreviews)
    }

    static func image(from p: Kernel.PreviewImage) -> UIImage? {
        guard let provider = CGDataProvider(data: Data(p.rgba) as CFData) else { return nil }
        guard let cg = CGImage(
            width: p.width, height: p.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: p.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        return UIImage(cgImage: cg)
    }

    static func fmt(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension PipelineModel {
    var isError: Bool { if case .error = phase { true } else { false } }
}
