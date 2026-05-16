import Foundation

/// On-disk layout for a BOREAL session.
///
///   <AppSupport>/BorealSession/
///     ├── session.json                    ← top-level: id + pyramid table + set list
///     ├── set-00/
///     │   ├── staging/                    ← raw DNGs as written by AVCapturePhotoOutput
///     │   ├── frame-0.dng                 ← final crop-tagged DNG
///     │   ├── frame-1.dng
///     │   ├── frame-2.dng
///     │   ├── frame-3.dng
///     │   └── set.json                    ← per-set sidecar (4 frame entries + budget)
///     ├── set-01/ ...
///     ├── ...
///     └── set-15/ ...
///
/// `prepareSessionFolder()` wipes and recreates the whole tree at the start of
/// each burst so capture starts with empty set directories. The 16 set folders
/// are created upfront so per-set writes never race directory creation.
///
/// Phase 1 (capture) writes DNGs into these folders; Phase 2 (process) reads
/// them back and emits the voxel pack alongside `session.json`.
enum Storage {

    private static var appSupportRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    }

    static var sessionRoot: URL {
        appSupportRoot.appendingPathComponent("BorealSession", isDirectory: true)
    }

    /// `set-NN/` directory for a given set index.
    static func setDir(setIdx: Int) -> URL {
        sessionRoot.appendingPathComponent(String(format: "set-%02d", setIdx),
                                           isDirectory: true)
    }

    /// `set-NN/staging/` — raw DNG bytes land here before crop-tag rewrite.
    static func stagingDir(setIdx: Int) -> URL {
        setDir(setIdx: setIdx).appendingPathComponent("staging", isDirectory: true)
    }

    /// `set-NN/staging/frame-M.dng` — pre-rewrite path for one frame.
    static func stagingURL(setIdx: Int, frameInSet: Int) -> URL {
        stagingDir(setIdx: setIdx)
            .appendingPathComponent(String(format: "frame-%d.dng", frameInSet))
    }

    /// `set-NN/frame-M.dng` — final, crop-tag-rewritten DNG path.
    static func frameURL(setIdx: Int, frameInSet: Int) -> URL {
        setDir(setIdx: setIdx)
            .appendingPathComponent(String(format: "frame-%d.dng", frameInSet))
    }

    /// `set-NN/set.json` — per-set sidecar.
    static func setSidecarURL(setIdx: Int) -> URL {
        setDir(setIdx: setIdx).appendingPathComponent("set.json")
    }

    /// `session.json` — top-level sidecar with the pyramid table + set list.
    static func sessionSidecarURL() -> URL {
        sessionRoot.appendingPathComponent("session.json")
    }

    /// Convenience for code that still thinks in linear slot indices.
    /// Maps `slot ∈ 0..<64` → `(setIdx, frameInSet)` via `framesPerSet`.
    static func slotPath(slot: Int) -> (setIdx: Int, frameInSet: Int) {
        (slot / PyramidTable.framesPerSet, slot % PyramidTable.framesPerSet)
    }

    /// Wipe + recreate the whole session tree. Creates all 16 set directories
    /// (and their staging subdirs) upfront so per-frame writes can never race
    /// directory creation.
    @discardableResult
    static func prepareSessionFolder() throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: sessionRoot.path) {
            try fm.removeItem(at: sessionRoot)
        }
        try fm.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
        for setIdx in 0..<PyramidTable.setCount {
            try fm.createDirectory(at: setDir(setIdx: setIdx),
                                   withIntermediateDirectories: true)
            try fm.createDirectory(at: stagingDir(setIdx: setIdx),
                                   withIntermediateDirectories: true)
        }
        return sessionRoot
    }

    /// Remove a single set's staging directory after Phase 1 succeeds for that
    /// set. The final crop-tagged DNGs in `set-NN/` remain on disk.
    static func clearStaging(setIdx: Int) {
        let dir = stagingDir(setIdx: setIdx)
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true)
    }
}
