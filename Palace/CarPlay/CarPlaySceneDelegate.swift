//
//  CarPlaySceneDelegate.swift
//  Palace
//
//  Created for CarPlay audiobook support.
//  Copyright © 2026 The Palace Project. All rights reserved.
//

import CarPlay
import Combine
import PalaceLogging

/// CarPlay scene delegate that manages the CarPlay interface lifecycle
/// and coordinates audiobook playback from the vehicle's infotainment system.
/// Note: This class is referenced by name in Info.plist as "CarPlaySceneDelegate"
// `@MainActor`: a `UIResponder`-derived CarPlay scene delegate. `UIResponder` and
// `CPTemplateApplicationSceneDelegate` are both main-actor isolated, and every
// callback drives main-actor CarPlay UI. Annotating the type is the `complete`-mode
// fix for the "conformance crosses into the main actor" warning on
// `CPTemplateApplicationSceneDelegate`; all members are already main-only.
//
// `@preconcurrency` on the `CPTemplateApplicationSceneDelegate` conformance: the
// protocol's requirements are declared `nonisolated` by CarPlay (not yet
// Sendable/isolation-audited upstream), so a `@MainActor` type satisfying them
// still trips "conformance crosses into main actor-isolated code." Every callback
// is delivered on the main thread by CarPlay, so the `@preconcurrency` conformance
// is the honest ceiling until Apple annotates the protocol.
@MainActor
@objc(CarPlaySceneDelegate)
final class CarPlaySceneDelegate: UIResponder, @preconcurrency CPTemplateApplicationSceneDelegate {

    // MARK: - Properties

    private var interfaceController: CPInterfaceController?
    private var templateManager: CarPlayTemplateManager?
    private var cancellables = Set<AnyCancellable>()
    private let bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController

