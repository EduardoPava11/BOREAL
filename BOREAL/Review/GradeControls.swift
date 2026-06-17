import SwiftUI

/// ASC-CDL grade controls. Dragging re-renders the hero live (cheap thumbnail,
/// same operator as the cube); releasing a slider re-bakes the exported .cube.
struct GradeControls: View {
    @Bindable var model: PipelineModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("LOOK · ASC-CDL").font(.mono(11, .semibold)).foregroundStyle(Theme.textDim)
                Spacer()
                Button("RESET") {
                    model.grade = .default
                    model.refreshPreview()
                    model.rebakeCube()
                }
                .font(.mono(10, .semibold))
                .foregroundStyle(Theme.accent)
            }
            row("EXPOSURE", $model.grade.exposure, -2...2, "%+.2f")
            row("CONTRAST", $model.grade.contrast, 0.6...1.6, "%.2f")
            row("SATURATION", $model.grade.saturation, 0...2, "%.2f")
            row("TEMP", $model.grade.temperature, -0.3...0.3, "%+.2f")
        }
        .panel()
    }

    @ViewBuilder private func row(_ label: String, _ value: Binding<Float>,
                                  _ range: ClosedRange<Float>, _ fmt: String) -> some View {
        HStack(spacing: 10) {
            Text(label).font(.mono(10)).foregroundStyle(Theme.textDim)
                .frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = $0; model.refreshPreview() }),
                   in: range,
                   onEditingChanged: { editing in if !editing { model.rebakeCube() } })
                .tint(Theme.accent)
            Text(String(format: fmt, value.wrappedValue))
                .font(.mono(11)).foregroundStyle(Theme.text)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
