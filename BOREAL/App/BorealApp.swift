import SwiftUI

@main
struct BorealApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Linkage canary: a missing -lborealkernel fails here, at launch.
        Kernel.keepalive()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .background(Theme.bg.ignoresSafeArea())   // never a white frame underneath
                // Cover the UI with black whenever the app isn't active, so the
                // app-switcher snapshot / resume never flashes the previous screen
                // (the captured photo or review) — and the launch reads as black.
                .overlay {
                    if scenePhase != .active {
                        Theme.bg.ignoresSafeArea().transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: scenePhase)
        }
    }
}
