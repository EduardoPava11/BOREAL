import Foundation
import CoreGraphics

/// One slot in the burst's 64-slot capture sequence. Persists as one entry in
/// the per-set `set.json` sidecar. `isPlaceholder` rows have no `.dng` file.
///
/// `slot` is the linear capture index (0..<64). `setIdx` and `frameInSet` are
/// the (set, frame-within-set) decomposition, persisted so a Phase 2 reader
/// can reconstruct the path as `set-NN/frame-M.dng` without re-deriving it.
/// `fileName` is the path RELATIVE TO the session root, e.g. `set-03/frame-2.dng`.
struct CapturedFrame: Codable, Sendable, Equatable {
    let slot: Int                  // 0..<64 (linear capture order)
    let setIdx: Int                // 0..<16
    let frameInSet: Int            // 0..<4
    let fileName: String           // e.g. "set-03/frame-2.dng" (relative to session root)
    let hwTimestampNanos: Int64?   // CMTime as ns since session start; nil if placeholder
    let wallClock: Date?           // nil if placeholder
    let isPlaceholder: Bool
    let skipReason: String?        // populated when isPlaceholder

    static func real(slot: Int,
                     hwTimestampNanos: Int64,
                     wallClock: Date) -> CapturedFrame {
        let setIdx = slot / PyramidTable.framesPerSet
        let frameInSet = slot % PyramidTable.framesPerSet
        return CapturedFrame(
            slot: slot,
            setIdx: setIdx,
            frameInSet: frameInSet,
            fileName: relativePath(setIdx: setIdx, frameInSet: frameInSet),
            hwTimestampNanos: hwTimestampNanos,
            wallClock: wallClock,
            isPlaceholder: false,
            skipReason: nil
        )
    }

    static func placeholder(slot: Int, reason: String) -> CapturedFrame {
        let setIdx = slot / PyramidTable.framesPerSet
        let frameInSet = slot % PyramidTable.framesPerSet
        return CapturedFrame(
            slot: slot,
            setIdx: setIdx,
            frameInSet: frameInSet,
            fileName: relativePath(setIdx: setIdx, frameInSet: frameInSet),
            hwTimestampNanos: nil,
            wallClock: nil,
            isPlaceholder: true,
            skipReason: reason
        )
    }

    static func relativePath(setIdx: Int, frameInSet: Int) -> String {
        String(format: "set-%02d/frame-%d.dng", setIdx, frameInSet)
    }
}

/// In-memory cell for the UI grid — a frame's thumbnail plus its status.
/// Not persisted; rebuilt per session. CGImage is not Equatable; we use identity.
struct FrameCell {
    enum Status {
        case empty                  // not yet attempted
        case captured(CGImage?)     // attempted + delivered (thumbnail optional)
        case skipped(SkipReason)    // attempted + skipped
    }
    var status: Status = .empty
}
