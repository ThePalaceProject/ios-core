---
name: in-app-navigation-during-playback
type: evolving
status: draft
created: 2026-06-01
last_refresh: 2026-06-01
freshness_window: 365d
owners: [general]
description: "Design — let users navigate the app while an audiobook is playing or an ebook is mid-session"
---

<!-- audit-verified -->
<!--
  Factual claims audited 2026-06-01 against:
    - PR #1020 → git log e9faeac3a (3.2.0 close-out wave 1 — audiobook hang)
    - F-011    → memory: audiobook_first_open_hang_3_2_0.md (PP-4436)
    - PP-3783  → git log 17aab7558 + NavigationCoordinator.swift:194-196 inline
    - FINDING-B→ git log fd4378d95 + AudiobookSessionManager.swift:716+ inline
-->

# In-app navigation during audiobook playback and ebook reading

> Today, once a user enters the audiobook player or the EPUB/PDF reader, the rest of the app is unreachable without either backing out completely or losing the session. This doc proposes a persistent mini-player for audiobooks and a "Continue Reading" resume surface for ebooks — patterns validated by Audible, Libby, Apple Books, and Spotify.

**Target release:** 3.3.0 (post-3.2.0, off `develop`)
**Status (2026-06-01):** Draft. Approach selected (A1 + B1); all open product questions resolved (§9). Ready for engineering review before P1 kickoff.

---

## 1. Problem

A library reading app spans browsing, borrowing, and consumption. Today consumption (`Reader2` for EPUB, `Reader3` for PDF, `AudiobookPlayerView` for audiobooks) is presented in a way that takes over the screen and breaks the navigation thread:

- **Audiobook player** is pushed onto the per-tab `NavigationCoordinator` stack via `AudiobookSessionManager.presentCoverArtAndNavigation` → `coordinator.pushAudioRoute(route)` (`Palace/Audiobooks/AudiobookSessionManager.swift:676`). The tab bar is hidden (`NavigationHostView.swift:107`). To check My Books or search the catalog, the user must navigate "back" — the audio keeps playing via `AudiobookSessionManager` + `NowPlayingCoordinator`, but the player UI is gone with no re-entry affordance other than re-opening the book from My Books.

- **EPUB sample reader** is presented as a root `.fullScreenCover` on each tab's `NavigationHostView` (`NavigationHostView.swift:19`). Fully modal.

- **EPUB full reader** routes via `.epub(BookRoute)` — either a SwiftUI `EPUBReaderView` or a `UIViewControllerWrapper` with the toolbar and tabBar hidden (`NavigationHostView.swift:91-103`).

- **PDF reader** (Readium-backed for LCP, PDFKit otherwise) routes via `.pdf(BookRoute)` with `.toolbar(.hidden, for: .tabBar)` (`NavigationHostView.swift:46-90`).

The user-visible gap: **a listening or reading session has no in-app presence outside the player/reader screen.** Compared to Audible, Libby, Apple Books, Spotify, and Pocket Casts, this is missing functionality — not a stylistic difference.

---

## 2. Goals

1. While audio is playing, the user can browse the catalog, search, manage holds, and view My Books **without losing the player chrome or interrupting playback**.
2. After dismissing the EPUB or PDF reader, the user can resume reading from anywhere in the app in **≤2 taps** and at the exact saved position.
3. State of "what's playing / what's being read" is observable from a single root-level surface (so the resume affordance is consistent across tabs).
4. The current `AudiobookSessionManager`, `NowPlayingCoordinator`, CarPlay, and lock-screen integrations continue to work unchanged.

## 3. Non-goals

- Multi-window or iPad split-view reading.
- Picture-in-picture mini-reader for EPUB/PDF.
- Concurrent playback of multiple audiobooks.
- Restructuring the reader's internals (Readium 3.x WKWebView, PalacePDFView). The reader UIs stay as they are.

---

## 4. Competitive landscape

Pattern survey across the apps users compare Palace to:

