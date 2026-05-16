import SwiftUI

@main
struct BorealApp: App {
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            CameraView()
                .environment(coordinator)
                .preferredColorScheme(.dark)
                .statusBarHidden()
        }
    }
}
