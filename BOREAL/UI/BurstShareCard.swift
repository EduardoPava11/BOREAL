import SwiftUI

/// Visible status + share UI for the burst-done state. Replaces the (invisible)
/// `Phase2ProgressRow` with a big rounded card that communicates:
///   - how many files are captured + their total size
///   - Phase 2's current stage (pending / done / failed) with a clear label
///   - a prominent Share button that bundles all the files for AirDrop
///
/// The `ShareLink(items:)` opens the system share sheet (Messages, Mail,
/// AirDrop, Save to Files, etc.). The user picks AirDrop, the 4 DNGs (~40 MB
/// total) plus the `.bvox` (if Phase 2 finished) transfer to their Mac. No
/// Xcode → Devices → Download Container required.
struct BurstShareCard: View {
    let phase2Status: AppCoordinator.Phase2Status?
    /// MVP: only set-00 (4-frame burst). When multi-set scaling lands, this
    /// card can show "Set N of 16" + bundle all sets' files.
    let setIdx: Int

    init(phase2Status: AppCoordinator.Phase2Status?, setIdx: Int = 0) {
        self.phase2Status = phase2Status
        self.setIdx = setIdx
    }

    private var shareableURLs: [URL] {
        let fm = FileManager.default
        var urls: [URL] = (0..<PyramidTable.framesPerSet).map { f in
            Storage.frameURL(setIdx: setIdx, frameInSet: f)
        }
        let bvox = Storage.setDir(setIdx: setIdx).appendingPathComponent("lab.bvox")
        if fm.fileExists(atPath: bvox.path) {
            urls.append(bvox)
        }
        return urls.filter { fm.fileExists(atPath: $0.path) }
    }

    private var totalSizeBytes: Int {
        let fm = FileManager.default
        return shareableURLs.reduce(0) { sum, url in
            sum + ((try? fm.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // ── Header: file count + size ──
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                Text("\(shareableURLs.count) files  •  \(sizeString)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
            }

            // ── Phase 2 status row (text label, not just a dot) ──
            HStack(spacing: 8) {
                statusGlyph
                Text(statusLabel)
                    .font(.subheadline.monospaced())
                    .foregroundStyle(.white.opacity(0.85))
                Spacer()
            }

            // ── The action: prominent Share button ──
            if !shareableURLs.isEmpty {
                ShareLink(items: shareableURLs) {
                    Label("Share via AirDrop", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.12))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
        )
        .padding(.horizontal, 24)
    }

    // MARK: - Status presentation

    @ViewBuilder private var statusGlyph: some View {
        switch phase2Status {
        case .pending:
            Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        case .none:
            Image(systemName: "circle").foregroundStyle(.white.opacity(0.4))
        }
    }

    private var statusLabel: String {
        switch phase2Status {
        case .pending: return "Phase 2  •  processing"
        case .done:    return "Phase 2  •  done"
        case .failed:  return "Phase 2  •  failed (see log)"
        case .none:    return "Phase 2  •  not started"
        }
    }

    private var sizeString: String {
        let bytes = totalSizeBytes
        if bytes >= 1_048_576 {
            return String(format: "%.1f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.1f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}