| App | Audio playing | Ebook session | Resume affordance |
|---|---|---|---|
| **Audible** | Persistent mini-player above tab bar; tap to expand to full player; swipe-down on full player to minimize | Full-screen reader; close to return to library | Hero "Continue listening" + "Continue reading" rows on Home |
| **Libby** | Persistent mini-player above tab bar | Full-screen reader; close to return to Shelf | "Continue" badge on Shelf; resumes at saved position |
| **Apple Books** | Mini-player at bottom (above tab bar) while audio plays; tap = expand | Full-screen reader; close to return to Library | "Reading Now" surface on home tab |
| **Spotify** / Apple Music | Persistent mini-player above tab bar | n/a | n/a |
| **Pocket Casts** / **Overcast** | Floating "Now Playing" pill / mini-player | n/a | n/a |
| **Kindle** | Mini-player when Audible audiobook is playing | Full-screen reader | "Continue Reading" hero on home |

**Convergent design:** audio gets persistent in-app chrome; ebooks get a frictionless resume surface. **No leading app provides a persistent reading mini-bar** for ebooks — the reader is the activity, and the resume affordance lives outside it.

---

## 5. Approaches considered

### Audiobook playback

| ID | Approach | Inspired by | Notes |
|---|---|---|---|
| **A1** | Persistent mini-player above the tab bar across all non-reader screens. Tap = expand to full player. Swipe down on full player = minimize. | Audible, Libby, Apple Books, Spotify | **Selected.** Strongest discoverability; matches user expectations from comparable apps. |
| A2 | Floating "Now Playing" pill (lighter chrome). | Pocket Casts, Overcast | Equivalent engineering cost (the hoist is the work, not the chrome shape). Less visually familiar in a library-reading context. |
| A3 | Rely entirely on `MPNowPlayingInfoCenter` + Control Center + lock screen. | (no leading app does this alone) | Lowest cost but worst UX for an in-app activity. Forces the user out of the app to control playback. |

### Ebook reading

| ID | Approach | Inspired by | Notes |
|---|---|---|---|
| **B1** | Keep the reader full-screen modal. Add a "Continue Reading" hero on Catalog and/or My Books that resumes the most-recent in-progress book at the saved position. | Kindle, Apple Books, Libby | **Selected.** Matches universal convention. Minimal reader-architecture change. Pairs naturally with A1 — both are "now-active" surfaces. |
| B2 | Persistent reading mini-bar above the tab bar (stacked with the audio mini-player when both are active). | Hybrid; not directly copied | Higher engineering cost; competes visually with the audio mini-player. No leading app does this. |
| B3 | iPad split-view reader with sidebar nav. | Apple Books on iPad | Real value on iPad, none on phone. Premature for the current Reader2 / Reader3 split. |

**Selected pair:** **A1 + B1.** A1 closes the audio gap with the strongest pattern. B1 closes the ebook gap with the universal-convention pattern at small cost. Both are observable from one "active sessions" data source, keeping the surfaces aligned without forcing symmetric chrome.

---

## 6. Architecture

### 6.1 Current state — relevant slice

```
SceneDelegate
    └── AppTabHostView (TabView, 4 tabs)
            ├── NavigationHostView(rootView: CatalogView)          ← own NavigationCoordinator
            ├── NavigationHostView(rootView: MyBooksView)          ← own NavigationCoordinator
            ├── NavigationHostView(rootView: HoldsView)            ← own NavigationCoordinator
            └── NavigationHostView(rootView: TPPSettingsView)      ← own NavigationCoordinator
                    └── .navigationDestination(for: AppRoute.self) {
                            case .audio(BookRoute):    AudiobookPlayerView  [tabBar hidden]
                            case .epub(BookRoute):     EPUBReaderView       [tabBar hidden]
                            case .pdf(BookRoute):      ReadiumPDFReaderView [tabBar hidden]
                            ...
                        }
                    .fullScreenCover(item: presentedEPUBSample)    ← EPUB sample modal
```

`AudiobookSessionManager` owns the live session and uses `AppContainer.production().navigationCoordinatorHub.coordinator` to push the `.audio` route. There is no root-level player container.

That getter used to resolve "whichever tab's stack appeared most recently", which is what made a push land on an offscreen tab (PP-5022 — the My Books Read button that did nothing). It now resolves the stack of the tab the tab router reports as SELECTED: `NavigationHostView` registers its stack under its own `AppTab`, and an unregistered selected tab yields `nil` rather than another tab's stack. For this document's purposes the consequence is that an `.audio` push lands on the visible tab. The residual, unfixed as of PP-5022, is that `dismissPlayerOnPhone`'s `removeAudioModel(forBookId:)` still resolves the same way at dismissal time, so a session presented on one tab and dismissed while another is selected leaves its cached `AudiobookPlaybackModel` behind in the original stack's store (`popToRoot` clears `path`, not the stored models).

