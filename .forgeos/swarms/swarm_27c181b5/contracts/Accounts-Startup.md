# Module Accounts-Startup — registry read-once + O(n²) dict + cover-reset call (standard-sensitive)

## Goal
Three surgical, non-semantic AccountsManager edits. NO signature or state-machine
changes.

## Changes (internal only)
- C1: `hasCachedCatalogData(hash:)` (:1171) stops doing a full `Data(contentsOf:)`
  just to test existence — use `FileManager` stat. The single real read is threaded
  through `preloadAccountsFromDiskCacheSync` (:487-490) and the SWR branch in
  `loadCatalogs` (:870-871) so bytes are read ONCE.
- C4: in `loadAccountSetsAndAuthDoc` (:1356), build `[uuid: Account]` from
  `oldAccounts` once (precedent `accountByUUID` :283); replace
  `oldAccounts.first(where: { $0.uuid == newAccount.uuid })` (:1376) with a dict lookup.
- B1 call-site: in the `currentAccount` setter, next to
  `ImageCache.shared.evictDecodedImages()` (~:585), add
  `TPPBookCoverRegistry.shared.reset()`.

## Test contracts
1. `testPreload_readsRegistryCacheOnce` — seed disk cache, spy read path, assert the
   byte-read happens exactly once (existence check does not read bytes).
2. `testLoadAccountSets_carryOver_isCorrectForEveryMatchingUUID` — with a large
   oldAccounts set, carry-over of authDoc + logo is correct for every matching uuid.
3. `testCurrentAccountSetter_onSwitch_resetsCoverCircuitBreaker`.

## Files OFF-LIMITS (same-file, different-contract regions)
`preloadAccountsFromDiskCacheSync` account-object HYDRATION semantics (CP-D1);
`loadCatalogs` bundled-snapshot branch :889-911 + dedupe reorder + crawl QoS (CP-D3);
`TPPBookCoverRegistry.reset()` IMPLEMENTATION (Covers).

## Verification criteria (grep-able)
1. Existence no longer reads bytes: diff of hasCachedCatalogData region adds
   `fileExists`/`attributesOfItem`/`FileManager`.
2. `grep -c 'TPPBookCoverRegistry.shared.reset()' Palace/Accounts/Library/AccountsManager.swift` → ≥1
3. Dict carry-over: diff adds `[…uuid…: Account]` / `Dictionary(uniqueKeysWithValues`; the :1376 `first(where:` site removed.
4. `grep -c 'AccountsManager(' PalaceTests/Accounts/AccountsManagerCacheReadTests.swift` → ≥1
5. `python3 scripts/check-test-name-vs-body.py PalaceTests/Accounts/AccountsManagerCacheReadTests.swift` → exit 0
6. Anti-overlap: diff does NOT touch the bundled-snapshot branch.
7. `scripts/verify-pr.sh --quick` PASS
