import UIKit

// Standalone diagnostic entry point. Never include this file in Rendprop.
@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = SpatialCaptureViewController()
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
