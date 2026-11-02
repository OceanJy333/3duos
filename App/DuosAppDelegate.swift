// Input: the iOS application and its window scene.
// Output: one independent 3duos window rooted in the game library.
// Pos: standalone app lifecycle entry.

import UIKit

@main
final class DuosAppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        true
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        window?.rootViewController?.supportedInterfaceOrientations ?? .all
    }
}

final class DuosSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = RootController()
        window.makeKeyAndVisible()
        self.window = window
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        let root = window?.rootViewController as? RootController
        root?.setSceneActive(true)
        root?.updateConsoleOrientation()
    }

    func sceneWillResignActive(_ scene: UIScene) {
        (window?.rootViewController as? RootController)?.setSceneActive(false)
    }

    func windowScene(_ windowScene: UIWindowScene, didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry) {
        (window?.rootViewController as? RootController)?.updateConsoleOrientation()
    }
}
