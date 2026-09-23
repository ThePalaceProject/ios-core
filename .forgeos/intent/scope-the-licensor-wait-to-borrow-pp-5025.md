---
name: scope-the-licensor-wait-to-borrow-pp-5025
created: 2026-08-25
author: claude-opus-5
type: bugfix
tracking: PP-5025 — surfaced while validating the Wipro 2.0 / RMSDK 13.0 DRM connector. Neither defect is caused by the connector; both reproduce regardless of which connector is installed. Crash artifact Palace-2026-08-25-110205.ips; race captured on device (Moes Max) and simulator.
related_prs: []
---

# Intent: PP-5025 follow-ups — borrow/licensor race + cover-cache double read

## Claims

- `AdobeDRMService.ensureDeviceActivated` can give a missing Adobe licensor a
  **bounded grace period** before failing, instead of reading it once and
  throwing `.noActivation` immediately. Adds
  `AdobeDRMService.awaitLicensor(_:within:)` (wall-clock deadline, 0.1s poll,
  returns immediately on cancellation), the `defaultLicensorGracePeriod` (15s)
  constant, and a `licensorGracePeriod:` parameter on BOTH
  `ensureDeviceActivated` overloads.
- **The grace period is opt-in and defaults to `0`.** Only `BorrowOperation`
  passes a budget — that is where the race was measured, and the only
  activation path that can afford to wait. The read path
  (`BookDetailViewModel`) and the fulfillment dispatcher
  (`RightsManagementDispatcher`) keep their existing fail-fast behaviour, so
  neither gains a stall. A fail-safe default also means a future caller cannot
  acquire a 15-second wait by accident.
- `BorrowOperation` hoists `bookRegistry.setProcessing(true, …)` ABOVE the DRM
  activation block and clears it if activation throws. Without this the wait is
  invisible on cell surfaces: `BookCellModel.didSelectDownload` sets no
  `isLoading`, so the catalog Get button would sit unchanged and tappable for
  the whole wait while the duplicate-tap guard keys on download info that does
  not exist yet.
- Extracts the cover-image memory-cache lookup to
  `TPPBook.firstCachedImage(in:keys:)`, which reads each key **exactly once**,
  replacing `lookupKeys.lazy.compactMap { self?.imageCache.get(for: $0) }.first`.
  Lazy `compactMap` expands to `map(t).filter { $0 != nil }.map { $0! }` and so
  evaluates the closure twice per key; the trailing force-unwrap traps whenever
  the second read disagrees with the first (cache eviction, or `self`
  deallocating).
- Changes no existing test's assertions. Because the default is `0`, existing
  callers and their tests behave exactly as before.

## Anti-claims

- Does **NOT** change `TPPUserAccount.setLicensor` to post
  `notifyAccountDidChange()`. That asymmetry (its neighbour `setPatron` does
  post) is why the wait is polled rather than event-driven, and fixing it would
  change what every existing account observer sees — it wants its own call-site
  census.
- Does **NOT** change the read path, the fulfillment dispatcher, or any
  activation path other than borrow. They keep fail-fast behaviour by keeping
  the `0` default.
- Does **NOT** change the guard ORDER in `ensureDeviceActivated`: the
  already-activated fast path and the `isDRMAvailable` guard still run before
  the licensor is consulted, and the single-flight coordinator still sits below
  all of them.
- Does **NOT** remove the licensor guard. A licensor that never arrives still
  throws `.noActivation`; the grace period defers the guard, it does not delete
  it.
- Does **NOT** widen public API. `firstCachedImage` is `internal`; the test
  reaches it via `@testable import PalaceBookModel`.
- Does **NOT** touch the Adobe connector, its binaries, the DRM fulfillment
  path, or anything about the PP-5025 connector validation itself — that needs
  no app changes and is recorded on the ticket.
- Does **NOT** alter the async/disk cache path, the network fetch, the
  thumbnail path, or the `finitePositiveDimension` NaN guard (PP-4772) in
  `fetchCoverImage`.

## Files in scope

- Palace/Reader2/ReaderStackConfiguration/AdobeDRM/AdobeCertificate.swift
- Palace/MyBooks/BorrowOperation.swift
- Palace/MyBooks/BorrowAdobeActivationStep.swift (new)
- Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBook+Presentation.swift
- PalaceTests/DRM/AdobeActivationLicensorGraceTests.swift (new)
- PalaceTests/Books/TPPBookCoverCacheLookupTests.swift (new)
- PalaceTests/DRM/AdobeActivationDedupTests.swift
- Palace.xcodeproj/project.pbxproj

