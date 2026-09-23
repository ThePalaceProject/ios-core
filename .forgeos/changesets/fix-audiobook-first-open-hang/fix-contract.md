# Fix-contract — Audiobook first-checkout open looks hung (BUG A)

**Branch:** `fix/audiobook-first-open-hang`
**Area:** `audiobook` (see `docs/architecture/areas/audiobook/verification-checklist.md`)
**Reproduced:** live on sim (iPhone 17 Pro, build 486) with *The Confusion* (LCP/Cantook) in A1QA — ~19s from Listen tap to player; download-progress half-sheet + spinning Listen button stacked over a static loading skeleton the entire time; dismisses only when the full `.lcpa` lands. Cold open (already-local) is fast. simdrive recording: `audiobook-first-open-hang-repro`.

## Root cause (confirmed against current source)

1. **Half-sheet dismissal is chained to FULL open completion.** `BookDetailViewModel.handleAction(.read/.listen)` dismisses the half-sheet only in the open *completion* (`BookDetailViewModel.swift:687-690`), which fires from `BookService.dispatchOpen`'s `defer` (`BookService.swift:84-88`) — i.e. only after `await openAudiobook(...)` returns.
2. **`openAudiobook` blocks until the whole audio package is local.** The PP-4542 LCP content-local gate (`AudiobookSessionManager.swift:681-699`) `await`s `awaitAudiobookContentLocal` (polls disk up to 180s, `:2113`) before constructing the player. This wait is the **intentional fix for F-011/PP-4436** (the dominant 3.2.0 LCP first-open hang — streaming-from-license is broken under Readium 3.9.0). **It must NOT be removed or shortened.**
3. **The shell shows no progress during the wait.** `presentLoadingShell` fires up front (`AudiobookSessionManager.swift:660-665`) but the presenter's `overallDownloadProgress`/`isDownloading` are fed ONLY from the toolkit playback model (`AudiobookSessionPresenter.swift:512-519`), which is adopted at `bind()` — *after* the wait. So during the wait the shell is a static skeleton → reads as "hung."

Net: the sheet can't dismiss and the shell can't show progress until the entire download finishes.

## Scope (in)

- **`Palace/Audiobooks/AudiobookSessionManaging.swift`** — add an optional early-present hook to the protocol entry point(s): `onLoadingShellPresented: (@MainActor () -> Void)?` (default `nil`). Non-breaking (defaulted).
- **`Palace/Audiobooks/AudiobookSessionManager.swift`**
  - `openAudiobook(...)` (public `:544` + internal `:586`): accept `onLoadingShellPresented`. Invoke it **at most once** (W2: single fire site), on `@MainActor`, immediately after `presentLoadingShell(...)` at `:660-665` — i.e. only when the shell is actually presented (`startPlaying && inAppPlaybackNavEnabledProvider()`). Do NOT add a non-shell fallback fire — the always-fired final `onFinish` backstop (below) covers the non-shell / early-failure paths, so a second fire site is redundant. Guard with a local `didFireLoadingShellPresented` Bool for defense-in-depth.
  - During the PP-4542 wait (`:681-699`): feed **download-center** progress into the presenter so the shell shows a determinate progress bar + "Downloading…" instead of a static skeleton. Read progress from `AppContainer.production().downloadCenter` for `book.identifier`; push into the presenter via the new presenter method below. Poll cadence reuses the existing `awaitAudiobookContentLocal` loop (no new timer).
