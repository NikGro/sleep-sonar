import UIKit

/// Querformat nur während einer laufenden Aufnahme (z. B. iPhone quer im Dock), sonst Hochformat.
@MainActor
enum Orientation {
    static var allowLandscape = false

    static func recordingChanged(_ running: Bool) {
        allowLandscape = running
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !running {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Orientation.allowLandscape ? .allButUpsideDown : .portrait }
    }
}
