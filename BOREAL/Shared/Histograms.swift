import SwiftUI

/// Three tiny channel squares that light up when that channel is clipping
/// (>0.5% of its samples piled in the top bin) — a glanceable "blown highlights"
/// warning per frame. Shared by the live capture overlay AND the review cards.
struct ClipDots: View {
    let hist: Kernel.ChannelHistogram
    private let threshold = 0.005

    var body: some View {
        HStack(spacing: 3) {
            dot(.red, hist.clipR)
            dot(.green, hist.clipG)
            dot(.blue, hist.clipB)
        }
    }

    private func dot(_ color: Color, _ frac: Double) -> some View {
        let clipping = frac > threshold
        return RoundedRectangle(cornerRadius: 2)
            .fill(clipping ? color : color.opacity(0.2))
            .frame(width: 8, height: 8)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(color.opacity(0.5), lineWidth: clipping ? 1 : 0))
    }
}

/// Per-channel RGB histogram, drawn as three screen-blended area curves on black.
/// Counts are log-compressed so a thin highlight-clip tail stays visible next to
/// a tall midtone peak — the detail that matters for judging exposure. Shared by
/// the live capture overlay AND the review cards.
struct RGBHistogramView: View {
    let hist: Kernel.ChannelHistogram

    var body: some View {
        Canvas { ctx, size in
            let peak = max(1.0, Double(hist.peak))
            let logPeak = log1p(peak)
            ctx.blendMode = .screen   // overlaps brighten → white where R,G,B coincide
            fill(&ctx, hist.r, .red, size, logPeak)
            fill(&ctx, hist.g, .green, size, logPeak)
            fill(&ctx, hist.b, .blue, size, logPeak)
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func fill(_ ctx: inout GraphicsContext, _ ch: [UInt32], _ color: Color,
                      _ size: CGSize, _ logPeak: Double) {
        let n = ch.count
        guard n > 1 else { return }
        let w = size.width, h = size.height
        var path = Path()
        path.move(to: CGPoint(x: 0, y: h))
        for i in 0..<n {
            let x = w * CGFloat(i) / CGFloat(n - 1)
            let v = log1p(Double(ch[i])) / logPeak           // 0…1, log-compressed
            let y = h - CGFloat(v) * h
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: w, y: h))
        path.closeSubpath()
        ctx.fill(path, with: .color(color.opacity(0.85)))
    }
}
