import SwiftUI

/// 8×8 grid of 64 cells. Three visual states per cell:
///   - empty (not yet attempted) → dark grey
///   - captured(thumb) → the thumbnail
///   - skipped(reason) → red X with reason letter (T=timeout, I=ispNotReady, etc.)
struct FrameGridView: View {
    let cells: [FrameCell]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<64, id: \.self) { i in
                cellView(for: cells.indices.contains(i) ? cells[i] : FrameCell())
            }
        }
    }

    @ViewBuilder private func cellView(for cell: FrameCell) -> some View {
        switch cell.status {
        case .empty:
            Rectangle()
                .fill(.white.opacity(0.06))
                .aspectRatio(1, contentMode: .fit)
        case .captured(let cg):
            if let cg {
                Image(decorative: cg, scale: 1.0)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
                    .clipped()
            } else {
                Rectangle()
                    .fill(.white.opacity(0.18))
                    .aspectRatio(1, contentMode: .fit)
            }
        case .skipped(let reason):
            ZStack {
                Rectangle().fill(.red.opacity(0.18))
                Text(reasonGlyph(reason))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red.opacity(0.8))
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    private func reasonGlyph(_ r: SkipReason) -> String {
        switch r {
        case .timeout:      "T"
        case .ispNotReady:  "I"
        case .captureError: "E"
        case .writeFailed:  "W"
        case .unknown:      "?"
        }
    }
}
