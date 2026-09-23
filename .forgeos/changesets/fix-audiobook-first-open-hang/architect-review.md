# Architect review — fix-contract "Audiobook first-open hang" (BUG A)

**Reviewer role:** architect (independent)
**Branch:** `fix/audiobook-first-open-hang` (contract-only; no code staged)
**Round 2 verdict:** **APPROVED** — the round-1 block (F1) is resolved by the additive-backstop design. Three non-blocking warnings to fold into implementation.

---

## Round-1 findings — disposition

### F1 (was fail) — RESOLVED
Dismissal is now additive, not a move (scope-in bullet 5, `:23`). The final-`onFinish` dismissal at `BookDetailViewModel.swift:689` STAYS; the early `onLoadingShellPresented` callback ADDS an earlier dismissal on the shell-present path. This fully closes the stuck-sheet gap on ALL early-return paths, because `BookService.dispatchOpen`'s audiobook `defer { … onFinish?() }` (`:84-88`) wraps `await openAudiobook(...)` and fires `onFinish` **regardless of the Result** — including the `.alreadyLoading` (`:617-620`) and validation-failure (`:640-645`) early returns, which never present a shell and never fire the early callback. Both writes are `showHalfSheet = false` → idempotent, order-independent. Verified against the actual `defer` semantics.

### F2 (was concern) — RESOLVED
Self-contradictory "single fire" grep removed. The at-most-once (0-or-1) `didFireLoadingShellPresented` Bool design (`:37`) is sound, and **test 2b** (`:49`) is exactly the right guard: mock manager returns `.failure` WITHOUT firing the early callback → assert `showHalfSheet` still becomes false via the backstop. That test catches the never-fire regression; a grep never could.

### F3 / F4 (were warnings) — RESOLVED
Sibling callers named in Scope(out) (`:30`): `BookCellModel.openAudiobookFromCell` (`:641`, no half-sheet → default `nil`, unchanged) and the OverDrive cold-load recovery reopen (`:2544`, a re-open, not a first open). Both correctly unaffected via the defaulted param. `downloadProgress(for:)` confirmed as the progress source.

---

## New (round-2) findings — all warnings, none blocking

### W1 — verification / **warning**: iPad present-then-dismiss timing is asserted, not verified
Scope-out (`:31`) reasserts "No iPad modal-transition race reintroduced," and Acceptance (`:55`) verifies in-sim on **iPhone only** (repro env is iPhone 17 Pro, `:5`). The additive change moves the sheet dismissal from ~19s-after-present (current shipping behavior) to **~same tick as `presentLoadingShell`**. `presentLoadingShell` only *kicks off* the morphing-player fullScreenCover (sets `isPlayerExpanded = true`); the UIKit transition completes asynchronously. PP-4633's own in-code note (`BookDetailViewModel:676-686`) says dismissing the form-sheet *while the player is being presented* races on iPad and freezes the player — the fix relied on temporal separation, which the early callback compresses. The additive backstop guarantees the sheet dismisses eventually, but it does NOT protect against a player-fails-to-present freeze. Exposure is limited to `inAppPlaybackNavEnabled == true` (morphing player on).
**Recommendation:** add one iPad-sim acceptance pass (drive `.listen` on an LCP audiobook with in-app nav ON → assert the morphing player presents AND the sheet dismisses, no freeze). Optionally defer the early dismiss by one runloop tick after `presentLoadingShell` so the presentation transaction completes first (literal present-then-dismiss). Cheap to close; I assessed this axis as passing in round 1, so this is a verify-don't-assume ask, not a design objection.

### W2 — scope / **warning**: two-site vs one-site fire description is internally inconsistent
Scope-in bullet 2 (`:19`, unchanged) still says fire "after `presentLoadingShell`" AND "when the shell is NOT presented … invoke it right before returning" (two fire sites). The new F2 text (`:37`) says it "fires only in the shell-present branch." Under the additive backstop both readings are SAFE (no double-fire via the Bool; no stuck sheet via the backstop), so this is editorial, not a correctness gap — but reconcile them. The non-shell fallback fire is now redundant with the backstop; simplest is to delete it from `:19` and let the shell-present branch be the sole early-fire site.

### W3 — scope / **warning**: wrong file citation for the progress source
`:30` cites `downloadProgress(for:)` as `AudiobookSessionManager.swift:1786`. The method is `MyBooksDownloadCenter.downloadProgress(for:) -> Double` at **`MyBooksDownloadCenter.swift:1786`** (reached via `AppContainer.production().downloadCenter`). Intent is correct; fix the file label so the implementer reads off the right source.

---

## Confirmations carried forward (pass)
- **F-011 / PP-4436 preserved:** `awaitAudiobookContentLocal` + the PP-4542 gate (`:681-699`) untouched; early callback fires at `:660`, before the gate (`:681`) and the `loadGeneration` bump (`:710`); `presentOnFirstOpen()` sync-before-Task ordering (`AudiobookSessionPresenter.swift:220`) intact.
- **Presenter later-wins:** `adoptPlaybackModel` (`:317`) unconditionally re-snapshots `overallDownloadProgress`/`isDownloading` (`:333-334`) after the wait/bind; `clearActiveSession` resets both. The `showDownloadProgress` setter is safe.
- **BUG B split:** clean disjoint-module split (now its own PR per product-owner direction, `:59-64`) — BUG A does not touch the throttle/label surface.

---

## Bottom line
APPROVED. The substantive block (stuck sheet on pre-shell failure) is correctly closed by keeping the always-fired final `onFinish` as an idempotent backstop, and test 2b locks it. Fold W1 (iPad verification — the only one with any runtime risk), W2 (reconcile the fire-site wording), and W3 (fix the file citation) into implementation. None block; W1 must be verified before merge, not before contract approval.
