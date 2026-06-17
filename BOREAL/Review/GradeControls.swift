import SwiftUI

/// ASC-CDL grade controls. Dragging re-renders the hero live (cheap thumbnail,
/// same operator as the cube); releasing a slider re-bakes the exported .cube.
struct GradeControls: View {
    @Bindable var model: PipelineModel

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Look · ASC-CDL").font(.caption.weight(.semibold))
                Spacer()
                Button("Reset") {
                    model.grade = .default
                    model.refreshPreview()
                    model.rebakeCube()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            row("Exposure", $model.grade.exposure, -2...2, "%+.2f")
            row("Contrast", $model.grade.contrast, 0.6...1.6, "%.2f")
            row("Saturation", $model.grade.saturation, 0...2, "%.2f")
            row("Temp", $model.grade.temperature, -0.3...0.3, "%+.2f")
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func row(_ label: String, _ value: Binding<Float>,
                                  _ range: ClosedRange<Float>, _ fmt: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.caption2).frame(width: 78, alignment: .leading)
            Slider(value: Binding(get: { value.wrappedValue },
                                  set: { value.wrappedValue = $0; model.refreshPreview() }),
                   in: range,
                   onEditingChanged: { editing in if !editing { model.rebakeCube() } })
            Text(String(format: fmt, value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .frame(width: 46, alignment: .trailing)
        }
    }
}
