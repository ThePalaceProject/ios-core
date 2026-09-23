---
name: holds-verification-checklist
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 180d
owners: [holds]
description: Per-area verification reference; refresh before next swarm/rigorous-fix
---

<!-- audit-verified: All file paths and line numbers were spot-read against the working tree on 2026-05-28 (branch chore/swarm-rigor-meta-improvement). Palace/Holds/ contains exactly the 3 files listed in Section 1 per `ls Palace/Holds/`. Test inventory verified via `find PalaceTests -name '*Hold*Tests.swift'`. Regression matrix rows B3/B4/B7/C4/N1/N4 quoted from docs/Testing/REGRESSION_TEST_MATRIX.md. HelpSpot ticket numbers (17960 Derryl, 17971 Heather), F-numbers (F-035, F-065, F-072, F-081), and JIRA ticket IDs (PP-3702, PP-3811, PP-4020, PP-4258, PP-4259, PP-4358) sourced from the regression matrix + git log -- Palace/Holds/. NotificationService.swift line numbers (484-579) verified via Read of that range. -->

# Holds area — verification checklist

**Owner area:** `Palace/Holds/` (HoldsReducer, HoldsViewModel, HoldsView) and the holds-adjacent surfaces in `Palace/Notifications/NotificationService.swift` (hold-ready push routing), `Palace/AppInfrastructure/TPPAppDelegate.swift` (`syncIfUserHasHolds`), `Palace/AppInfrastructure/AppTabHostView.swift` (holds tab + badge), `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` (`didSelectReserve` / `cancelHold` dispatch), `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` (cell-side reserve/cancel-hold paths), `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift` + `BookButtonMapper` (`canHold`, `holding`, `holdingFrontOfQueue`, `managingHold`, hold-ready transition).

**Purpose:** the architect's first deliverable on ANY swarm or /rigorous-fix in this area is *update this file*. Verify what's still true, add what's changed, mark what's UNKNOWN.

