import SwiftUI

/// One frame's exposure card: thumbnail + per-channel histogram + clip read-out.
/// Depends on ClipDots + RGBHistogramView (Shared/Histograms.swift).
struct FrameCardView: View {
    let card: PipelineModel.FrameCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("F\(card.index + 1)")
                    .font(.mono(10, .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Theme.surfaceHi, in: Capsule())
                if let s = card.stops, abs(s) >= 0.01 {
                    Text(String(format: "%+.1f EV", s))
                        .font(.mono(10))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                ClipDots(hist: card.hist)
            }
            if let img = card.image {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            RGBHistogramView(hist: card.hist)
                .frame(height: 48)
        }
        .panel(8)
    }
}
