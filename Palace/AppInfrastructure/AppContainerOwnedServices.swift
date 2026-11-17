//
//  AppContainerOwnedServices.swift
//  Palace
//
//  Storage for the services each `AppContainer` owns, and the link a
//  container uses to reach it.
//

import PalaceCatalog

/// Services that belong to one container: each captures that container's
/// collaborators, so sharing one across containers would route its effects to
/// another container's accounts manager, registry or network session. Built
/// lazily on first read (the members are `@MainActor`); the initializer touches
/// no isolated state, so a container can still be built on any thread.
///
/// Process-wide services (audiobook session and presenter, playback
/// bootstrapper, sample preview, rating, side-loading, book-open tracker,
/// offline-queue coordinator) stay in `AppContainer`'s statics.
@MainActor
final class AppContainerOwnedServices {
    var signInModalSheetPresenter: SignInModalSheetPresenter?
    var bookCellModelCache: BookCellModelCache?
    var catalogAPI: DefaultCatalogAPI?
    var catalogRepository: CatalogRepositoryProtocol?

    nonisolated init() {}
}

/// Weak reference to a container's owned services, held by `nonOwningCopy()`.
struct WeakOwnedServices {
    weak var storage: AppContainerOwnedServices?

    init(_ storage: AppContainerOwnedServices) {
        self.storage = storage
    }
}

/// How a container reaches its owned services: owning them, or (in the
/// copy a service holds of its own container) through a weak reference.
enum OwnedServicesLink {
    case owner(AppContainerOwnedServices)
    case nonOwning(WeakOwnedServices)
}