### 6.2 Target state — A1 mini-player

```
SceneDelegate
    └── AppTabHostView
            ├── TabView (4 tabs as today)
            └── .safeAreaInset(edge: .bottom) {
                    AudiobookMiniPlayerView(session: sessionManager)
                        .observe { tap → presentFullPlayer = true }
                }
            .fullScreenCover(isPresented: $presentFullPlayer) {
                AudiobookPlayerView(model: ...)
                    .swipeDownToMinimize → presentFullPlayer = false
            }
```

Key moves:

1. **Hoist player presentation to the root.** `AudiobookSessionManager` no longer pushes `.audio` onto a per-tab nav stack. Instead it flips an `@Published var hasActiveSession: Bool` and exposes the active `AudiobookPlaybackModel`. `AppTabHostView` observes this via a new `AudiobookSessionPresenter` (or directly via `AudiobookSessionManaging`) and renders the mini-player in its bottom safe-area inset.

2. **Full-player expansion lives at root.** Tap on the mini-player flips a `@Published var isPlayerExpanded: Bool` on the presenter, which drives a root-level `.fullScreenCover` (or a custom sheet with a swipe-down dismissal gesture). This matches Apple Music / Audible / Libby behavior: minimize returns the user to wherever they were, regardless of tab.

3. **`AppRoute.audio` becomes a legacy compatibility case.** Old call sites that pushed the player onto a nav stack route through the presenter instead. The case can remain as a no-op or be removed once all push sites are migrated (likely a single follow-up).

4. **No regression to `NowPlayingCoordinator`, CarPlay, lock screen.** Those subscribe to `AudiobookSessionManager` already; the hoist doesn't change the session-state surface.

5. **Tab switching during playback works for free.** With the player above the tab bar, switching tabs is a normal `TabView` operation; the mini-player stays put.

### 6.3 Target state — B1 "Continue Reading / Listening" surface

```
CatalogView (top of catalog tab)
    ┌─────────────────────────────────────┐
    │ Continue Listening                  │
    │ [cover] Title          ▶ 12:34 left │  ← if audiobook session active OR paused recently
    └─────────────────────────────────────┘
    ┌─────────────────────────────────────┐
    │ Continue Reading                    │
    │ [cover] Title             52% / Ch3 │  ← most-recent in-progress ebook
    └─────────────────────────────────────┘
    ... (rest of catalog lanes)
```

Both rows are driven by a new `ActiveSessionsViewModel` observing:
- `AudiobookSessionManager` for the active audio session (already exists).
- A lightweight `RecentlyReadingService` that queries the existing book registry for "downloaded, partially-read EPUB/PDF" sorted by last-read timestamp. The last-read timestamp + position is already persisted via `TPPBookLocation` and the Readium bookmark surface (see `Palace/Reader2/Bookmarks/`).

The "Continue Reading" tap is a thin wrapper over the existing reader-open flow (`ReaderService.openEPUB` / `ReaderService.openPDF`). No reader changes.

### 6.4 Data flow

```
AudiobookSessionManager  ─── publishes ──▶  AudiobookSessionPresenter
                                                  │
                                                  ├──▶ AppTabHostView (mini-player + root fullScreenCover)
                                                  ├──▶ ActiveSessionsViewModel (Continue Listening row)
                                                  ├──▶ NowPlayingCoordinator (unchanged)
                                                  └──▶ CarPlayAudiobookBridge (unchanged)

TPPBookRegistry         ─── + last-read ──▶  RecentlyReadingService
                                                  │
                                                  └──▶ ActiveSessionsViewModel (Continue Reading row)
```

There is **one source of truth** for "an audiobook is currently active" (the session manager) and **one source of truth** for "an ebook session is in progress" (registry + Readium position). No new persisted state is required for A1; B1 reuses the existing position storage.

---

## 7. Cross-cutting concerns

### 7.1 Accessibility

- Mini-player needs an accessibility label (`"Now playing: <title> by <author>, paused at <chapter>, double-tap to expand"`) and standard `playPauseButton` / `skipForwardButton` accessibility hints.
- VoiceOver focus must move into the expanded player on open and return to the mini-player on minimize.
- Reduce-motion must skip the expand/minimize transition (matches existing `NavigationCoordinator` reduce-motion handling).
- Dynamic Type: mini-player chrome must reflow at AX1–AX5; truncate title before hiding controls.

