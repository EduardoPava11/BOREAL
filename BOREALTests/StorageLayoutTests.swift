import XCTest
@testable import BOREAL

/// Verifies the per-set folder layout produced by `Storage.prepareSessionFolder()`
/// and the path helpers that compose `set-NN/frame-M.dng` URLs. These tests
/// guard the Phase 1 on-disk contract that Phase 2 will read against.
final class StorageLayoutTests: XCTestCase {

    override func setUpWithError() throws {
        // Each test starts from a wiped session tree.
        try Storage.prepareSessionFolder()
    }

    func testPrepareCreates16SetDirectoriesEachWithStaging() {
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: Storage.sessionRoot.path))
        for setIdx in 0..<PyramidTable.setCount {
            var isDir: ObjCBool = false
            let setDir = Storage.setDir(setIdx: setIdx)
            XCTAssertTrue(fm.fileExists(atPath: setDir.path, isDirectory: &isDir),
                          "set-\(setIdx) directory missing")
            XCTAssertTrue(isDir.boolValue, "set-\(setIdx) is not a directory")

            let stagingDir = Storage.stagingDir(setIdx: setIdx)
            XCTAssertTrue(fm.fileExists(atPath: stagingDir.path, isDirectory: &isDir),
                          "set-\(setIdx)/staging missing")
            XCTAssertTrue(isDir.boolValue, "set-\(setIdx)/staging is not a directory")
        }
    }

    func testFrameURLComposesSetNNFrameM() {
        let url = Storage.frameURL(setIdx: 3, frameInSet: 2)
        XCTAssertEqual(url.lastPathComponent, "frame-2.dng")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "set-03")
    }

    func testStagingURLComposesSetNNStagingFrameM() {
        let url = Storage.stagingURL(setIdx: 15, frameInSet: 0)
        XCTAssertEqual(url.lastPathComponent, "frame-0.dng")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "staging")
        XCTAssertEqual(url.deletingLastPathComponent()
                          .deletingLastPathComponent().lastPathComponent, "set-15")
    }

    func testSlotPathRoundTrip() {
        for slot in 0..<PyramidTable.totalFrameCount {
            let p = Storage.slotPath(slot: slot)
            XCTAssertEqual(p.setIdx, slot / 4)
            XCTAssertEqual(p.frameInSet, slot % 4)
            XCTAssertTrue(p.setIdx < PyramidTable.setCount)
            XCTAssertTrue(p.frameInSet < PyramidTable.framesPerSet)
        }
    }

    func testCapturedFrameRelativePathMatchesStorage() {
        // CapturedFrame.fileName must be a relative path that, joined to sessionRoot,
        // equals Storage.frameURL for the same (setIdx, frameInSet). This is the
        // contract Phase 2 readers will rely on.
        for slot in [0, 1, 4, 7, 31, 60, 63] {
            let f = CapturedFrame.real(slot: slot,
                                       hwTimestampNanos: 0,
                                       wallClock: Date())
            let composed = Storage.sessionRoot.appendingPathComponent(f.fileName)
            let direct = Storage.frameURL(setIdx: f.setIdx, frameInSet: f.frameInSet)
            XCTAssertEqual(composed.standardizedFileURL, direct.standardizedFileURL,
                           "slot \(slot) path mismatch")
        }
    }

    func testSetSidecarRoundTrip() throws {
        let frames = (0..<PyramidTable.framesPerSet).map { fIdx in
            CapturedFrame.real(slot: 7 * PyramidTable.framesPerSet + fIdx,
                               hwTimestampNanos: Int64(fIdx) * 1_000_000,
                               wallClock: Date(timeIntervalSince1970: Double(fIdx)))
        }
        let sidecar = SetSidecar(setIdx: 7,
                                 codeBudget: PyramidTable.codeBudget(setIdx: 7),
                                 captured: 4,
                                 skipped: [],
                                 frames: frames)
        let url = Storage.setSidecarURL(setIdx: 7)
        try sidecar.write(to: url)
        let read = try SetSidecar.read(from: url)
        XCTAssertEqual(read, sidecar)
        XCTAssertEqual(read.codeBudget, 64)   // pyramid[7]
    }

    func testSessionSidecarRoundTrip() throws {
        let setFolders = (0..<PyramidTable.setCount).map { String(format: "set-%02d", $0) }
        let sidecar = SessionSidecar(sessionId: "test-uuid",
                                     startedAt: Date(timeIntervalSince1970: 0),
                                     endedAt: Date(timeIntervalSince1970: 1),
                                     captured: 64,
                                     skipped: [],
                                     crop: .default,
                                     byteOrder: "MM",
                                     pyramid: PyramidTable.pyramid,
                                     setFolders: setFolders)
        let url = Storage.sessionSidecarURL()
        try sidecar.write(to: url)
        let read = try SessionSidecar.read(from: url)
        XCTAssertEqual(read, sidecar)
        XCTAssertEqual(read.pyramid.reduce(0, +), 256)
    }
}