**Last refresh:** 2026-05-28 (initial baseline — derived from PR #947 (BUG-004), the HoldsReducer extraction commits 06bf675d7 + 17b029d09, and HelpSpot triage on 17960/17971).
**Refreshing architect:** sign and date the next-refresh row at the bottom of this file.

---

## 1. Call-site map (sites that mutate hold state, route hold notifications, or render hold UI)

| File | Lines | What it does | Notes |
|------|-------|-------------|-------|
| `Palace/Holds/HoldsReducer.swift` | 1-131 | Pure reducer over `HoldsState`. Owns `syncBegan` / `syncEnded` / `syncFailed` / `registryChanged` / `searchQueryChanged` / `filterCompleted` / `dismissSyncError`. `isReserved(_:)` private predicate matches `availability == .reserved || .ready`. | Banner-suppression rules collapsed into `syncFailed(cached:anonymous:)` payload — caller (HoldsViewModel.`dispatchSyncFailure`) computes both flags. |
| `Palace/Holds/HoldsViewModel.swift` | 1-297 | Wires registry + auth-state publishers to the reducer; partitions books into `reservedBookVMs` + `heldBookVMs`. `refresh()` (line 245) / `refreshInBackground()` (line 261). | `currentLibraryNeedsAuth` default-denies on nil auth doc (BUG-004 fix, see lines 82-94). `authStateDidChangePublisher` observer (line 159) catches SAML re-auth that hasCredentials-only publishers miss. |
| `Palace/Holds/HoldsView.swift` | 1-257 | SwiftUI list + search + sync-error banner. `TPPHoldsViewController.makeSwiftUIView` (line 247) is the UIKit entry from the tab bar. | `BookListView` is the shared cell renderer; selection routes through `NavigationCoordinator.push(.bookDetail(...))`. |
| `Palace/Notifications/NotificationService.swift` | 484-579 | `userNotificationCenter(didReceive:)` (line 485) routes hold-ready taps. `decideHoldNavigation(currentAccount:)` (line 569) is the pure seam; returns `.navigate / .skipUnsupportedReservations / .skipNoCurrentAccount / .skipDetailsFailed`. Event enum (line 620) defines `holdAvailable` / `holdRemoved`. | Bucket A migration extracted the navigation decision so tests can pin every branch without a real `UNNotificationResponse`. |
| `Palace/Notifications/NotificationService.swift` | 17 | `HoldNotificationCategoryIdentifier = "NYPLHoldToReserveNotificationCategory"` — legacy NYPL-prefixed string preserved for compat with registered local-notification category. | Renaming this string drops in-flight scheduled local notifications. |
| `Palace/AppInfrastructure/TPPAppDelegate.swift` | 295-329 | `syncIfUserHasHolds()` — 30s-throttled foreground sync triggered on `applicationDidBecomeActive`. Updates app-icon badge on success. | Shared throttle key `"lastForegroundSyncTimestamp"` is also read by `NotificationService.syncWithThrottle`. Don't change the key without updating both. |
| `Palace/AppInfrastructure/AppTabHostView.swift` | 69-156 | Holds tab registration; tab-change handler triggers `bookRegistry.sync()` on switch to holds (F-035, line 99). `updateHoldsBadge` reads `computeReadyCount` / `computeReservedCount` (lines 123-149) — both are pure helpers exposed for unit testing. | `shouldUpdateBadge` (line 153) gates badge writes to `.loaded || .synced` registry states only. |
| `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` | 617, 657, 759-776, 623 | `case .reserve` dispatches `didSelectReserve` → `downloadCenter.borrowAsync(book, attemptDownload: false)`. `case .manageHold` (line 657) toggles `isManagingHold`. `case .return / .remove / .returning / .cancelHold` (line 623) routes to `didSelectReturn`. | Cancel-hold is a borrow-flow return; the same `returnBook` path serves both real returns and hold cancellations. |
| `Palace/Book/UI/BookDetail/BorrowReducer.swift` | 129 | `processingButtons.subtract([.returning, .cancelHold, .return, .remove])` on borrow-completion — clears the spinner on hold actions. | If a new hold action is added to BookButtonType, audit this `subtract` set. |
| `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift` | 504-540, 676-708 | Cell-side `.reserve` / `.cancelHold` / `.manageHold` dispatch + `didSelectReserve()` (line 676 — calls `borrowAsync(_, attemptDownload: false)`). Signs in via `SignInModalPresenter` when `needsAuth && !hasCredentials()`. | `borrowAsync(attemptDownload: false)` is the marker that distinguishes "place a hold" (don't download) from "borrow-from-hold-ready" (which does download). |
| `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonState.swift` | 14, 22, 37-58 | `.canHold` / `.holding` / `.holdingFrontOfQueue` / `.managingHold` states map to `[.reserve]`, `[.manageHold]` (or `[.get, .cancelHold]` when ready), and `[.cancelHold]` resp. | If `isHoldReady(book:)` returns true for a `.holding` state, the cell flips to `[.get, .cancelHold]` — this is the PP-3702 fix surface. |
| `Palace/MyBooks/MyBooks/BookCell/ButtonView/BookButtonType.swift` | 13, 23-24, 66, 77-78 | `.reserve` / `.cancelHold` / `.manageHold` button types + localized strings (`placeHold`, `cancelHold`, `manageHold`). | Adding a new hold-flavored button means updating the `accessibilityLabel`, `accessibilityHint`, and the BorrowReducer subtract set. |
| `Palace/Accounts/Library/Account.swift` | 301, 377, 552 | `supportsReservations: Bool` is parsed from authentication-document `features.disabled` containing `"https://librarysimplified.org/rel/policy/reservations"`. | `decideHoldNavigation` reads this via `awaitReady().supportsReservations`; library carve-out for anonymous libraries falls through this predicate. |

**STILL UNMIGRATED / known scope debt:**
- `HoldsViewModel.dispatchSyncFailure` (line 197) still references `TPPBookRegistry.syncFailureErrorDocumentKey` as `[AnyHashable: Any]` — when registry sync moves to a typed error envelope, update this and the reducer payload together.
- The `HoldNotificationCategoryIdentifier` retains the legacy `NYPL` string prefix (line 17 of NotificationService) — rename pending a coordinated cleanup with the CM-side category registration.

---

## 2. Module ownership

| Module | Owner | Public surface (what changes here is a contract break) |
|--------|-------|---------------------------------------------------------|
| `Palace/Holds/` | Main target | `HoldsState`, `HoldsAction`, `HoldsEnvironment`, `HoldsReducer.reduce(_:_:)`, `HoldsBookViewModel`, `HoldsViewModel` (+ `SyncError` nested type), `HoldsView`, `TPPHoldsViewController.makeSwiftUIView()` |
| `Palace/Notifications/NotificationService.swift` | Main target | `userNotificationCenter(didReceive:)`, `decideHoldNavigation(currentAccount:)`, `HoldNavigationOutcome` enum, `EventType.holdAvailable` / `.holdRemoved`, `HoldNotificationCategoryIdentifier` constant, `updateAppIconBadge(heldBooks:)`, `currentFCMToken()`, `deleteToken(for:)`. |
| `Palace/AppInfrastructure/AppTabHostView.swift` (hold-adjacent) | Main target | `AppTab.holds` tab registration, `computeReadyCount(books:)` / `computeReservedCount(books:)` / `shouldUpdateBadge(for:)` helpers, `updateHoldsBadge()` |
| `Palace/AppInfrastructure/TPPAppDelegate.swift` (hold-adjacent) | Main target | `syncIfUserHasHolds()` (private), shared throttle key `"lastForegroundSyncTimestamp"` |
| `Palace/MyBooks/` (hold-adjacent) | Main target | `BookButtonState.canHold / .holding / .holdingFrontOfQueue / .managingHold`, `BookButtonType.reserve / .cancelHold / .manageHold`, `BookCellModel.didSelectReserve()`, `MyBooksDownloadCenter.borrowAsync(_:attemptDownload:)` (`attemptDownload: false` = place-hold path) |

---

## 3. Distributor × hold-state matrix (verify before changing hold dispatch logic)

| Distributor | Place hold | Queue position display | Hold-ready push | Cancel hold | Hold→loan conversion (B7) | Re-hold after expiry |
|---|---|---|---|---|---|---|
| Overdrive (open-access + DRM) | works (Manual B3) | works | works | works (F-065 fix) | works — F-081 closed Overdrive path | UNKNOWN |
| Adobe ACS (EPUB) | works | works | works | works | **UNKNOWN** — B7 was "Unable to test" in PP-4020; still pending a waited-out run |  UNKNOWN |
| LCP (EPUB / PDF / audiobook) | works | works | works | works | **UNKNOWN** — B7 was "Unable to test" in PP-4020; pending `hold-to-loan-lcp.yaml` recording | UNKNOWN |
| Findaway audiobook | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |
| OPDS-for-Distributors (BiblioBoard et al.) | UNKNOWN — distributor commonly does not support holds | n/a | n/a | n/a | n/a | n/a |
| Axis 360 / Boundless | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |
| Bibliotheca cloudLibrary | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN | UNKNOWN |
| Anonymous library (Palace Bookshelf, COPPA-gated) | **MUST NOT OFFER** (SQ-005 / BUG-004) | n/a | n/a | n/a | n/a | n/a |

Most UNKNOWN cells reflect the PP-4020 and PP-4358 audit gaps; refresh with each distributor's holds path on the next regression run.

---

## 4. Notification → state coherence model (verify before changing routing)

| Trigger | Where it lands | What it should do | What can go wrong |
|---------|---------------|------------------|-------------------|
| Hold-ready push tap (background → foreground) | `NotificationService.userNotificationCenter(didReceive:)` (line 485) | `syncWithThrottle` first, then `decideHoldNavigation` → `tabRouterHub.navigate(to: .holds)` if account supports reservations | 30s shared throttle key can skip a real fresh-state fetch if user just foregrounded — see HelpSpot 17960 (Derryl) where ready push fired but holds list disagreed |
| Hold-ready push tap (cold launch) | Same path, but `awaitReady()` may not yet have details | `decideHoldNavigation` waits on `currentAccount.awaitReady()`; falls to `.skipDetailsFailed` on error | Cold-launch eviction race (memory `enum_conflation_account_not_found`) can return `.detailsFailed(.accountNotFound)` even when account is valid; awaitReady gate is the seam to harden |
| App foreground while holds tab active | `applicationDidBecomeActive` → `TPPAppDelegate.syncIfUserHasHolds()` (line 297) | If user has holds AND throttle elapsed (>30s), sync registry + update badge | Throttle is shared with notification path — back-to-back push tap + foreground can leak a single sync; intentional |
| Manual tab-switch to holds | `AppTabHostView` `onChange(of: selectedTab)` (line 99) | `bookRegistry.sync()` unconditionally (F-035) | None known; unconditional sync acceptable here because user-initiated |
| Pull-to-refresh on holds list | `HoldsView.content` `.refreshable { model.refresh() }` (line 145) | `HoldsViewModel.refresh()` → either `bookRegistry.sync()` or `presentSignIn` if no creds | If `presentSignIn` is invoked and user cancels, the spinner clears via the completion closure |
| `TPPSyncBegan` notification | `HoldsViewModel.init` Combine sink (line 125) | Dispatch `.syncBegan` → reducer sets `isLoading = true`, clears prior `syncErrorMessage` | Reducer cancels prior banner; if a banner just appeared, it disappears on next sync. Intentional. |
| `TPPSyncFailed` notification | `dispatchSyncFailure` (line 197) | Computes `cached = !visibleBooks.isEmpty` and `anonymous = !currentLibraryNeedsAuth() || !hasCredentials()`; dispatches `.syncFailed(message, cached, anonymous)` | Banner suppressed only when EITHER flag is true — see Section 7 trap on the `||` semantics |
| `authStateDidChangePublisher == .loggedIn` | line 159 sink | Calls `self.refresh()` after fresh sign-in OR SAML re-auth | Required because `hasCredentials`-only publishers miss SAML re-auth — `hasCredentials` stays true through `.credentialsStale` → `.loggedIn` |

---

## 5. Test surface

**Existing test files** (3 files, ~1,350 lines total):
- `PalaceTests/ViewModels/HoldsReducerTests.swift` — 190 lines, ~11 reducer cases (commit 06bf675d7).
- `PalaceTests/Holds/HoldsViewModelTests.swift` — 988 lines, exercises sync notifications, registry change, search filter, account loading.
- `PalaceTests/BookStateManagement/BookButtonMapperHoldReadyTests.swift` — 172 lines, PP-3702 regression suite (`.holding` + `.ready` availability ⇒ `.canBorrow`).

**Tests that test BEHAVIOR (must-survive any refactor):**
- Banner-suppression rules: `syncFailed + cached=true` and `syncFailed + anonymous=true` both suppress the banner; `syncFailed + cached=false + anonymous=false` shows it.
- Search-active state: `registryChanged` does NOT stomp `visibleBooks` while `searchQuery` is non-empty (reducer line 89).
- Hold partitioning: `availability == .reserved || .ready` → `reservedBooks`; anything else → `heldBooks`.
- PP-3702 hold-ready mapping: `BookButtonMapper.map(registryState: .holding, availability: ready, …) == .canBorrow`.
- Anonymous library no-banner: BUG-004 — `currentLibraryNeedsAuth == false` suppresses the banner even when credentials are absent.
- Notification routing decision: `decideHoldNavigation` returns `.navigate` only when `awaitReady().supportsReservations == true`; `.skipUnsupportedReservations` on supported-false, `.skipNoCurrentAccount` on nil, `.skipDetailsFailed` on awaitReady throw.

**Tests that test IMPLEMENTATION (rewritable when underlying changes):**
- Tests that observe the exact `applyStateUpdate` re-publish ordering (identifier-diff optimization at lines 186-193 is a perf detail, not a contract).
- Tests asserting on the specific NotificationCenter publisher graph inside `HoldsViewModel.init` — observable behavior is what the reducer does in response, not which publisher chain it came through.

**Cross-area test references:**
- `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` Test 7 — round-trip for the `.detailsFailed(.accountNotFound)` swap-back case that `decideHoldNavigation` depends on for cold-launch correctness.
- `PalaceTests/AppInfrastructure/*` — tab badge tests should exist for `computeReadyCount` / `computeReservedCount` (verify on next refresh).

**N4 row** in `docs/Testing/REGRESSION_TEST_MATRIX.md` is the canonical manual test for hold-ready notification ↔ holds-list coherence — runs against multi-hold accounts on any distributor with hold support.

---

## 6. Known traps / anti-patterns (lessons from prior work)

- **Anonymous library carve-out is library-state, not user-account-state** (BUG-004, PR #947). Reading `currentUserAccount.hasCredentials()` alone races during library switches because `lastKnownCurrentUserAccount` falls back to the previous (still-credentialed) library while `currentAccountId` is briefly nil. Always read `accountsManager.currentAccount?.needsAuth` first; default-deny on nil. Tests must drive a library-switch scenario to catch this regression.
- **Banner-suppression `||` semantics**: `cached || anonymous → suppress`. Removing either flag silently re-enables noisy banners for users who already have a hold list cached. The `||` is intentional — see HoldsReducer.swift line 76.
- **`canHold` state requires push permission prompt**: `BookCellModel.didSelectDownload` and `didSelectReserve` both call `NotificationService.requestAuthorization()` whenever `state.buttonState == .canHold` or before reserving. Removing this prompt strands hold-ready notifications.
- **HelpSpot 17960 (Derryl, iPhone 13 iOS 26.4.2)** — hold-ready push arrived but holds list disagreed; reinstall briefly wiped all holds before self-recovering. Symptom of notification ↔ registry-state desync. Reproduce by N4-row manual test on a multi-hold account.
- **HelpSpot 17971 (Heather)** — "queue position 1 for months" never advances; survives reinstall. Possibly stale position display vs CM-side advancement. Audit `TPPOPDSAcquisitionAvailabilityReserved.holdPosition` rendering vs server-side updates.
- **F-065 cancel-hold sync gap** — cancel-hold from search/list view was broken before a pre-PR-#1018-era fix. When changing cancel-hold dispatch (BookCellModel line 520 or BookDetailViewModel line 623), exercise B4 in BOTH the search-results card and the holds list, not just from book detail.
- **F-072 notification tap routing must not be nil** — `decideHoldNavigation`'s `.skipNoCurrentAccount` branch is the safety net; never let it crash on nil.
- **B7 hold→loan conversion is UNKNOWN for Adobe and LCP** — F-081 closed the Overdrive path. When changing `borrowAsync(_, attemptDownload: false)` semantics, the Adobe + LCP paths are unvalidated; treat as high-risk until a waited-out run lands `hold-to-loan-adobe.yaml` and `hold-to-loan-lcp.yaml`.
- **Hold-ready availability is BOTH `.reserved` and `.ready`** (HoldsReducer.isReserved) — the legacy `HoldsBookViewModel.isReserved` partition lumps them together for list-section purposes, but `BookButtonMapper.map(...)` differentiates them for the action button. Don't unify these predicates.
- **`HoldNotificationCategoryIdentifier` uses the NYPL prefix** — renaming this string strands in-flight local notifications. Coordinate with CM-side registration before changing.
- **Throttle key sharing** — `"lastForegroundSyncTimestamp"` is read by both `TPPAppDelegate.syncIfUserHasHolds` and `NotificationService.syncWithThrottle`. Renaming the key in one place leaks duplicate syncs.

---

## 7. Architect's pre-swarm checklist (what to verify before writing a new contract)

Before any new swarm or /rigorous-fix in this area, the architect should:

1. **Refresh this file's sections 1-4** — confirm the call-site map, module ownership, distributor matrix, and notification routing model are still accurate.
2. **Verify hold-ready notification ↔ holds-list coherence (N4)** — run the N4 manual row against a multi-hold account; confirm tab-switch sync (F-035) AND throttle-shared foreground sync both fire. Include the ALREADY-ON-HOLDS case: tapping a hold-ready notification while the Holds tab is already selected changes no tab, so the `onChange`-driven F-035 sync does not fire and the list refreshes only via the foreground path. That has always been true (PP-5051 kept it); it is called out here because PP-5051 made tapping the notification also return that tab to its root, which makes a stale list more visible.
3. **Verify hold→loan conversion (B7) for distributors with hold support** — at minimum exercise Overdrive (F-081). Mark Adobe and LCP UNKNOWN explicitly if not exercised.
4. **Confirm the anonymous-library carve-out** — load Palace Bookshelf or another anonymous library; assert holds tab does NOT show the sync-error banner AND does NOT offer hold actions (BUG-004 + SQ-005 regression class).
5. **Re-run test inventory** — `find PalaceTests -name '*Hold*Tests.swift' -o -name '*HoldsReducer*Tests.swift' | wc -l` — confirm count and update Section 5.
6. **Re-grep cell-side hold buttons** — `grep -rn "\.reserve\b\|\.cancelHold\|\.manageHold" Palace --include="*.swift"` — any new matches outside Section 1's known sites need triage.
7. **Update Section 8 (refresh history)** with date + your initials.

---

## 8. Refresh history

| Date | Refreshed by | Notes |
|------|-------------|-------|
| 2026-05-28 | Initial baseline (chore/swarm-rigor-meta-improvement) | Derived from PR #947 (BUG-004 anonymous suppression), commit 06bf675d7 (HoldsReducer extraction + 11 tests), commit 17b029d09 (AppContainer DI migration), regression matrix rows B3/B4/B7/C4/N1/N4, HelpSpot triage (17960 Derryl, 17971 Heather), PR #1018 area-checklist pattern. |

---

**This file is owned by the holds area.** If you change anything in the modules listed in Section 2, update the relevant section here before you commit. The Definition of Done treats out-of-date area checklists as scope debt.
