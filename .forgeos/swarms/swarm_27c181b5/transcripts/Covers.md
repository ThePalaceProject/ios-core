# Module Covers — implementation transcript (swarm_27c181b5)

## Summary
Implemented B1 (circuit-breaker threshold honored + reachability-driven reset),
B2 (cell/prefetch source-URL unification for small displays), and B3 (duplicate
`.set` review — retained with instance-identity documentation, deletion NOT
safe). All within the contracted file allow-list; AccountsManager / CatalogUI /
Network untouched.

## Files changed (production)
- `Palace/Book/Models/TPPBookCoverRegistry.swift`
  - **B1a** `HostRecord.isTripped` now reads a per-record `failureThreshold`
    (copied from the actor at record creation): `consecutiveFailures >= failureThreshold`,
    replacing the hardcoded `>= 1`. `recordFailure` builds records with
    `HostRecord(failureThreshold: failureThreshold)`.
  - **B1b** default `failureThreshold` init param raised `1 → 3`.
  - **B1c** Added a `.TPPReachabilityChanged` observer in the actor initializer
    that calls `hostFailureTracker.reset()` (previously reset() had ZERO
    cover-path callers). Observer token stored in `reachabilityObserverToken`,
    removed in `deinit`. Closure captures only the Sendable `tracker` (not
    `self`), so it is sound to install from the actor init. Added
    `import PalaceNetwork` — `Notification.Name.TPPReachabilityChanged` is
    declared in PalaceNetwork and is NOT re-declared on `Notification.Name` in
    the Palace target (NSNotification+TPP only bridges it onto `NSNotification`),
    so the import is required (mirrors `BookCellModel`).
  - **B2** Added `nonisolated static func coverSourceURL(imageURL:thumbnailURL:displayPoints:)`
    + `static let smallDisplayThreshold: CGFloat = 200`. `coverImage(for:displayPoints:)`
    now selects the source URL through it: small displays (≤200pt catalog cells)
    prefer `imageThumbnailURL` (with full-size fallback), so the cell's
    `sourceData(for:)` fetch coalesces onto the same URL-keyed download prefetch
    uses. Larger displays keep full-res `imageURL`.
- `Palace/Utilities/ImageCache/ImageLoaderImpl.swift`
  - **B3** Both paired `.set` sites (coverKey ~118-119, thumbnailKey ~149-150)
    RETAINED with an instance-identity comment (see decision below).
- `Palace/Book/Models/TPPBook+Presentation.swift` — reviewed, NOT modified (see B3).

## Files changed (tests, added to PalaceTests target via pbxproj_add_swift.rb, added=2)
- `PalaceTests/Book/HostFailureTrackerTests.swift`
  - `testHostFailureTracker_singleFailure_belowThreshold_notTripped` — threshold=3;
    1 failure → `isHostFailing == false`; 3 consecutive → `true`. Kills the
    `>= failureThreshold` → `>= 1` regression and any `+=`/threshold mutant.
  - `testHostFailureTracker_reachabilityChange_resetsCircuit` — trip (threshold=1,
    1 failure), drive `reset()`, assert cleared. Body literally performs the
    trip→reset→assert steps ("reset" multi-step check honored).
- `PalaceTests/Utilities/ImageCoverKeyUnificationTests.swift`
  - `testCoverKey_cellAndPrefetch_coalesceForSmallDisplay` — small display resolves
    to thumbnail URL (== prefetch URL); large display resolves to full-size URL
    (discrimination proof). Kills threshold-comparison and "always return one
    side" mutants.
  - `testCoverSourceURL_smallDisplayWithNoThumbnail_fallsBackToFullSize` — nil
    thumbnail on a small display falls back to full-size (never nil).
  - Uses `try XCTUnwrap` for URLs — no force-unwraps.

## B3 identity decision — RETAIN both sets (deletion NOT safe)
Grepped `TPPBook.swift`: `imageCache` is an injected `let` (init param), defaulted
to `ImageCache.shared` in the production factory inits (lines 248, 354) but freely
injectable (public init; propagated as `self.imageCache` at 387/441). The
`ImageLoader.cache` is a SEPARATE injection point (`AppContainer.production()`
wires `ImageCache.shared`, line 547). The two `.set` calls therefore target the
same object ONLY under the `ImageCache.shared` production convention — the code
does NOT structurally guarantee identity (two independent injection sites; tests
inject mock caches). `cache.set` warms the loader's cache (`coverImage(for:)`
reads it); `book.imageCache.set` warms the book's cache (`TPPBook.fetchCoverImage`
sync check reads it). When the two caches differ (test/preview), BOTH are needed.
Per the contract ("delete ONLY after asserting instance identity; if you cannot
prove identity, leave the set and note it — do NOT guess"), I could NOT prove
universal identity, so I retained both and added instance-identity comments at
both sites (satisfies verification criterion #5's retain-with-comment path). Same
review at `TPPBook+Presentation.swift`: line 87 is a single set (no same-key
pair); `fetchThumbnailImage` (142-143) sets two DIFFERENT keys (identifier +
`_thumbnail`) — intentional dual-key, not a duplicate. No change made.

## Verification (grep-able criteria from contract §Verification)
1. `consecutiveFailures >= failureThreshold` → 1 ; `consecutiveFailures >= 1` → 0 ✅
2. default raised: `failureThreshold: Int = 3` (≥2) ✅
3. `.reset()` in registry → 1 (reachability observer) ✅
4. `coverImage(for:displayPoints:)` path references `imageThumbnailURL` (via coverSourceURL) ✅
5. B3 retained pairs carry instance-identity comments ✅
6. `HostFailureTracker(` in HostFailureTrackerTests → 2 (≥1) ✅
7. `check-test-name-vs-body.py` on both new test files → exit 0 / 0 ✅
   - HostFailureTrackerTests.swift: exit 0
   - ImageCoverKeyUnificationTests.swift: exit 0

## Definition-of-Done evidence
- SUT instantiation (#1): `HostFailureTracker(` ×2 in HostFailureTrackerTests.
  ImageCoverKeyUnificationTests is a themed name (contract-mandated filename, no
  `ImageCoverKeyUnification` production type); its bodies make the static call
  `TPPBookCoverRegistry.coverSourceURL(...)`.
- Multi-step (#3): `reachabilityChange_resetsCircuit` body performs trip→reset→assert.
- Scope audit (#4): B1/B2/B3 all in diff; no scope reduction.
- No force-unwraps; no fluff tests (each asserts a real behavior + a
  discrimination/edge case).

## Deferred to integrator (constraint: this agent must NOT run git / full build)
- **#5 mutation, #6 build + verify-pr.sh --quick, #7 line-coverage, #8 contract-
  reconciliation, #9 blast-radius, #10 adjacency, #11 superpartner-spectrum** —
  these require git-diff / a full app build, which the module contract forbade
  this implementer from running. They must be run by the swarm integrator before
  merge. Note the new API surface for #9: one `nonisolated static func
  coverSourceURL(...)` + `static let smallDisplayThreshold` on
  `TPPBookCoverRegistry` (internal, not public) — behavior-additive, no public
  surface change.
- Build risk flagged & pre-mitigated: added `import PalaceNetwork` so
  `.TPPReachabilityChanged` resolves.
