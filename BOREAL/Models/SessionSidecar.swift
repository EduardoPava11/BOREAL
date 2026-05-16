import Foundation

/// Spatial-crop spec recorded once per session. Same numbers as
/// `DNGCropTagEditor.CropPlan` defaults; persisted so downstream readers
/// don't need to re-derive them from the DNG IFDs.
struct CropSpec: Codable, Sendable, Equatable {
    let originX: UInt32      // 544
    let originY: UInt32      // 40
    let sizeWidth: UInt32    // 2944
    let sizeHeight: UInt32   // 2944
    let bayerBlockSize: UInt32  // 46

    static let `default` = CropSpec(
        originX: 544, originY: 40,
        sizeWidth: 2944, sizeHeight: 2944,
        bayerBlockSize: 46
    )
}

/// Per-set on-disk sidecar — one of these is written into each `set-NN/set.json`.
/// Holds the four frame entries for the set and the set's pyramid budget so the
/// Phase 2 processor can read a set folder in isolation without consulting
/// `session.json`.
struct SetSidecar: Codable, Sendable, Equatable {
    let setIdx: Int
    let codeBudget: Int             // pyramid[setIdx]; persisted for self-containment
    let captured: Int               // count of non-placeholder frames in this set
    let skipped: [Int]              // frameInSet indices that were skipped
    let frames: [CapturedFrame]     // exactly framesPerSet (= 4) entries

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> SetSidecar {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SetSidecar.self, from: try Data(contentsOf: url))
    }
}

/// Top-level `session.json` written when Phase 1 finishes. Holds the pyramid
/// table + crop spec + ordered list of set-folder names. The Phase 2 processor
/// reads this first to know which sets to walk.
struct SessionSidecar: Codable, Sendable, Equatable {
    let sessionId: String
    let startedAt: Date
    let endedAt: Date
    let captured: Int                  // total non-placeholder frames across all sets
    let skipped: [Int]                 // global linear slot indices (0..<64) that were skipped
    let crop: CropSpec
    let byteOrder: String              // "MM" or "II"
    let pyramid: [Int]                 // PyramidTable.pyramid, persisted for forward-compat
    let setFolders: [String]           // ["set-00", "set-01", ..., "set-15"]

    func write(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> SessionSidecar {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SessionSidecar.self, from: try Data(contentsOf: url))
    }
}
