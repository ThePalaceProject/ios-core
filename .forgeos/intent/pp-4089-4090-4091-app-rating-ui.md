---
name: pp-4089-4090-4091-app-rating-ui
created: 2026-07-02
author: claude-opus-4-8
---

**ADR refs:** extends `adr_059bdb6c` (MVVM + Services + Reducers — AppContainer DI
root; the routing logic is a pure, testable seam on `AppRatingService`). Complies
with `adr_204fafdd` (superpartner-spectrum) and `adr_3e2c6a3c` (present-during-
transition: the gate is an in-`ZStack` overlay, not a `present()` racing a
transition coordinator). Touches critical paths `Palace/MyBooks/BorrowOperation.swift`
and `Palace/Audiobooks/AudiobookLoader.swift` (both in `adr_52261f2a`'s strict
mutation regex) — trigger hooks there are single-line insertions gated on the
new service; the risk-bearing decision logic stays in the testable service.

PR 2 of 2 for Epic PP-4086. Adds the sentiment-gate UI (PP-4089), native StoreKit
request (PP-4090), and feedback path (PP-4091), plus the three positive-moment
triggers and a Developer Settings force-eligibility/reset hook (enables QA PP-4092
and the simdrive suite PP-4716). Stacked on the PR 1 branch.

## Claims

- adds SwiftUI `SentimentGateView` in `Palace/AppRating/SentimentGateView.swift` — the "Are you enjoying The Palace Project?" card + the "share feedback?" follow-up, VoiceOver + Dynamic Type + Dark Mode
- adds `RatingPromptPresenter` (`@MainActor ObservableObject`) in `Palace/AppRating/RatingPromptPresenter.swift` with a published `step: RatingPromptStep?` and the routing methods `handleTrigger(_:)`, `respondPositive()`, `respondNegative()`, `confirmFeedback()`, `declineFeedback()`, `respondAskLater()`, `dismiss()`
- adds protocol `ReviewRequesting` and `RatingReviewRequester` (SKStoreReviewController wrapper) in `Palace/AppRating/RatingReviewRequester.swift`
- adds protocol `FeedbackPresenting` and `RatingFeedbackPresenter` (reuses `ProblemReportEmail`, support@thepalaceproject.org, mailto fallback) in `Palace/AppRating/RatingFeedbackPresenter.swift`
- adds `resetEngagementState()` to `AppRatingService` and a force-eligible bypass in `isEligible(for:)`
- adds `reset()` to `RatingEngagementTracker`
- adds `appRatingForceEligibleLocalOverrideKey` + `isAppRatingForceEligible` to `RemoteFeatureFlags`
- adds `ratingPromptPresenter` lazy-cache registration to `AppContainer` and wires the force-eligible provider into `appRatingService`
- adds a sentiment-gate overlay layer to `AppTabHostView`'s root `ZStack`
- adds a "Force rating-prompt eligible" toggle row and a "Reset rating state" action row to `TPPDeveloperSettingsTableViewController`
- migrates all four `TPPAppStoreReviewPrompt.presentIfAvailable()` end-of-book call sites (both branches of `presentEndOfBookAlert` in `BookAvailabilityFormatter.swift` and `BookDetailViewModel.swift`) to route through `AppRatingService` via `noteBookCompleted()`. This also covers the audiobook completion path, since `AudiobookLoader`'s `playbackCompletionHandler` calls `BookDetailViewModel.presentEndOfBookAlert` — no direct `AudiobookLoader` edit is needed.
- adds a borrow-succeeded trigger after `announceBorrowSucceeded` in `BorrowOperation.swift`
- adds an EPUB end-of-book (`totalProgression >= 0.99`) trigger in `TPPEPUBViewController.swift`
- adds tests under `PalaceTests/AppRating/` for routing, requester, feedback, presenter, and trigger eligibility

## Anti-claims

- does NOT change `RatingEligibilityPolicy` — the PR 1 policy is reused unchanged
- does NOT present the gate via `.fullScreenCover` or a `present()` racing a transition coordinator (uses an in-`ZStack` overlay)
- does NOT add XCTest image-snapshot tests — visual regression is covered by the simdrive suite (PP-4716); the XCTest layer stays deterministic behavior/routing tests
- does NOT offer any incentive for a rating and presents NO custom star-rating UI (only the system prompt) — §5.6.1
- does NOT change `TPPBookRegistry` public surface
- does NOT modify the borrow/download state machine in `BorrowOperation` beyond the single post-success trigger call
- does NOT delete `TPPAppStoreReviewPrompt` (left in place; its call sites are re-routed)

## Files in scope

- Palace/AppRating/SentimentGateView.swift
- Palace/AppRating/RatingPromptPresenter.swift
- Palace/AppRating/RatingReviewRequester.swift
- Palace/AppRating/RatingFeedbackPresenter.swift
- Palace/AppRating/AppRatingService.swift
- Palace/AppRating/RatingEngagementTracker.swift
- Palace/FeatureFlags/RemoteFeatureFlags.swift
- Palace/AppInfrastructure/AppContainer.swift
- Palace/AppInfrastructure/AppTabHostView.swift
- Palace/Settings/DeveloperSettings/TPPDeveloperSettingsTableViewController.swift
- Palace/Book/UI/BookDetail/BookAvailabilityFormatter.swift
- Palace/Book/UI/BookDetail/BookDetailViewModel.swift
- Palace/MyBooks/BorrowOperation.swift
- Palace/Reader2/UI/TPPEPUBViewController.swift
- Palace/Utilities/Localization/Strings.swift
- PalaceTests/AppRating/RatingPromptPresenterTests.swift
- PalaceTests/AppRating/RatingFeedbackPresenterTests.swift
- PalaceTests/AppRating/AppRatingServiceOverrideTests.swift
- Palace.xcodeproj/project.pbxproj