- **`Palace/Audiobooks/AudiobookSessionPresenter.swift`** — add a pre-bind progress setter, e.g. `func showDownloadProgress(_ fraction: Float)` that sets `isDownloading = true` + `overallDownloadProgress = fraction` (cleared normally at `bind()` / `clearActiveSession()`). Guarded so a later real `adoptPlaybackModel` mirror wins.
- **`Palace/Book/UI/BookDetail/BookService.swift`** — thread the early callback through `open(...)` + `dispatchOpen(...)` **audiobook case only**. EPUB/PDF/streaming cases unchanged (they present synchronously; their existing `onFinish` is already prompt).
- **`Palace/Book/UI/BookDetail/BookDetailViewModel.swift`** — in the `.read/.listen` audiobook path, dismiss the half-sheet EARLY (`showHalfSheet = false`) in the new `onLoadingShellPresented` callback. **ADDITIVE, not a move (architect F1):** the existing final-`onFinish` dismissal (`:687-690`) STAYS as an idempotent backstop, so an open that fails BEFORE the shell is presented (`.alreadyLoading` `:617-620`, validation failure `:640-645` — both reachable on the real Listen path, and neither presents a shell) still dismisses the sheet via the final completion. Both writes set `showHalfSheet = false` → idempotent, order-independent, no stuck sheet on any path. Non-audiobook read/listen (EPUB) keeps current behavior. Also keep the final `onFinish` for `removeProcessingButton`.

## Scope (out) — DO NOT touch

- **Do NOT remove/shorten `awaitAudiobookContentLocal` or the PP-4542 gate** — F-011/PP-4436 preservation. The wait stays; only the UI coupling changes.
- **Do NOT change `presentOnFirstOpen()` / `presentLoadingShell` sync-before-Task ordering** — F-011 preservation contract (`swarm_0b7616e7` C-AudiobookSessionPresenter). The early callback fires AFTER `presentLoadingShell`, preserving order.
- **Do NOT touch** `AudiobookLoader`, vendor adapters, `NowPlayingCoordinator`, `PlaybackBootstrapper`, CarPlay. This is a UI-coupling + progress-surfacing change, not a load-path change.
- **Sibling `openAudiobook` callers (architect F3/F4) — named, unaffected via defaulted param, NOT modified:** `BookCellModel.openAudiobookFromCell` (`BookCellModel.swift:641`) opens from the My Books cell (no half-sheet there → no early callback needed; relies on default `nil`). The OverDrive cold-load recovery reopen inside `AudiobookSessionManager` (`:2544`, via `awaitAudiobookContentLocal` `:2118`) is a re-open, not a first open — it does not thread the early callback. **(W3 cite fix)** `downloadProgress(for:)` is on `MyBooksDownloadCenter.swift:1786`, reached via `AppContainer.production().downloadCenter` — the confirmed source for the determinate progress bar.
- **Do NOT reorder the PP-4633 iPad dismissal** — present the shell first, THEN dismiss the sheet underneath (the early callback fires after `presentLoadingShell`, which is exactly present-then-dismiss). No iPad modal-transition race reintroduced.
- **BUG B (button-label flicker on first open) is DEFERRED** to a fast-follow — it lives in a different module cluster (`BookCellModel` throttle, `BorrowReducer`, `LCPFulfillmentHandler` early `.downloadSuccessful`) and would push this past single-module scope. Filed as follow-up; see "Not done."

## Verification criteria (grep-able before declaring done)

