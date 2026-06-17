import SwiftUI

@main
struct BorealApp: App {
    init() {
        // Linkage canary: a missing -lborealkernel fails here, at launch.
        Kernel.keepalive()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
