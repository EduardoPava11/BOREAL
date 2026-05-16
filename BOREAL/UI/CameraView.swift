import SwiftUI

struct CameraView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                preview
                FrameGridView(cells: coordinator.cells)
                    .padding(.horizontal, 24)
                statusLine
                actionBar
                    .padding(.bottom, 36)
            }
            .padding(.top, 24)
        }
        .task { await coordinator.preparePreviewIfNeeded() }
    }

    private var preview: some View {
        CameraPreviewView(session: coordinator.avSession)
            .aspectRatio(3.0/4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 24)
            .overlay(squareCropOverlay)
    }

    /// Faint outline showing the centered 2944² square region the burst will save.
    private var squareCropOverlay: some View {
        GeometryReader { geo in
            // Sensor is 4032×3024 displayed as 3:4 portrait. The 2944² crop is
            // 2944/3024 ≈ 97.4% of the displayed width and 2944/4032 ≈ 73.0% of height.
            let widthFrac: CGFloat = 2944.0 / 3024.0
            let heightInDisplayUnits = geo.size.width * widthFrac
            let x = (geo.size.width - geo.size.width * widthFrac) / 2
            let y = (geo.size.height - heightInDisplayUnits) / 2
            Rectangle()
                .stroke(.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .frame(width: geo.size.width * widthFrac, height: heightInDisplayUnits)
                .offset(x: x, y: y)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch coordinator.state {
        case .idle:
            Text("READY").font(.caption).monospaced().foregroundStyle(.white.opacity(0.7))
        case .preparing:
            Text("PREPARING…").font(.caption).monospaced().foregroundStyle(.white.opacity(0.7))
        case .capturing(let slot, let captured, let skipped, _):
            Text("CAPTURING \(slot)/\(BurstReducer.targetFrameCount) (saved \(captured) · skipped \(skipped.count))")
                .font(.caption).monospaced().foregroundStyle(.white)
        case .draining(let captured, let skipped, let left, _):
            Text("DRAINING (\(captured) saved · \(skipped.count) skipped · \(left) processing)")
                .font(.caption).monospaced().foregroundStyle(.white.opacity(0.85))
        case .done(let captured, let skipped, _, let dur):
            if skipped.isEmpty {
                Text(String(format: "SAVED %d IN %.2fs", BurstReducer.targetFrameCount, dur))
                    .font(.caption).monospaced().foregroundStyle(.green)
            } else {
                Text(String(format: "SAVED %d OF %d IN %.2fs · skipped %@",
                            captured, BurstReducer.targetFrameCount, dur,
                            skipped.map(String.init).joined(separator: ",")))
                    .font(.caption).monospaced().foregroundStyle(.yellow)
            }
        case .failed(let m):
            Text("ERROR: \(m)").font(.caption).monospaced().foregroundStyle(.red)
        }
    }

    @ViewBuilder private var actionBar: some View {
        switch coordinator.state {
        case .idle:
            captureButton
        case .preparing, .capturing, .draining:
            captureButton.opacity(0.35).allowsHitTesting(false)
        case .done(_, _, let folder, _):
            VStack(spacing: 8) {
                Text(folder.path).font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(2).truncationMode(.middle)
                Button("NEW BURST") { coordinator.reset() }
                    .buttonStyle(.bordered).tint(.white)
            }
            .padding(.horizontal, 24)
        case .failed:
            Button("RETRY") { coordinator.reset() }
                .buttonStyle(.bordered).tint(.white)
        }
    }

    private var captureButton: some View {
        Button(action: { coordinator.beginBurst() }) {
            Circle()
                .fill(.white)
                .frame(width: 76, height: 76)
                .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 4).padding(-6))
        }
        .buttonStyle(.plain)
    }
}
