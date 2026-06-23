---
name: audiobook-rc-regressions-3.2.0
created: 2026-06-22
author: Maurice Carrier
branch: fix/audiobook-rc-regressions-3.2.0
priority: PP-4631 (Blocker) + PP-4633 / 3.2.0 RC (build 481) regression fixes
---

# Intent: two 3.2.0 RC audiobook/book-detail regressions

Landed on `release/3.2.0` FIRST (RC lineage, build 481), then forward-ported
to `develop`, then a new RC build is cut so QA testing can continue.

## Context

Two regressions surfaced in 3.2.0 RC build 481 (RC testing under PP-4572):

- **PP-4631 (Blocker):** OverDrive & Unlimited Listens audiobooks fail to open
  ("An error was encountered while trying to open this book"); LCP/Findaway are
  fine. Root cause is PR **#979** (Audiobook Vendor Adapter Extraction), NOT
  #981. The refactor replaced the pre-swarm runtime (body-based) bearer-token
  detection with a static top-level-MIME gate, `BearerTokenMIMEGate.canHandle`
  (`Adapters+Production.swift:100`), which only fires when
  `book.defaultAcquisition?.type == application/vnd.librarysimplified.bearer-token+json`.
  For OverDrive / Unlimited Listens the bearer-token MIME is nested in the
  `indirectAcquisition` chain, not the top-level `type`, so the gate misses and
  the book falls through to `OpenAccessAdapter`, which (per its carve-out) had no
  bearer detection — it treats the bearer-token *wrapper* JSON as the manifest,
  which fails decode → the error alert.

- **PP-4633 (Normal, iPad):** tapping Listen (and Read) leaves the half-sheet on
  screen; the player/reader opens behind it. The `.read, .listen` case in
  `BookDetailViewModel.handleAction` never set `showHalfSheet = false` (unlike
  its `.reserve` / `.return` siblings). iPad form-sheet geometry exposes it;
  iPhone's full-width detent masks it. From modernization PR #811.

## Claims

- PP-4631: `OpenAccessAdapter` (the chain's fallback) regains the pre-swarm
  runtime bearer-token detection — after fetching+parsing the body, if it parses
  as a bearer-token wrapper (`MyBooksSimplifiedBearerToken.simplifiedBearerToken(with:)`),
  it records the token on the book and follows the second leg to the real
  manifest via the injected `BearerTokenManifestFetching`. Detection is
  body-based, so it is immune to where the bearer MIME is declared in the OPDS
  feed (top-level vs nested indirectAcquisition). The top-level-MIME
  `BearerTokenMIMEGate` → `BearerTokenAdapter` fast path is unchanged.
- The bearer fetcher is an OPTIONAL injected collaborator (default `nil`); only
  production wiring (`AudiobookLoader.makeProductionAdapters`) passes the real
  `ProductionBearerTokenManifestFetcher`. With no fetcher (open-access-only
  tests), detection is skipped → existing behavior preserved.
- PP-4633: the `.read, .listen` and `.readStreaming` cases set
  `showHalfSheet = false` in the OPEN COMPLETION (after the reader/player is
  presented), mirroring `.reserve` / `.return`. (Corrected from an initial
  on-tap dismiss, which on iPad raced the form-sheet dismissal against the
  player presentation and froze the screen — present first, then dismiss the
  sheet underneath.)

## Verification

- Unit (PP-4631): 5 tests in `OpenAccessAdapterTests` — bearer wrapper →
  follows second leg & returns the real manifest (not the wrapper) + records
  token/fulfillURL; nil second leg → `.manifestFetchFailed`; bearer body with no
  fetcher → returns body verbatim (back-compat); plain manifest with fetcher →
  returned directly, no second leg. Existing 6 OpenAccess tests unchanged.
- Unit (PP-4633): 2 tests in `BookDetailViewModelTests` — `handleAction(.read)`
  and `handleAction(.listen)` set `showHalfSheet = false`.
- Build: `xcodebuild build` (Palace scheme, iOS Simulator) succeeds.

## Files in scope

- `Palace/Audiobooks/Vendors/OpenAccessAdapter.swift` — optional bearer fetcher + body-based bearer detection + header doc.
- `Palace/Audiobooks/AudiobookLoader.swift` — wire `ProductionBearerTokenManifestFetcher` into the fallback `OpenAccessAdapter`.
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift` — `showHalfSheet = false` in `.read, .listen` and `.readStreaming`.
- `PalaceTests/Audiobook/Vendors/OpenAccessAdapterTests.swift` — 5 new bearer-recovery tests.
- `PalaceTests/Book/BookDetailViewModelTests.swift` — 2 new half-sheet-dismiss tests.

## Anti-claims

- Does NOT change the top-level-MIME `BearerTokenMIMEGate` / `BearerTokenAdapter`
  fast path, nor the LCP / LocalFile / OpenAccess chain order.
- Does NOT broaden the gate to walk the indirectAcquisition tree (rejected:
  depends on indirect-chain population; body-based detection is more robust and
  is the proven pre-swarm behavior).
- Does NOT change OPDS parsing, the bearer-token wrapper format, or
  `MyBooksSimplifiedBearerToken`.
- Does NOT address PP-4632 ("returned audiobooks still play") — flagged as a
  likely-related sibling in the same adapter area but out of scope here.
- Does NOT include a runtime device/sim repro of PP-4631 (the OverDrive loan
  open) or PP-4633 (iPad modal) — both blocked on this CLI sim build by the
  background-URLSession download limitation; verification here is unit-level +
  grounded root cause. Runtime QA validation happens on the new RC build.
- Does NOT bump the build number in this commit — the 481→482 RC bump is a
  separate release-chore commit after the fix lands.