## Reproduction

**Borrow/licensor race** — real artifact, device and simulator, captured while
testing the 2.0 connector:

    12:09:38.942  AdobeCertificate.swift: No Adobe DRM licensor credentials stored — cannot activate
    12:09:38.942  DownloadStartCoordinator.swift: Borrow failed: Device not activated
    12:09:51.885  TPPSignInBusinessLogic+DRM.swift: Saving DRM licensor credentials (activation deferred to borrow time)

The licensor is written on the user-profile-document leg of sign-in, which
completed 13 seconds after the auth gate had already released the queued
borrow. Borrowing again afterwards succeeds, which is what made this look like
a DRM/connector fault.

**Cover-cache trap** — `Palace-2026-08-25-110205.ips`:
`_assertionFailure` → `closure #2 in LazySequenceProtocol.compactMap` →
`LazyMapSequence.subscript.read` → `Collection.first.getter` →
`TPPBook.fetchCoverImage(forDisplayHeight:)` →
`CatalogContentView.swift:93` (the lane-prefetch `onAppear`).

## Root cause

**Borrow/licensor race.** Sign-in writes the Adobe licensor on the
user-profile-document leg (`TPPSignInBusinessLogic+DRM.saveDRMCredentials` →
`userAccount.setLicensor`), but the auth gate that releases a queued borrow
resumes on `hasCredentials() && authState == .loggedIn`, which is reached
earlier. `ensureDeviceActivated` then read `userAccount.licensor` exactly once
and threw `.noActivation` on a nil that was about to become non-nil. Nothing
made the two orderings agree, and nothing could observe the later write:
`setLicensor` does not post `notifyAccountDidChange()`, unlike its immediate
neighbour `setPatron`, so there is no change signal for a waiter to await.

**Cover-cache trap.** `LazySequenceProtocol.compactMap` is
`map(transform).filter { $0 != nil }.map { $0! }` — the transform is evaluated
once by the filter and again by the trailing force-unwrap. The lookup's
transform was `{ [weak self] in self?.imageCache.get(for: $0) }`, which reads
mutable shared state and captures `self` weakly, so its two evaluations are not
guaranteed to agree. When they disagree — the cache evicted the entry, or
`self` deallocated — the `{ $0! }` unwraps nil and traps. The bug is not the
cache and not the key list; it is using a double-evaluating lazy combinator
over a non-deterministic closure.

## Not done

- **The borrow site's opt-in is not itself pinned by a test.** Deleting the
  `licensorGracePeriod:` argument at `BorrowOperation.swift` would make the fix
  inert with the suite green. `BorrowOperation` takes a concrete
  `AdobeDRMService` rather than a protocol, so there is no spy seam to assert
  the argument; introducing one is a wider refactor than this fix warrants.
  `test_defaultLicensorGracePeriod_isANonZeroBudget` pins the constant's value
  but not its use.
- **Grace × single-flight is untested.** `awaitLicensor` runs above
  `activationCoordinator.activate`, so N concurrent borrows each poll
  independently before any de-duplication. Writable with the existing
  read-count stub; not written here.
- **`setLicensor` still does not notify.** See Anti-claims.
- The 15s budget is fitted to a single measured observation (13s) with ~2s
  margin. It is a starting value, not a derived one.

## Verification

Both fixes were proved by reintroducing the defect against the committed tests
(a green test is not evidence a guard bites):

- Restoring the lazy `compactMap` produced
  `Swift/FlatMap.swift:49: Fatal error: Unexpectedly found nil while unwrapping
  an Optional value` — the production crash signature — and failed
  `test_lookup_onHit_consultsCacheExactlyOncePerKey` and
  `test_lookup_fallsThroughToLaterKey_whenEarlierMisses` on doubled call counts,
  while `test_lookup_whenEntryIsEvictedBetweenReads_…` trapped the runner.
- Restoring the lazy `compactMap` at the CALL SITE ONLY — leaving the corrected
  helper in place but unused — failed `test_fetchCoverImage_onHit_doesNotReReadTheHitKey`
  with `("2") is not equal to ("1")`. This mutant survived the first round of
  tests, which exercised only the helper; it was caught in review as a green
  guard on the wrong surface and the caller-level tests were added for it.
- Restoring the single licensor read failed
  `test_ensureDeviceActivated_whenLicensorArrivesLate_waitsAndActivates` with
  `caught error: "drm(Palace.DRMError.noActivation)"` — the exact production
  symptom — while the other four tests in that file continued to pass, so the
  suite is targeted rather than blanket-failing.
