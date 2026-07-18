import SwiftUI
import UniformTypeIdentifiers

/// Navigation root. Owns the single PipelineModel and the .fileImporter, and
/// flips between the live-camera HOME and the post-capture GIF preview driven
/// by `model.phase`:
///   .idle / .error  → CameraHomeView (live preview + histogram + shutter; Import
///                      always reachable, incl. when the camera can't start)
///   .processing      → processing overlay
///   .done            → GifPreviewView (rung hero + palette grid + AirDrop)
/// Capture IS the home: the shutter feeds model.process(datas:) directly (no
/// fullScreenCover). Preview's "New" resets → .idle → back to the camera.
struct RootView: View {
    @State private var model = PipelineModel()
    @State private var importing = false

    private var dngType: UTType { UTType(filenameExtension: "dng") ?? .data }

    /// The error message when a process()/import failed, else nil. Surfaced on
    /// the camera home so a failure isn't silently swallowed by the bounce-back.
    private var phaseError: String? {
        if case .error(let m) = model.phase { return m } else { return nil }
    }

    var body: some View {
        content
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [dngType],
                          allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): model.process(urls)
                case .failure(let err): model.phase = .error("\(err)")
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle, .error:
            CameraHomeView(
                pipelineError: phaseError,
                onCapture: { datas in model.process(datas: datas) },
                onImport: { importing = true }
            )
        case .processing:
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 18) {
                    Wordmark(size: 22)
                    ProgressView().tint(Theme.textDim)
                    Text(model.status)
                        .font(.mono(12))
                        .foregroundStyle(Theme.textDim)
                        .multilineTextAlignment(.center)
                        .animation(.default, value: model.status)
                }
            }
        case .done:
            GifPreviewView(model: model, onNew: { model.reset() })
        }
    }
}

#Preview {
    RootView()
}
