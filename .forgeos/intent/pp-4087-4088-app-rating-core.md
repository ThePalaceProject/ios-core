---
name: pp-4087-4088-app-rating-core
created: 2026-07-02
author: claude-opus-4-8
---

**ADR refs:** extends `adr_059bdb6c` (MVVM + Services + Reducers triad — AppContainer
as DI root; closure/pure-function reducers). `AppRatingService` is registered via the
AppContainer lazy-cache pattern and `RatingEligibilityPolicy` is a pure function in the
reducer spirit. Complies with `adr_204fafdd` (superpartner-spectrum: every new function /
enum case / state change ships with a matching test). Not a critical-path module per
`adr_52261f2a` (mutation regex covers auth/borrow/download/DRM/audiobooks/accounts/network;
AppRating is outside it) — PR 1 deliberately avoids `BorrowOperation` and the audiobook
seams so it stays off the strict-gate surface; those trigger-wirings land in PR 2.

This is PR 1 of 2 for Epic PP-4086 (App Rating Prompt). It implements the engagement
tracking (PP-4087) and the eligibility policy (PP-4088). No UI, no StoreKit request, no
sentiment-gate dialog — those land in PR 2 (PP-4089/4090/4091). PR 1 is mergeable
standalone: it records engagement signals and can evaluate eligibility, but never presents
anything.

## Claims

- adds new module group `Palace/AppRating/`
- adds struct `RatingEngagementState` capturing sessionCount, booksCompleted, lastPromptDate, promptDisplayCount, dismissalCount, optedOut, crashFreeLastSession and a computed isFirstSession
- adds class `RatingEngagementTracker` in `Palace/AppRating/RatingEngagementTracker.swift` that reads/writes engagement signals through an injected settings store
- adds struct `RatingConfig` in `Palace/AppRating/RatingConfig.swift` holding the tunable thresholds (minSessions, minBooksCompleted, cooldownDays, lifetimePromptCap) with a hardcoded `.fallback` default
- adds enum `RatingEligibilityPolicy` with static function `evaluate(state:config:now:) -> Bool` in `Palace/AppRating/RatingEligibilityPolicy.swift` implementing all 7 criteria
- adds enum `AppRatingTrigger` (`.bookCompleted`, `.borrowSucceeded`) in `Palace/AppRating/AppRatingService.swift`
- adds class `AppRatingService` (`@MainActor`) in `Palace/AppRating/AppRatingService.swift` exposing `recordSession()`, `recordBookCompleted()`, `recordPromptShown()`, `recordDismissal()`, `recordOptOut()`, and `isEligible(for:) -> Bool` — no presentation logic in PR 1
- adds engagement-signal keys and computed properties to `TPPSettings` (appRatingSessionCount, appRatingBooksCompleted, appRatingLastPromptDate, appRatingPromptDisplayCount, appRatingDismissalCount, appRatingOptedOut, appRatingCrashFreeLastSession)
- adds the mirrored properties to `TPPSettingsProviding`
- adds numeric remote-config accessor `getDoubleValue(forKey:)` to `FirebaseManager`
- adds `wasLastSessionCrashFree() -> Bool` (Crashlytics-backed, best-effort) to `FirebaseManager`
- adds `app_rating_*` keys (prompt_enabled master switch + 4 numeric thresholds) to `FirebaseManager.RemoteConfigKey` and their default values
- adds `isAppRatingPromptEnabled` and `appRatingConfig` accessors to `RemoteFeatureFlags` that source values from remote config with fallback
- adds lazy-cached `appRatingService` registration to `AppContainer` (+ nil-reset in `_resetForTesting`)
- adds session-count increment call at `TPPAppDelegate.applicationDidBecomeActive`
- adds tests `RatingEngagementTrackerTests`, `RatingEligibilityPolicyTests`, `AppRatingServiceTests` under `PalaceTests/AppRating/`

## Anti-claims

- does NOT add any UI, SwiftUI view, dialog, or sheet (deferred to PR 2 / PP-4089)
- does NOT call `SKStoreReviewController` or request any App Store review (deferred to PR 2 / PP-4090)
- does NOT add any feedback / mailto path (deferred to PR 2 / PP-4091)
- does NOT modify `BorrowOperation.swift`, `AudiobookLoader.swift`, `AudiobookSessionManager.swift`, or any `Palace/Reader2/` file — the book-completion / borrow / EPUB triggers wire in PR 2
- leaves `TPPAppStoreReviewPrompt` untouched — its supersession happens in PR 2
- does NOT change `TPPBookRegistry` public surface
- does NOT change `AppContainer`'s init signature or any copy-constructor param list (uses the lazy-cache computed-property pattern, not an eager `let`)
- does NOT transmit any engagement data off-device (all signals are local UserDefaults)

## Files in scope

- Palace/AppRating/RatingEngagementTracker.swift
- Palace/AppRating/RatingEligibilityPolicy.swift
- Palace/AppRating/RatingConfig.swift
- Palace/AppRating/AppRatingService.swift
- Palace/Settings/TPPSettings.swift
- Palace/Settings/TPPSettingsProviding.swift
- Palace/AppInfrastructure/FirebaseManager.swift
- Palace/FeatureFlags/RemoteFeatureFlags.swift
- Palace/AppInfrastructure/AppContainer.swift
- Palace/AppInfrastructure/TPPAppDelegate.swift
- PalaceTests/AppRating/RatingEngagementTrackerTests.swift
- PalaceTests/AppRating/RatingEligibilityPolicyTests.swift
- PalaceTests/AppRating/AppRatingServiceTests.swift
- PalaceTests/Mocks/TPPSettingsMock.swift
- Palace.xcodeproj/project.pbxproj
