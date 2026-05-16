import SwiftUI

/// A compact row of `PyramidTable.setCount` (= 16) dots, one per set.
/// Each dot reflects that set's Phase 2 status:
///   - dim grey  → set not yet captured (Phase 1 hasn't reached it)
///   - amber     → set captured, Phase 2 in progress
///   - green     → Phase 2 done; `set-NN/lab.bvox` exists on disk
///   - red       → Phase 2 failed (LJPEG decode error, write failure, etc.)
///
/// Reads `phase2Status` from the coordinator. The setIdx mapping comes
/// from `PyramidTable.setCount` so this row is forward-compatible with
/// the eventual 16-set burst.
struct Phase2ProgressRow: View {
    let phase2Status: [Int: AppCoordinator.Phase2Status]
    let totalSets: Int

    init(phase2Status: [Int: AppCoordinator.Phase2Status],
         totalSets: Int = PyramidTable.setCount) {
        self.phase2Status = phase2Status
        self.totalSets = totalSets
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<totalSets, id: \.self) { setIdx in
                Circle()
                    .fill(color(for: setIdx))
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 4)
    }

    private func color(for setIdx: Int) -> Color {
        switch phase2Status[setIdx] {
        case .pending: return .orange
        case .done:    return .green
        case .failed:  return .red
        case .none:    return .white.opacity(0.18)
        }
    }
}
