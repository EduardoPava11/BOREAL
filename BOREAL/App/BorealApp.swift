import SwiftUI

@main
struct BorealApp: App {
    @State private var coordinator = AppCoordinator()

    init() {
        // Force-link the Zig kernel by referencing one of its symbols.
        // Without this, the linker drops the unused `-lborealkernel` archive
        // and item 4's `Decoder.swift` calls would fail at runtime with
        // "symbol not found." Cheap startup cost; verifies linkage at launch.
        BorealKernel.keepalive()
    }

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environment(coordinator)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