### 7.2 CarPlay

`CarPlayAudiobookBridge` and `NowPlayingCoordinator` subscribe to `AudiobookSessionManager`, not to the phone UI. The hoist must not change those publisher contracts. **Verification gate:** the CarPlay smoke flow must pass on the in-progress branch before the hoist lands.

### 7.3 Reader screens

The reader's `.toolbar(.hidden, for: .tabBar)` directive (`NavigationHostView.swift:75, 87, 100, 107`) hides the tab bar today. With the mini-player as a `safeAreaInset` of `AppTabHostView`, **the mini-player would still appear while in the reader unless explicitly suppressed.** Two options:

- **Option α (selected):** suppress the mini-player while a reader route is on top. The presenter exposes `@Published var isReaderActive: Bool`, set by a thin hook in `NavigationHostView`'s navigation-destination cases for `.epub`, `.pdf`, and `presentedEPUBSample`. The mini-player view conditions visibility on `!isReaderActive`.
- Option β: let the mini-player appear over the reader. **Rejected** — distracting while reading; reduces reader usable height; no leading app does this.

### 7.4 First-open / readiness gate interaction

The recent `PlaybackReadinessGate` work (PR #1020, F-011 fix) means the player can take a moment to actually start audio after `presentCoverArtAndNavigation`. Today the user sees the full player screen during the gate wait, which provides loading affordance. With A1:

- If the user **opens** an audiobook for the first time, we should still **expand to the full player** immediately so the cover art + loading state are visible during the readiness wait. Only after they minimize does the mini-player become the surface.
- If audio is **resumed** from the mini-player or from `MPNowPlayingInfoCenter`, the readiness gate already-handled and the mini-player suffices.

### 7.5 LCP streaming (FINDING-B)

The LCP-streaming gate skip (`AudiobookSessionManager.swift:716`-) is orthogonal; A1 doesn't change the readiness flow. Verify the LCP-streaming smoke path stays green.

---

## 8. Phased implementation outline

Each phase is independently shippable and reviewable. **No code in this doc** — phase scoping only.

| Phase | Scope | Module count | Rigor bar |
|---|---|---|---|
| **P0** | This design doc, reviewed and merged on `develop`. | 0 | `/clean-code` |
| **P1** | `ActiveSessionsViewModel` + `RecentlyReadingService` + "Continue Reading" row on Catalog (and/or My Books). Reader unchanged. | 1 (`MyBooks` / `CatalogUI`) | `/clean-code` + TDD; mutation on `RecentlyReadingService` |
| **P2** | Add "Continue Listening" row to the same viewmodel. Wires only — no player hoist yet. | 1 (`Audiobooks`) | Same as P1 |
| **P3** | `AudiobookSessionPresenter` introduced. Mini-player rendered as `safeAreaInset` of `AppTabHostView`. Tap = push existing `.audio` route (no expand yet — pure visibility win). | 2 (`AppInfrastructure`, `Audiobooks`) | `/swarm` (multi-module) OR `/rigorous-fix` (critical-path) |
| **P4** | Root-level full-player presentation (`fullScreenCover`). Migrate `AudiobookSessionManager` off `pushAudioRoute`. Suppress mini-player while reader route is active. | 2 | `/rigorous-fix` (critical-path; audiobook hoist + CarPlay smoke + LCP smoke) |
| **P5** | Polish: VoiceOver focus, Dynamic Type, reduce-motion transitions, swipe-down dismissal gesture on the full player. | 1 | `/clean-code` |
| **P6** | Remove legacy `AppRoute.audio` push sites once migration is complete. | 1 | `/clean-code` |

P1 + P2 are pure additions, low risk, can ship under 3.3.0 or earlier. P3 + P4 are the audiobook player architectural change and gate the user-visible feature. P5 + P6 are cleanup.

---

## 9. Risks and open questions

### Risks

1. **CarPlay regression.** Any change to `AudiobookSessionManager` presentation path risks regressing the CarPlay bridge or `NowPlayingCoordinator`. **Mitigation:** keep the session-manager public publishers identical; the hoist only changes where the UI renders, not what the manager publishes. Verify via the existing CarPlay smoke flow before each phase ships.
2. **Readiness-gate UX regression.** If we minimize the player too eagerly during first-open, the user sees a mini-player with no audio playing yet and may tap play repeatedly. **Mitigation:** see §7.4 — first-open always expands.
3. **Reader full-screen hiding.** If the suppression hook in §7.3 has a race or misses a route case, the mini-player could flash over the reader. **Mitigation:** drive `isReaderActive` from `path.last`-style observation, not from per-screen `onAppear`/`onDisappear` (which can drop frames on push).
4. **Tab-switching + back-stack semantics.** Today `pushAudioRoute` has subtle behavior around "switching audiobooks vs opening from book detail" (`NavigationCoordinator.swift:194-196`, PP-3783). The hoist must preserve "open new audiobook while one is already playing → replaces the active session, doesn't stack".

### Resolved (2026-06-01)

1. **"Continue Listening" + "Continue Reading" rows both land on the Catalog tab** (Audible pattern: both rows together on the home surface; Catalog is our closest analogue to Audible's Home).
2. **Full-screen expansion** for the audiobook player — custom `fullScreenCover` with our own swipe-down gesture to match Audible's full-takeover aesthetic.
3. **Samples are excluded** from "Continue Reading" — sample sessions have no meaningful position state.
4. **Threshold = >0 seconds of playback** for a book to appear in "Continue Listening". Any progress counts; matches Audible's permissive surfacing.
5. **Mini-player is visible on the Settings tab** — Settings is a navigation surface, not a consumption surface. Mini-player is suppressed only when a reader route is active (§7.3 Option α).

---

## 10. Out of scope (for this design, not forever)

- iPad split-view reading.
- PiP / mini-EPUB-reader.
- "Listen along while reading the same book" sync mode.
- New persisted state schema (the design reuses existing `TPPBookLocation` and `AudiobookSessionManager` state).

---

## 11. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-06-01 | A1 (persistent mini-player) + B1 ("Continue Reading" surface) | Matches Audible / Libby / Apple Books convention; lowest user-side surprise; preserves reader as a focus environment. |
| 2026-06-01 | Hoist player to root `AppTabHostView` rather than promote one tab's `NavigationCoordinator` to global | Tab switching during playback works for free; minimize/expand semantics match comparable apps. |
| 2026-06-01 | Suppress mini-player while reader route is active (Option α §7.3) | No leading app overlays a media-player chrome on a reader; would crowd Reader2's WKWebView. |
| 2026-06-01 | "Continue Listening" + "Continue Reading" rows both live on Catalog tab | Audible pattern: both rows together on the home surface. Catalog is our closest analogue to Audible's Home (we have no dedicated Home tab). |
| 2026-06-01 | Full-screen `fullScreenCover` for the expanded player (custom swipe-down) | Matches Audible's full-takeover aesthetic; the custom gesture preserves the minimize-to-mini-player metaphor. |
| 2026-06-01 | Samples excluded from "Continue Reading" | Sample sessions have no meaningful position state; surfacing them would mislead the user about what "continue" means. |
| 2026-06-01 | Threshold for "Continue Listening" = >0 seconds played | Audible-style permissive surfacing. Avoids hiding books the user opened but only briefly tapped. |
| 2026-06-01 | Mini-player visible on Settings tab; suppressed only on reader routes | Settings is navigation, not consumption. Reader routes are the only true full-screen activity. |

---

## 12. Cross-references

- `Palace/AppInfrastructure/AppTabHostView.swift` — root tab container
- `Palace/AppInfrastructure/NavigationHostView.swift` — per-tab nav stack + route destinations
- `Palace/AppInfrastructure/NavigationCoordinator.swift` — coordinator + audio-route push logic (`pushAudioRoute`, `isTopRouteAudio`)
- `Palace/Audiobooks/AudiobookSessionManager.swift` — session state + current `presentCoverArtAndNavigation`
- `Palace/Audiobooks/NowPlayingCoordinator.swift` — system Now Playing wiring (unchanged)
- `Palace/CarPlay/CarPlayAudiobookBridge.swift` — CarPlay wiring (unchanged)
- `Palace/Reader2/Bookmarks/` — EPUB position storage (re-used by B1)
- PP-3783 — back-stack semantics for the player open from book detail (must preserve)
- F-011 / PR #1020 — readiness gate; informs §7.4 first-open behavior
- FINDING-B / LCP streaming — informs §7.5 verification
