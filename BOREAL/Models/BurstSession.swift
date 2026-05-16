import Foundation

struct BurstSession: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let targetFrameCount: Int        // 64
    var frames: [CapturedFrame]
    let folder: URL                  // <AppSupport>/BorealSession/

    static func make(targetFrameCount: Int = 64) throws -> BurstSession {
        let folder = try Storage.prepareSessionFolder()
        return BurstSession(
            id: UUID(),
            startedAt: Date(),
            targetFrameCount: targetFrameCount,
            frames: [],
            folder: folder
        )
    }
}
