---
name: pp-5022-read-button-dead
created: 2026-08-31
author: claude-opus-5
---

**ADR refs:** none queried — ForgeOS governance is OFF in this environment
(`FORGEOS_ENABLED=0`), so the ADR ledger was not consulted. The touched area's
prose contract is `Palace/AppInfrastructure/NavigationCoordinator.swift` +
`NavigationHostView.swift` comments.

## Context

PP-5022: on My Books the Read button stops opening a downloaded book — no
spinner, no error, nothing. Reproduced on the simulator: `NavigationCoordinatorHub`
holds ONE global `weak var coordinator`, written by whichever of the four tab
NavigationStacks ran `.onAppear` last. When that is not the tab on screen, the
reader route is pushed onto an OFFSCREEN stack: `EPUBReaderView.onAppear` fires,
the patron sees nothing, and the tab bar hides app-wide.

## Claims

- migrates `NavigationCoordinatorHub` from a single global `weak var coordinator`
  to a per-`AppTab` registry, so `coordinator` resolves the stack of the tab that
  is actually on screen
- adds public function `register(_:for:)` on `NavigationCoordinatorHub`
- adds public function `coordinator(for:)` on `NavigationCoordinatorHub`
- adds field `tabRouterHub` to `NavigationCoordinatorHub` (constructor-injected, no default)
- adds field `openCoordinatorByBookId` to `ReaderService` so an LCP-PDF completion acts
  on the stack the open targeted rather than on whatever is visible when it lands
- removes `setupCoordinator` from `CatalogLaneMoreView` — the view is reached from
  `BookDetailView` on every tab and cannot know its own tab identity
- adds public function `popRouteIfStillOwned(forBookIdentifier:on:)` on `ReaderService`
  — the one ownership decision both LCP-PDF completion arms use before popping
- adds a stale-generation guard to the `openBook` failure arm, matching the success
  arm, so a failure from a superseded open cannot tear down the open that replaced it
- adds field `currentTab` to `AppTabRouterHub`
- adds field `tab` to `NavigationHostView` so each tab's stack registers under its
  own identity
- changes `AppTabHostView.handleTabSelectionChange` to pop the OUTGOING tab's
  stack explicitly instead of whichever stack the global pointer happened to hold
- adds a visible "Unable to open book" alert on the remaining book-open paths that
  today drop silently when no coordinator resolves

## Anti-claims

- does NOT change `NavigationCoordinator`'s public surface (push/pop/store/resolve
  are untouched)
- does NOT change which routes exist or how any destination renders
- does NOT touch sign-in, borrow, return, download, or DRM fulfillment logic
- does NOT change the audiobook session presentation policy
  (`inAppPlaybackNavEnabled` routing is untouched)
- does NOT add or change any tab, tab order, or tab chrome

## Files in scope

- Palace/AppInfrastructure/NavigationCoordinatorHub.swift
- Palace/AppInfrastructure/AppTabRouter.swift
- Palace/AppInfrastructure/NavigationHostView.swift
- Palace/AppInfrastructure/AppTabHostView.swift
- Palace/AppInfrastructure/AppContainer.swift
- Palace/AppInfrastructure/ReaderService.swift
- Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift
- Palace/Book/UI/BookDetail/BookDetailViewModel.swift
- Palace/Book/UI/BookDetail/BookService.swift
- Palace/CatalogUI/Views/CatalogLaneMoreView.swift
- PalaceTests/AppInfrastructure/NavigationCoordinatorHubTests.swift
- PalaceTests/AppInfrastructure/AppTabHostTabSwitchResetTests.swift
- PalaceTests/AppInfrastructure/ReaderServiceRouteOwnershipTests.swift
- Palace.xcodeproj/project.pbxproj
- docs/architecture/in-app-navigation-during-playback.md

Test files updated mechanically because the settable `coordinator` property was
replaced by `register(_:for:)`, and to pin hub resolution deterministically
rather than depending on production's tab router being unset:

- PalaceTests/Audiobooks/AudiobookSessionManagerFlagGatePresentationTests.swift
- PalaceTests/Audiobooks/AudiobookSessionManagerPresenterMigrationTests.swift
- PalaceTests/Contract/StreamingReaderPresentationContractTests.swift
- PalaceTests/MyBooks/BookCellModelStreamingHTMLTests.swift
- PalaceTests/Support/TestAppContainerFactory.swift
- PalaceTests/AppInfrastructure/AppContainerTests.swift

Declared drive-by, outside the PP-5022 cause but inside a file this diff already
touches: `PalaceTests/Book/BookDetailViewModelTests.swift` replaces a
`XCTAssertTrue(true, ...)` tautology with a real `XCTAssertNil` on the value the
test names. The test-quality gate counts a pre-existing blocking violation
against any changed file, so leaving it was not an option.
