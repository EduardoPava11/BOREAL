import SwiftUI

/// Post-capture review + grade: hero preview, ASC-CDL look controls, the per-frame
/// RGBT exposure grid, and Share (TIFF / .cube). Reached at `model.phase == .done`.
struct ReviewView: View {
    @Bindable var model: PipelineModel
    /// Return to the live-camera home (RootView resets the model → .idle).
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 14) {
                    hero
                    GradeControls(model: model)
                    rgbtGrid
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            shareBar
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private var topBar: some View {
        HStack {
            Button(action: onNew) {
                Label("Camera", systemImage: "chevron.left")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.text)
            }
            Spacer()
            Text(model.isError ? model.status : metadata)
                .font(.mono(11))
                .foregroundStyle(model.isError ? .red : Theme.textDim)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// Compact mono read-out (dims · TIFF · LUT) from the output, else the status.
    private var metadata: String {
        guard let o = model.output else { return model.status }
        return "\(o.width)×\(o.height)  TIFF \(PipelineModel.fmt(o.tiffBytes))  LUT \(PipelineModel.fmt(o.cubeBytes))"
    }

    @ViewBuilder private var hero: some View {
        if let img = model.previewImage {
            Image(uiImage: img)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Theme.corner))
                .overlay(RoundedRectangle(cornerRadius: Theme.corner).strokeBorder(Theme.hairline))
        } else {
            RoundedRectangle(cornerRadius: Theme.corner)
                .fill(Theme.surface).frame(height: 220)
                .overlay(Image(systemName: "checkmark.circle").font(.system(size: 44)).foregroundStyle(Theme.accent))
        }
    }

    @ViewBuilder private var rgbtGrid: some View {
        if !model.frameCards.isEmpty {
            HStack {
                Text("EXPOSURE · RGBT").font(.mono(11, .semibold)).foregroundStyle(Theme.textDim)
                Spacer()
                Text("4 FRAMES").font(.mono(10)).foregroundStyle(Theme.textDim.opacity(0.7))
            }
            .padding(.top, 4)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                GridItem(.flexible(), spacing: 10)], spacing: 10) {
                ForEach(model.frameCards) { card in FrameCardView(card: card) }
            }
        }
    }

    @ViewBuilder private var shareBar: some View {
        if let o = model.output {
            HStack(spacing: 10) {
                ShareLink(item: o.tiffURL) {
                    Label("TIFF", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
                ShareLink(item: o.cubeURL) {
                    Label(".cube", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)
            .background(Theme.bg)
        }
    }
}