- `grep -c "onLoadingShellPresented" Palace/Audiobooks/AudiobookSessionManager.swift` ≥ 3 (param on 2 overloads + ≥1 invocation site).
- **Wiring guard (extracted-seam):** the shell-present + fire is extracted to `presentLoadingShellIfEligible(for:startPlaying:onLoadingShellPresented:)` (deterministically unit-testable without the auth/registry/network gauntlet the full `openAudiobook` requires). `grep -c "presentLoadingShellIfEligible" Palace/Audiobooks/AudiobookSessionManager.swift` ≥ 2 (definition + the call inside `openAudiobook` — the call is the wiring; deleting it re-hangs the sheet). Unit tests drive the extracted method directly and assert presenter-adopts-book + hook-fires.
- **At-most-once fire** (F2 — corrected): the early callback fires 0 or 1 times per open, never twice. It fires only in the shell-present branch (after `presentLoadingShell`). It does NOT fire on the early-failure returns (`.alreadyLoading`, validation) — that is BY DESIGN; the sheet is dismissed there by the final-`onFinish` backstop. A local `Bool` (`didFireLoadingShellPresented`) guards against a second fire if the shell-present branch is ever re-entered. Assert via test, not a contradictory grep.
- **Backstop present:** `grep -n "showHalfSheet = false" Palace/Book/UI/BookDetail/BookDetailViewModel.swift` still shows the dismissal inside the final read/listen completion (`~:689`) — NOT removed.
- `grep -c "showDownloadProgress" Palace/Audiobooks/AudiobookSessionPresenter.swift` ≥ 1 and the manager's wait loop calls it: `grep -c "showDownloadProgress" Palace/Audiobooks/AudiobookSessionManager.swift` ≥ 1.
- `grep -n "awaitAudiobookContentLocal" Palace/Audiobooks/AudiobookSessionManager.swift` still present at the open path (wait NOT removed).
- Every new `await` boundary added in production is driven by a test via the public entry — see Tests. If not drivable (loader needs real audio), STOP + scope-defer that assertion (per skill Phase 1 rule).
- Mutation kill ≥ 80% (diff-only) on `BookService.swift` seam + the presenter progress setter.
- `scripts/verify-pr.sh --quick` PASS (pass `HARNESS_SESSION_SIM_UDID`).

## Tests required (TDD — write first)

1. **`BookService` early-callback ordering** (new `BookServiceAudiobookOpenTests` or extend existing): with a mock `AudiobookSessionManaging` whose `openAudiobook` invokes `onLoadingShellPresented` before its async return, assert the early callback fires BEFORE the final `onFinish`. This is the core regression guard for "sheet dismisses on shell-present, not on full completion."
2. **`BookDetailViewModel` half-sheet dismissal timing**: driving `.listen` on an audiobook, assert `showHalfSheet` flips to `false` on the early presented signal (mock manager fires it) while the open Result is still pending. Contract-snapshot candidate (ordered dependency calls).
2b. **`BookDetailViewModel` stuck-sheet regression (architect F1/F2 — the block):** driving `.listen` on an audiobook where the mock manager returns `.failure` (`.alreadyLoading` / validation) and NEVER fires `onLoadingShellPresented`, assert `showHalfSheet` STILL becomes `false` via the final `onFinish` backstop. This is the must-have guard that the never-fire path doesn't strand the sheet.
3. **`AudiobookSessionPresenter.showDownloadProgress`**: asserts `isDownloading == true` + `overallDownloadProgress == fraction`, and that a subsequent `adoptPlaybackModel` mirror overrides it (later-wins).
4. **Regression floor (must stay green):** `CrossVendorSmokeTests`, `AudiobookOpenStateRaceTests` (loadGeneration supersession — the early callback must not break the generation guard), `AudiobookLoadFailureSAMLReauthTests`.

## Acceptance

- Early presented callback fires once, on MainActor, after `presentLoadingShell`; half-sheet dismisses at shell-present (verified in-sim: sheet gone within ~1s of Listen tap, morphing player skeleton + **download progress bar** visible during the wait, not a frozen sheet).
- **(W1) iPad verify-before-merge:** run one iPad-sim `.listen` pass (in-app nav ON) confirming the player still presents cleanly when the sheet dismisses near-same-tick as `presentLoadingShell` — PP-4633's freeze was "dismiss WHILE player presents." If any iPad freeze appears, defer the early dismiss by one runloop tick (`DispatchQueue.main.async`) so present fully commits first. iPhone repro already clean.
- PP-4542 wait intact; F-011 does not regress (LCP first-open still opens from the local package).
- All Verification criteria pass; regression floor green; mutation ≥ 80% diff-only; `verify-pr.sh --quick` PASS.

## Companion workstream — BUG B (separate PR, same effort)

Per product-owner direction (2026-07-16): **fold BUG B into this effort but ship as its OWN PR** (split A/B in PR). BUG B gets its own branch + fix-contract + architect review + SoD review, tracked at `.forgeos/changesets/fix-audiobook-first-open-flicker/fix-contract.md`.

