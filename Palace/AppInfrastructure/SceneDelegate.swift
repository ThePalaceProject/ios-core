//
//  SceneDelegate.swift
//  Palace
//
//  Created for scene-based app lifecycle support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import UIKit
import SwiftUI
import PalaceLogging

/// Scene delegate for the main app window.
/// Required when using UIApplicationSceneManifest for CarPlay support.
class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    /// Tracks whether the main phone scene has connected at least once.
    /// Used by CarPlay to determine if user has the phone app open.
    static var hasMainSceneConnected = false

    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }

        guard session.role == .windowApplication else {
            Log.info(#file, "Ignoring non-application scene role: \(session.role.rawValue)")
            return
        }

        Log.info(#file, "📱 Main app scene connecting")
        SceneDelegate.hasMainSceneConnected = true

        // when running as "Designed for iPad" on Apple Silicon Macs
        // the default window size (~715x800pt) is undersized for Mac monitors.
        // Set a Mac-class minimum and request a larger initial geometry so the
        // first-launch experience uses the available screen real estate.
        // ProcessInfo.isiOSAppOnMac is false on iPad / iPhone — guard ensures
        // no behavioral change on those platforms.
        Self.applyMacWindowGeometry(to: windowScene)

        // Create window for this scene
        let newWindow = UIWindow(windowScene: windowScene)
        newWindow.tintColor = TPPConfiguration.mainColor()
        newWindow.tintAdjustmentMode = .normal

        // Create root view controller directly to avoid any timing issues
        let container = AppContainer.production()
        let rootView = AppTabHostView()
            .environment(\.appContainer, container)
        let hostingController = UIHostingController(rootView: rootView)
        newWindow.rootViewController = hostingController
        newWindow.makeKeyAndVisible()

        // Instrument first-frame timing (AppLaunchTracker). The window is now
        // key + visible, so the initial frame is committed; paired with
        // `processStart` (recorded in TPPAppDelegate) this yields timeToFirstFrame.
        Task {
            await AppLaunchTracker.shared.recordMilestone(.firstFrame)
        }

        window = newWindow

        // Also set on AppDelegate for backward compatibility
        if let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate {
            appDelegate.window = newWindow
        }

        Log.info(#file, "📱 Main app window configured successfully")

        // Handle any URLs passed at launch
        if let urlContext = connectionOptions.urlContexts.first {
            let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate
            _ = appDelegate?.application(UIApplication.shared, open: urlContext.url, options: [:])
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        Log.info(#file, "📱 Main app scene disconnected")
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        // Restart any tasks paused when scene was inactive
    }

    func sceneWillResignActive(_ scene: UIScene) {
        // Called when scene will move to inactive state
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
        // Called as scene transitions from background to foreground
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        // Save data, release resources, store scene state
    }

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url else { return }
        let appDelegate = UIApplication.shared.delegate as? TPPAppDelegate
        _ = appDelegate?.application(UIApplication.shared, open: url, options: [:])
    }

    // MARK: - PP-4289 Mac geometry

    /// Mac-friendly default window dimensions (in points) for "Designed for iPad"
    /// on Apple Silicon Macs. Pulled out as a constant so tests can assert without
    /// instantiating a UIWindowScene.
    static let macPreferredWindowSize = CGSize(width: 1100, height: 800)
    static let macMinimumWindowSize = CGSize(width: 700, height: 500)

    /// Apply iPadOnMac-only window size hints. No-op on iPhone / iPad. The
    /// `requestGeometryUpdate` is best-effort — older macOS versions may
    /// ignore the size hint, but the minimum-size restriction always sticks
    /// and prevents the window from being shrunk into a broken layout.
    static func applyMacWindowGeometry(to windowScene: UIWindowScene) {
        guard ProcessInfo.processInfo.isiOSAppOnMac else { return }

        windowScene.sizeRestrictions?.minimumSize = macMinimumWindowSize

        let preferences = UIWindowScene.GeometryPreferences.Mac(
            systemFrame: CGRect(origin: .zero, size: macPreferredWindowSize)
        )
        windowScene.requestGeometryUpdate(preferences) { error in
            Log.info(#file, "Mac initial-size request rejected: \(error.localizedDescription)")
        }
    }
}
