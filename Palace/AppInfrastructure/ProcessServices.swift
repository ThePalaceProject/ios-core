//
//  ProcessServices.swift
//  Palace
//
//  The services that live for the whole process, and the link a container
//  uses to reach them.
//

import Combine
import os

/// Services that live as long as the process: one audiobook session, one
/// play-time queue, one offline-queue executor. The app builds one instance in
/// `AppContainer._buildCachedAppContainer()`, and every copy of that container
/// shares it, so CarPlay, the lock screen and the phone UI drive one session.
/// A separately built container (a test's) gets its own instance, so its
/// services are wired to its own graph.
///
/// The `@MainActor` cells are built lazily by `AppContainer`. The side-loading
/// cells and the offline-queue slot are lock-guarded because they are first
/// read off the main actor.
final class ProcessServices: @unchecked Sendable {
    @MainActor var samplePreviewManager: SamplePreviewManager?
    @MainActor var audiobookSession: AudiobookSessionManager?
    @MainActor var backgroundPlaybackTrimmer: BackgroundPlaybackMemoryTrimmer?
    @MainActor var audiobookSessionPresenter: AudiobookSessionPresenter?
    @MainActor var playbackBootstrapper: PlaybackBootstrapper?
    @MainActor var appRatingService: AppRatingService?
    @MainActor var ratingPromptPresenter: RatingPromptPresenter?
    @MainActor var activityPolicy: ActivityPolicy?
    @MainActor var playtimeUploader: AudiobookDataManager?

    let sideloadedBookRegistry = OSAllocatedUnfairLock<SideloadedBookRegistry?>(initialState: nil)
    let sideloadedBookManager = OSAllocatedUnfairLock<SideloadedBookManager?>(initialState: nil)
    /// Keeps the coordinator alive so its `[weak self]` executor closure does;
    /// `AppContainer.ensureOfflineQueueExecutorRegistered()` fills it once.
    let offlineQueueCoordinator = OSAllocatedUnfairLock<OfflineQueueCoordinator?>(initialState: nil)

    private let accountSwitchSubscription = OSAllocatedUnfairLock<AnyCancellable?>(uncheckedState: nil)

    init() {}

    /// The cells that hold state for the current library.
    @MainActor
    func accountScopedServices() -> [AccountScopedResetting] {
        [playtimeUploader].compactMap { $0 }
    }

    /// Resets this container's per-library services on each `.willSwitch`
    /// `switches` sends. The event arrives on the main thread before the switch
    /// cleanup when the switch is made on main (see `MainThreadBroadcaster`).
    func resetAccountScopedServices(
        on switches: AnyPublisher<CurrentLibraryChange, Never>,
        ownedServices: AppContainerOwnedServices
    ) {
        let subscription = switches.sink { [weak self, weak ownedServices] change in
            guard case .willSwitch = change else { return }
            MainActor.assumeIsolated {
                let services = (self?.accountScopedServices() ?? []) + (ownedServices?.accountScopedServices() ?? [])
                services.forEach { $0.resetForAccountSwitch() }
            }
        }
        accountSwitchSubscription.withLockUnchecked { $0 = subscription }
    }
}

/// Weak reference to a container's process services, held by `nonOwningCopy()`.
struct WeakProcessServices {
    weak var services: ProcessServices?

    init(_ services: ProcessServices) {
        self.services = services
    }
}

/// How a container reaches its process services: owning them, or (in the
/// copy a service holds of its own container) through a weak reference, so
/// the services and the container do not retain each other.
enum ProcessServicesLink {
    case owner(ProcessServices)
    case nonOwning(WeakProcessServices)
}