- **BUG B — first-open button-label flicker** (Cancel↔Download↔Listen bounce). Root: `throttle(50ms,latest:true)` leading+trailing replay (`BookCellModel.swift:365-375`, `BookDetailViewModel.swift:416-428`) + optimistic `bookState=.downloading` racing the registry (`BookDetailViewModel.swift:820`) + LCP early `.downloadSuccessful` promotion (`LCPFulfillmentHandler.swift:204`). Module cluster: `Book` + `MyBooks`.
- **Sequencing:** BUG A (this PR) lands first — it's the reproduced primary complaint and is `Audiobooks`-centered. BUG B follows on its own branch off develop (or stacked on A if it touches shared BookDetailViewModel lines). Two PRs so each gets clean, focused SoD review.

## SoD review round 1 (2026-07-16) — all 3 request-changes, addressed

architect + qa_test + blast_radius all approved the DESIGN (F-011 preserved, dispatch correct, no scope drift) but blocked on two consistent findings, both now fixed:

1. **Contract tests 1/2/2b absent** (all 3 reviewers). Fixed: injected `audiobookSession` into `BookService.open`/`dispatchOpen` (mirrors the existing `bookRegistry` injection) and added `PalaceTests/Book/BookServiceAudiobookOpenTests.swift` — Test 1 (early hook fires before `onFinish`) + Test 2b (session returns `.failure` without firing the hook → `onFinish` backstop still fires → half-sheet still dismisses). A `HookRecordingSession` mock overrides the 3-arg `openAudiobook` so the wiring is driven, not the global singleton.
2. **iPad present-while-dismiss race** (architect). Fixed: the VM's `onLoadingShellPresented` closure now defers the dismiss one runloop tick (`DispatchQueue.main.async`) so the player present commits before the sheet dismisses underneath — preserves present-first-then-dismiss on iPad (PP-4633).

Warnings folded in: mutation "0/0" reworded (no operator surface on changed lines; behavioral coverage by construction — not cited as proof); progress-feed reads the global download center (see Not done).

## SoD review round 2 (2026-07-16) — all 3 approved; VM Test 2 then added

architect + qa_test + blast_radius all APPROVED at tip 7ca030ffc (`review:architect` green). All three left ONE shared non-blocking warning: contract Test 2 (VM-level `showHalfSheet` dismissal) was delivered at the BookService seam, not the VM, and wasn't reconciled in "Not done". Per product-owner direction, Test 2 is now DELIVERED:
- Added an `audiobookSession` injection seam to `BookDetailViewModel` (init param, default nil → BookService resolves the DI-root session) so the audiobook open path is drivable with a mock.
- `BookDetailViewModelAudiobookDismissTests.testHandleActionListen_earlyShellHook_dismissesHalfSheetBeforeOpenCompletes`: drives the REAL `handleAction(.listen)` path (auth gate completes fast in-test, no network) with a mock session that fires the shell hook then HOLDS the open 3s; asserts the half-sheet dismisses within 1.5s. This ISOLATES the early hook — a mutant removing the early dismissal leaves the sheet up until onFinish (3s) and fails the 1.5s window. 9 new tests total; full set 48/48 green.

## Not done (this PR)

- **Progress-feed-during-wait mutation/unit coverage** (qa/blast warning): the `onProgress` sampling inside the static `awaitAudiobookContentLocal` reads `AppContainer.production().downloadCenter` and lives behind the `#if LCP` auth/registry/network gauntlet — not unit-driven. `showDownloadProgress` (the sink) IS fully tested; that it's *fed during the wait* is verified by the live sim repro, not a unit test. Cosmetic (progress bar). Explicit scope-defer.
- **iPad-sim verify** still recommended as belt-and-suspenders even with the one-tick deferral (architect W1).
- **Palace-noDRM build** (not in CI) — hook is outside `#if LCP`; blast_radius reasoned it compiles; verify by launching noDRM on a sim.
- **Full-suite CI-parity run** — spot-check only so far.
- BUG B — its own PR (above), not deferred.
