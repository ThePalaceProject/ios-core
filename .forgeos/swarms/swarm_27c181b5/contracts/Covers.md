# Module Covers — honor circuit-breaker threshold, unify cover/prefetch key, dedup sets (standard)

## Goal
One Wi-Fi↔cellular blip stops blacklisting the whole cover CDN for 300s. Cell and
prefetch fetch the SAME URL/key so dedup coalesces (no 2× full-res download per book
after a switch). Kill cache-key proliferation + duplicate sets.

## Changes
- B1: `HostRecord.isTripped` (:26) references `failureThreshold` (actor param)
  instead of hardcoded `>= 1`; default `failureThreshold` (:31) raised to 2-3. Add a
  reachability-change observer inside the registry that calls the existing `reset()`
  (:66) — today reset() has ZERO cover-path callers.
- B2: verified — cell `coverImage(for:displayPoints:)` fetches `book.imageURL`
  (full-size, :205) while prefetch fetches `book.imageThumbnailURL`. For small
  display sizes, prefer `imageThumbnailURL` so cell + prefetch share one dedup key.
- B3: `ImageLoaderImpl` sets the same image under one key TWICE (:118-119, :149-150);
  same object ONLY when built with `ImageCache.shared`. Collapse to one canonical key
  per book+size-class; delete the redundant set ONLY after asserting instance
  identity. Same review at `TPPBook+Presentation.swift:87`.

## Test contracts
1. `testHostFailureTracker_singleFailure_belowThreshold_notTripped` (threshold=3);
   record threshold-many → tripped.
2. `testHostFailureTracker_reachabilityChange_resetsCircuit`.
3. `testCoverKey_cellAndPrefetch_coalesceForSmallDisplay`.

## Files OFF-LIMITS
AccountsManager.swift (the reset() CALL-site is Accounts-Startup's); CatalogUI/*; Network/*.

## Verification criteria (grep-able)
1. `grep -c 'consecutiveFailures >= failureThreshold' Palace/Book/Models/TPPBookCoverRegistry.swift` → ≥1;
   `grep -c 'consecutiveFailures >= 1' …` → 0
2. Default raised: diff shows `failureThreshold: Int = ` value ≥2
3. `grep -c '\.reset()' Palace/Book/Models/TPPBookCoverRegistry.swift` → ≥1 (reachability observer)
4. B2: diff of coverImage(for:displayPoints:) references `imageThumbnailURL`
5. B3: diff removes ≥1 duplicate `.set(`; any retained pair has an instance-identity comment
6. `grep -c 'HostFailureTracker(' PalaceTests/Book/HostFailureTrackerTests.swift` → ≥1
7. `python3 scripts/check-test-name-vs-body.py` on both new test files → exit 0
8. `scripts/verify-pr.sh --quick` PASS