        // Check feature flag - if CarPlay is disabled, show coming soon message
        guard RemoteFeatureFlags.shared.isCarPlayEnabledCached else {
            Log.info(#file, "🚗 CarPlay scene connected but feature is DISABLED - showing coming soon message")
            showComingSoonTemplate(interfaceController: interfaceController)
            return
        }

        Log.info(#file, "🚗 CarPlay scene connected - setting up templates")

        AppContainer.production().playbackBootstrapper.ensureInitializedForCarPlay()

        // Defensive: if a prior manager is somehow still held (a second
        // didConnect without an intervening didDisconnect), tear it down first
        // so its Now Playing observer registration is removed on the main actor
        // before we drop the reference — otherwise it would dangle on the shared
        // CPNowPlayingTemplate.
        templateManager?.tearDown()
        self.templateManager = CarPlayTemplateManager(interfaceController: interfaceController)

        // Set up the root template
        templateManager?.setupRootTemplate()

        // Subscribe to book registry changes to refresh the library
        subscribeToBookRegistryChanges()

        Log.info(#file, "🚗 CarPlay setup complete")
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        Log.info(#file, "🚗 CarPlay disconnected")

        cancellables.removeAll()
        // Remove the Now Playing observer on the main actor BEFORE releasing the
        // manager. This replaces the former deinit-time removal (unrepresentable
        // under Swift 6 strict concurrency) and makes removal deterministic
        // regardless of when the manager actually deallocs.
        templateManager?.tearDown()
        templateManager = nil
        self.interfaceController = nil

        // Note: We don't stop playback on CarPlay disconnect since:
        // 1. User might still be listening on phone
        // 2. Phone app UI may still be showing the player
        // Playback lifecycle is managed by AudiobookSessionManager
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didSelect navigationAlert: CPNavigationAlert
    ) {
        // Handle navigation alerts if needed
    }

    // MARK: - Private Methods

    private func showComingSoonTemplate(interfaceController: CPInterfaceController) {
        // Create a list template with a "Coming Soon" message
        // Note: Audio apps can only use CPListTemplate, not CPInformationTemplate

        // Create and resize the Palace logo for CarPlay
        let logoImage = createCarPlayLogo()

        // Header item with Palace logo
        let headerItem = CPListItem(
            text: "Palace",
            detailText: "CarPlay Support Coming Soon"
        )
        headerItem.isEnabled = false
        if let logo = logoImage {
            headerItem.setImage(logo)
        }

        // Feature description
        let featureItem = CPListItem(
            text: "Audiobook Playback",
            detailText: "Listen while you drive"
        )
        featureItem.isEnabled = false
        featureItem.setImage(UIImage(systemName: "headphones"))

        // Status update
        let statusItem = CPListItem(
            text: "Under Development",
            detailText: "Stay tuned for updates"
        )
        statusItem.isEnabled = false
        statusItem.setImage(UIImage(systemName: "hammer.fill"))

        // Alternative suggestion
        let alternativeItem = CPListItem(
            text: "Use Palace App",
            detailText: "Enjoy audiobooks on your device"
        )
        alternativeItem.isEnabled = false
        alternativeItem.setImage(UIImage(systemName: "iphone"))

        let section = CPListSection(
            items: [headerItem, featureItem, statusItem, alternativeItem],
            header: nil,
            sectionIndexTitle: nil
        )

        let comingSoonTemplate = CPListTemplate(title: "Palace", sections: [section])

        interfaceController.setRootTemplate(comingSoonTemplate, animated: true, completion: nil)
    }

    private func createCarPlayLogo() -> UIImage? {
        // Try to load the Palace logo from assets
        guard let logoImage = UIImage(named: "LaunchImageLogo") ?? UIImage(named: "WelcomeLogo") else {
            return nil
        }

        // Resize for CarPlay list item (recommended size is around 90x90 points)
        let size = CGSize(width: 90, height: 90)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { _ in
            // Calculate aspect-fit rect to maintain logo proportions
            let aspectRatio = logoImage.size.width / logoImage.size.height
            var drawRect = CGRect(origin: .zero, size: size)

            if aspectRatio > 1 {
                // Wider than tall
                drawRect.size.height = size.width / aspectRatio
                drawRect.origin.y = (size.height - drawRect.size.height) / 2
            } else {
                // Taller than wide
                drawRect.size.width = size.height * aspectRatio
                drawRect.origin.x = (size.width - drawRect.size.width) / 2
            }

            logoImage.draw(in: drawRect)
        }
    }

    private func subscribeToBookRegistryChanges(bookRegistry: TPPBookRegistryProvider = AppContainer.production().bookRegistry) {
        // Subscribe to registry changes (fires when books are loaded from disk or synced)
        bookRegistry.registryPublisher
            .dropFirst() // Skip initial empty state
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Log.debug(#file, "Registry updated - refreshing CarPlay library")
                self?.templateManager?.refreshLibrary()
            }
            .store(in: &cancellables)

        // Also subscribe to individual book state changes (download progress, etc.)
        bookRegistry.bookStatePublisher
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.templateManager?.refreshLibrary()
            }
            .store(in: &cancellables)

        // Subscribe to account changes to update library name.
        // `.receive(on: DispatchQueue.main)` guards the same Swift 6 bug class as
        // the AccountDetailViewModel fix: this closure is `@MainActor`-isolated
        // (calls `templateManager` on the main actor), and NotificationCenter
        // delivers synchronously on the posting thread. Every current
        // `.TPPCurrentAccountDidChange` poster is on main, so this is defensive —
        // but it was the lone bare sink here (the two registry sinks above hop
        // via `.debounce(scheduler: DispatchQueue.main)`), so a future off-main
        // poster would trap. Match the siblings.
        NotificationCenter.default.publisher(for: .TPPCurrentAccountDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Log.info(#file, "🚗 Account changed - updating CarPlay library name and refreshing")
                self?.templateManager?.updateLibraryName()
                self?.templateManager?.refreshLibrary()
            }
            .store(in: &cancellables)
    }
}
