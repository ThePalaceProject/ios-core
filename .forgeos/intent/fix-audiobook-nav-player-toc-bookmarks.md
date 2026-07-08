---
name: fix-audiobook-nav-player-toc-bookmarks
created: 2026-06-08
author: claude-opus-4-8
tracking: (none — user-reported regression in in-app-nav audiobook playback)
related_prs: ["#1029 (feat: in-app navigation during audiobook playback — introduced the regressions)"]
submodule_change: ios-audiobooktoolkit (branch fix/audiobook-nav-view-public)
---

## Summary

The in-app-nav audiobook playback flow (flag `in_app_playback_nav_enabled`, shipped in PR #1029) lost the **Table of Contents button** — and with it access to the **Chapters and Bookmarks** lists — in the full player. While fixing it, two adjacent #1029 bugs surfaced and are fixed here too: a **Done/Back button collision** and a **phantom mini-player** that lingered after a failed open.

Root cause of the TOC loss: the toolkit's `AudiobookPlayerView` declares its back + TOC buttons as `.toolbar { ToolbarItem(placement: .navigationBar*) }`. SwiftUI only renders `.navigationBar*` toolbar items inside a `NavigationStack`. The legacy flow hosts the player inside `NavigationHostView`'s `NavigationStack`; the new nav flow hosts it in a bare `ZStack` inside `AudiobookFullPlayerCoverContainer` with no `NavigationStack` ancestor, so the toolbar items silently no-op.

**Approach (Option B, user-approved after Option A was rejected by live testing):** an earlier attempt wrapped the player in a nested `NavigationStack`; live simdrive testing proved that crashes (`NavigationRequestObserver tried to update multiple times per frame` → crash-relaunch on back-nav) and collides the Done button with the nav-bar back button. Option B instead presents the toolkit's `AudiobookNavigationView` (Chapters + Bookmarks) in an isolated `fullScreenCover` launched from a TOC button in the overlay — no nested `NavigationStack` in the live hierarchy, player view untouched.

## Claims

### Module A — toolkit `ios-audiobooktoolkit`

- Makes `AudiobookNavigationView` (the Chapters + Bookmarks screen) `public` (`public struct` + `public init(model:)` + `public var body`) so the app can present it. No behavior change; visibility only.

### Module B — app `Palace`

- `AudiobookFullPlayerCoverContainer`: presents `AudiobookNavigationView(model:)` in a `fullScreenCover` (in its own `NavigationStack`), driven by a new `showTableOfContents` `@State`. Adds a `topControlsOverlay` (HStack) with the existing chevron-down Done button (leading) and a new `tableOfContentsButton` (trailing, `list.bullet`, a11y label `Strings.Generic.tableOfContents`). Removes the nested-`NavigationStack` wrap. No new user-facing copy (reuses `Strings.Generic.tableOfContents`).
- `AudiobookSessionPresenter.subscribeToSessionState`: on a terminal `.error` state, calls `clearActiveSession()` so the mini-player + full-player overlay tear down after a failed open (phantom-view fix).
- `AudiobookSessionManager` load-failure path: publishes the terminal `.error` to `playbackStatePublisher` (it previously set `state = .error` without publishing, so the presenter never saw the failure — the phantom's root cause).
- Adds `testErrorState_tearsDownSession_soPlaybackViewDoesNotLingerAfterFailedOpen` to `AudiobookSessionPresenterTests`.

## Anti-claims

- Does **not** wrap the player in a nested `NavigationStack` (the rejected Option A).
- Does **not** change the legacy (flag-OFF) playback flow.
- Does **not** change `AudiobookPlayerView` behavior or the persistent-overlay mount semantics.
- Does **not** add or change any user-facing copy.
- Does **not** change the mini-player's `hasActiveSession && !isReaderActive` visibility predicate.

## Files in scope

- `ios-audiobooktoolkit/PalaceAudiobookToolkit/UI/AudiobookNavigationView.swift`
- `Palace/AppInfrastructure/AudiobookFullPlayerCoverContainer.swift`
- `Palace/Audiobooks/AudiobookSessionPresenter.swift`
- `Palace/Audiobooks/AudiobookSessionManager.swift`
- `PalaceTests/Audiobooks/AudiobookSessionPresenterTests.swift`

## Verification

- Build clean (Palace scheme, iPhone 16 Pro).
- Unit: `testErrorState_tearsDownSession_...` (phantom-view teardown, mutation-checked).
- simdrive (Dune, flag ON): TOC button → Chapters/Bookmarks cover → Back (no crash, playback continues) → Done → real mini-player. Zero per-interaction nav-faults, no crash-relaunch (vs Option A: 3 faults + 2 crashes). Before/after screenshots in PR body.
