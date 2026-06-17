import SwiftUI

/// Post-capture review + grade screen: hero preview, ASC-CDL look controls, the
/// per-frame RGBT exposure grid, and Share (TIFF / .cube) + New actions.
/// Reached when `model.phase == .done` (after a capture or an import).
struct ReviewView: View {
    @Bindable var model: PipelineModel
    /// Return to the live-camera home (RootView resets the model → .idle).
    let onNew: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ScrollView {
                VStack(spacing: 16) {
                    if let img = model.previewImage {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        Image(systemName: "checkmark.circle").font(.system(size: 52)).foregroundStyle(.green)
                    }

                    GradeControls(model: model)

                    if !model.frameCards.isEmpty {
                        HStack {
                            Text("Exposure · RGBT").font(.caption.weight(.semibold))
                            Spacer()
                            Text("4 frames").font(.caption2).foregroundStyle(.secondary)
                        }
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(model.frameCards) { card in
                                FrameCardView(card: card)
                            }
                        }
                    }
                }
                .padding(12)
            }

            Text(model.status)
                .font(.callout)
                .foregroundStyle(model.isError ? .red : .secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .animation(.default, value: model.status)

            HStack(spacing: 12) {
                if let o = model.output {
                    ShareLink(item: o.tiffURL) { Label("TIFF", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                    ShareLink(item: o.cubeURL) { Label(".cube", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.bordered)
                }
                Button("New") { onNew() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.large)
        }
        .padding(24)
    }
}
