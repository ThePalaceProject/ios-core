---
name: forgeos-lint-exclude-active-swarms
type: evolving
status: active
created: 2026-05-26
last_refresh: 2026-05-26
freshness_window: 365d
owners: [general]
description: Files claimed by non-complete swarms — excluded from this cleanup PR
---

# Files claimed by non-complete swarms — excluded from this cleanup PR
# Generated 2026-05-22T16:05:16Z from .forgeos/swarms/*/manifest.yaml status != complete

## Sources
- swarm_81b5099e (triaged): Account state machine Phase 2
- swarm_d5a3d473 (bundled): Singleton sweep Tracks A/B
- swarm_dfdaf7ad (bundled): HelpSpot 17865/17923/17870

## Excluded files (37 claimed; 16 overlap our cleanup candidates)
- Palace/Accounts/AgeCheck/TPPAgeCheck.swift
- Palace/Accounts/Library/Account+State.swift
- Palace/Accounts/Library/AccountsManager.swift
- Palace/Accounts/Library/AccountStateStore.swift
- Palace/AppInfrastructure/AppContainer.swift
- Palace/AppInfrastructure/TPPAppDelegate.swift
- Palace/Audiobooks/AudiobookSessionManager.swift
- Palace/Audiobooks/NowPlayingCoordinator.swift
- Palace/Book/Models/BookRegistrySync.swift
- Palace/Book/Models/TPPBook.swift
- Palace/Book/Models/TPPBook+Presentation.swift
- Palace/Book/Models/TPPBookCoverRegistry.swift
- Palace/Book/Models/TPPBookRegistry.swift
- Palace/Book/Models/TPPBookRegistryAsync.swift
- Palace/CarPlay/CarPlayAudiobookBridge.swift
- Palace/CarPlay/CarPlayImageProvider.swift
- Palace/Logging/AudiobookFileLogger.swift
- Palace/Logging/TPPErrorLogger.swift
- Palace/MyBooks/MyBooks/BookListView.swift
- Palace/Notifications/NotificationService.swift
- Palace/OPDS2/Models/OPDS2PublicationExtended.swift
- Palace/OPDS2/OPDSFeedService.swift
- Palace/OPDS2/Service/UnifiedOPDSService.swift
- Palace/Packages/PalaceLogging/Sources/PalaceLogging/PersistentLogger.swift
- Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift
- Palace/Reader2/ReaderStackConfiguration/LCP/LCPPassphraseAuthenticationService.swift
- Palace/Settings/AccountDetailView.swift
- Palace/Settings/Debug/DebugSettings.swift
- Palace/SignInLogic/LegacySAMLAuthAdapter.swift
- Palace/SignInLogic/TPPSignInBusinessLogic.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift
- Palace/SignInLogic/TPPSignInBusinessLogic+OAuth.swift
- Palace/Utilities/DeviceSpecificErrorMonitor.swift
- Palace/Utilities/ImageCache/ImageCacheType.swift
- Palace/Utilities/ImageCache/ImageLoaderImpl.swift
- Palace/Utilities/ImageCache/ImageLoading.swift
- Palace/Utilities/Localization/Strings.swift
