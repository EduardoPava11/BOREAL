import SwiftUI

/// The GIF preview surface (BOREAL-GIF-ISP-WORKFLOW.md Phase 1): the user
/// SEES exactly what the ISP targets — index map × palette, decoded by the
/// same path that writes the report PNGs. Nearest-neighbor upscale only;
/// smoothing would lie about the product.
///
///   hero      the selected rung, palette-mapped
///   rung bar  16 / 32 / 64 / 128 / 256 — every prefix is a rung
///   palette   the seed 16×16 shown AS a 16×16 grid (A2 made visible:
///             grid position ≡ palette color)
///   share     AirDrops the full report bundle (JSON + PNGs + DNGs)
struct GifPreviewView: View {
    let model: PipelineModel
    let onNew: () -> Void

    @State private var rung = 256

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if let report = model.report {
                content(report)
            } else {
                Text("No report.").font(.mono(12)).foregroundStyle(Theme.textDim)
            }
        }
    }

    @ViewBuilder private func content(_ report: CycleReport.Report) -> some View {
        VStack(spacing: 16) {
            HStack {
                Button(action: onNew) {
                    Label("New", systemImage: "camera")
                        .font(.mono(12)).foregroundStyle(Theme.text)
                }
                Spacer()
                Text(model.status)
                    .font(.mono(10)).foregroundStyle(Theme.textDim)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)

            // Hero: the selected rung, decoded index×palette, hard pixels.
            // At the ceiling the cycle's 4 per-frame maps ANIMATE at the
            // GIF's 5 cs cadence — THE GIF, decoded by the same path.
            // Non-ceiling rungs stay static (frames exist only at ceiling).
            let frames = heroFrames(report)
            if frames.count == 4 {
                TimelineView(.periodic(from: .now, by: 0.05)) { ctx in
                    hero(frames[Int(ctx.date.timeIntervalSinceReferenceDate * 20) % 4])
                }
            } else if let img = heroImage(report) {
                hero(img)
            }

            // Rung bar: every prefix is a rung.
            HStack(spacing: 8) {
                ForEach(report.indexMaps.keys.sorted(), id: \.self) { r in
                    Button(action: { rung = r }) {
                        Text("\(r)")
                            .font(.mono(12))
                            .foregroundStyle(rung == r ? .black : Theme.text)
                            .padding(.vertical, 6).padding(.horizontal, 10)
                            .background(Capsule().fill(rung == r ? Theme.text : .clear))
                            .overlay(Capsule().strokeBorder(Theme.text, lineWidth: 1))
                    }
                }
            }

            // The seed 16×16 AS a 16×16 grid — the palette IS the image.
            paletteGrid(report)
                .padding(.horizontal, 60)

            // THE PRODUCT: the cycle's 4 frames as one GIF (what the hero
            // is animating), shareable alone — the burst-of-4 direction's
            // first-class moment. The full bundle stays one row below.
            HStack(spacing: 10) {
                if let gif = report.urls.first(where: { $0.lastPathComponent == "cycle.gif" }) {
                    ShareLink(items: [gif]) {
                        Label("Share GIF", systemImage: "square.and.arrow.up")
                            .font(.mono(12))
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                }
                ShareLink(items: report.urls) {
                    Label("AirDrop report (\(report.urls.count) files)",
                          systemImage: "square.and.arrow.up")
                        .font(.mono(12))
                        .padding(.vertical, 8).padding(.horizontal, 14)
                        .background(.ultraThinMaterial, in: Capsule())
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.top, 12)
    }

    private func hero(_ img: CGImage) -> some View {
        Image(decorative: img, scale: 1)
            .resizable()
            .interpolation(.none)
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 18)
    }

    /// The cycle's 4 per-frame ceiling renders — non-empty only when the
    /// ceiling rung is selected AND the report carries all 4 frame maps.
    private func heroFrames(_ report: CycleReport.Report) -> [CGImage] {
        let ceiling = report.indexMaps.keys.max() ?? 16
        let r = report.indexMaps[rung] != nil ? rung : ceiling
        guard r == ceiling, report.frameIndices.count == 4 else { return [] }
        let imgs = report.frameIndices.compactMap {
            CycleReport.cgImage(indices: $0, side: ceiling, paletteRGB: report.paletteRGB)
        }
        return imgs.count == 4 ? imgs : []
    }

    private func heroImage(_ report: CycleReport.Report) -> CGImage? {
        let r = report.indexMaps[rung] != nil ? rung : (report.indexMaps.keys.max() ?? 16)
        guard let indices = report.indexMaps[r] else { return nil }
        return CycleReport.cgImage(indices: indices, side: r, paletteRGB: report.paletteRGB)
    }

    private func paletteGrid(_ report: CycleReport.Report) -> some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 1), count: 16)
        return LazyVGrid(columns: cols, spacing: 1) {
            ForEach(0..<256, id: \.self) { i in
                let p = i * 3
                Rectangle()
                    .fill(Color(red: Double(report.paletteRGB[p]) / 255,
                                green: Double(report.paletteRGB[p + 1]) / 255,
                                blue: Double(report.paletteRGB[p + 2]) / 255))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
    }
}
