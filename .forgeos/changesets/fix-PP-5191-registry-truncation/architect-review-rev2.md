# Architect post-review — PP-5191 fix-contract **rev 2** (contract only, no code)

**Branch:** `fix/PP-5191-registry-truncation` · **Worktree:** `/Users/mauricework/PalaceProject/wt-5191`
**Base verified:** `git rev-parse --short HEAD` → `ea61dd998` (matches the contract's stated base)
**Reviewer:** architect (independent) · **Date:** 2026-09-21 · ForgeOS OFF — no MCP call, no signed verdict.

## VERDICT: **BLOCKED** (narrowly — 3 blockers, all in the new `replaceBucket` / INV-2 surface)

Rev 2 closes all 8 of my rev-1 items, and closes them honestly: I re-ran every one of C1–C12
against `ea61dd998` and **all twelve reproduce the observed values in your table exactly**.
That is the first contract in this area whose verification section I could not break by running it.

The block is that the *new* machinery — `replaceBucket` + INV-2 — carries three unspecified
cells, and two of them are launch-path failures with a silent false-green. One of them breaks
**named existing tests** and **every upgrading install**; I have the fixture bytes.

---

## Your two targeted questions

### (a) Ledger row 4 — **the fact is TRUE, the inference is INVALID. The row survives, its evidence does not.**

I verified the read. `AccountRegistryStore.buildAccountIndex` does flatten every bucket:

    static func buildAccountIndex(_ sets: [String: [Account]]) -> [String: Account] {
        var index = [String: Account]()
        for accounts in sets.values { for account in accounts { index[account.uuid] = account } }

and `account(_:)` reads `accountByUUID[uuid]` before the slim fallback. So: **a uuid loaded
under *any* hash resolves under *every* hash.** Confirmed.

But that is not what row 4 needs to prove. The rival "hash mismatch" hypothesis is *"the bucket
actually in use was keyed under a hash whose feed never contained this library"* — e.g. a custom
registry URL (`TPPConfiguration.customRegistryIsExplicitURL()`, `AccountRegistryLoader.swift:528`)
whose feed simply lacks Cortland. Flattening says nothing about a uuid that is in **no** bucket.
As written the row proves "loaded-elsewhere still resolves" and then concludes "never-loaded
also resolves". Non-sequitur.

**The row is still ruled out — by a different argument, which you already own.** `loadCatalogs`
path 3 computes `hash` from whatever `targetUrl` is *currently* active (prod, beta, or custom,
`:456-463`) and commits the bundled 1142 under **that** hash (`:507` → `:735`) before any network
call. Both UUIDs are in the bundle. Combined with flattening, there is no active-hash value for
which a *successfully entered* path 3 leaves these uuids unresolvable. So the hash is irrelevant
to the outcome — which is a stronger statement than rev 2 makes, and it is hash-independent.

**Required:** restate row 4's evidence as "*path 3 commits the bundle under whichever hash is
active, and `buildAccountIndex` flattens all buckets — so the hash cannot be the discriminator*",
and note the one residual it leaves open (a custom registry URL that genuinely lacks the library
is a different cause, not this one, and is out of class). Do not leave the current wording: a
reviewer who checks it finds a true fact supporting a conclusion it does not reach, and stops
trusting the rest of the ledger.

**Free observation while I was in there (not yours to fix):** flattening means that when two
buckets both hold a uuid, `index[account.uuid] = account` lets the **last-enumerated bucket win**,
and `Dictionary.values` order is nondeterministic. So `account(uuid)` across a prod/beta mismatch
returns a nondeterministically-chosen instance. The code comment at `buildAccountIndex` already
owns this ("equivalent to the nondeterministic 'first across `values`'"). It does not affect your
ledger, but it does mean "resolves across a hash mismatch" is weaker than it sounds.

### (b) `replaceBucket` routing `hydrateFullAccountSets` — **two real hazards, one of them a launch deadlock**

**No added decode — confirmed good.** `hydrateFullAccountSets` (`:320-336`) already decodes
`OPDS2CatalogsFeed.fromData(cachedData)` at `:322`, so `feed.metadata.numberOfItems` is free.
You are adding one `Int` comparison. Throughput in the CP-D1 window is a non-issue.

**B-1 (BLOCKER) — the lock composition is unspecified, and two of the three obvious
implementations are wrong, one fatally.** `AccountRegistryStore.mutate` takes
`accountSetsLock.write { }`, and `ReadWriteLock` is a bare `pthread_rwlock` — **non-recursive**.

- `replaceBucket` = `performRead { current }` … then `mutate { … }` → **TOCTOU**. Two acquisitions;
  a concurrent crawl write can land between the decision and the apply. On this path the reader is
  the launch thread and the writer is an owned crawl task — a real interleaving, not a theoretical one.
- `replaceBucket` = `accountSetsLock.write { … mutate(…) … }` → **recursive `pthread_rwlock_wrlock`
  on the same thread = deadlock/UB.** This one hangs the launch thread *inside*
  `AppContainer._buildCachedAppContainer()`'s `_cachedLock` (see the loader's own comment at
  `:303-307` explaining why that lock already cost every signed-in user a launch crash). Same trap,
  one layer down.
- **Correct:** `replaceBucket` is a *peer* of `mutate`, implemented directly as a single
  `accountSetsLock.write { read current → decide → apply → rebuild index }` critical section —
  never composed from `performRead` + `mutate`, never nested inside another `write`.

The contract says only "`mutate` semantics unchanged; the new `replaceBucket` sits alongside it."
**Write the one-critical-section requirement into the contract**, and add it to the store's
file-header `@unchecked Sendable` invariant block (which enumerates exactly this kind of rule).

**B-2 (BLOCKER) — a refusal must never leave the bucket EMPTY, and INV-2 as stated does not say so.**
You asked precisely the right question. Trace the naive reading ("incoming is partial ⇒ refuse"):

1. Launch: `accountSets[hash]` is empty (fresh process). Preload reads a partial disk cache →
   **refused** → bucket stays empty → `currentAccount` nil at launch, which is the bug being fixed,
   relocated to the preload path.
2. `init`'s background `loadCatalogs`: bucket empty ⇒ path 1 skipped; `hasFreshCatalogData` true
   (cache is <24h) ⇒ **path 2** (`:477-489`) → `loadAccountSetsAndAuthDoc` on the same partial bytes
   → refused again → still empty.
3. `loadAccountSetsAndAuthDoc`'s `group.notify` fires `completionBox.handler(**true**)` (`:782`)
   regardless — so `callAndClearLoadingHandlers(hash, true)` reports **success over an empty
   bucket**. A silent false-green, exactly the shape the harness canon warns about.
4. Recovery requires `refreshInBackground` to land a complete feed. Offline ⇒ the bucket stays
   empty for the whole session *and* every launch for the next 24h until the cache expires.

INV-2 must therefore be stated as a **3-cell table over the resident bucket's provenance**, not a
one-liner:

| resident bucket | incoming | verdict |
|---|---|---|
| absent / empty | partial | **ACCEPT** (short beats empty) |
| partial | partial | **ACCEPT** (and merge, don't truncate) |
| complete | partial | **REFUSE** + `Log.error` — this is the only cell INV-2 exists for |
| any | complete | ACCEPT |

Add the corresponding tests (your §7.4 covers only two of the four cells today).

**B-3 (BLOCKER, and the one with named casualties) — "derived from a complete feed" has no home, and the byte predicate is nil-ambiguous.**

`replaceBucket(hash:accounts:isCompleteFeed:)` takes completeness as an *input*, but INV-2 is
phrased as a *byte predicate* (`catalogs.count < metadata.numberOfItems`). Those are two different
sources of truth for one bit, and the contract never says (i) where the resident bucket's
completeness is remembered, or (ii) what `numberOfItems == nil` means. Both matter enormously:

- **The store has nowhere to remember it.** `replaceBucket` needs a per-hash `[String: Bool]`
  completeness map, written **inside the same critical section** as the bucket (same
  never-desync rule the header already imposes on `accountByUUID`). State it, and state its
  behaviour on `clearCache()` (which today clears files only — `AccountsManager.swift:786-792` —
  leaving buckets *and* this new map resident) and on a hash switch.
- **`numberOfItems == nil` MUST mean COMPLETE.** Evidence, measured:

      $ python3 … PalaceTests/OPDS2CatalogsFeed.json
      catalogs: 171
      metadata: {'adobe_vendor_id': 'NYPL', 'title': 'Libraries'}     ← no numberOfItems

  That fixture is the canonical accounts feed, loaded by `AccountsManagerCacheReadTests.swift:64`
  and driven through `loadAccountSetsAndAuthDoc` / `preloadAccountsFromDiskCacheSync` by
  **`AccountsManagerCacheReadTests`, `AccountsManagerStateMachineWiringTests`,
  `AccountsManagerLaunchSnapshotTests`** — three of the six suites your own Acceptance section
  requires green. Under "nil ⇒ partial" every one of those bucket writes is refused into an empty
  bucket and the suites fail wholesale. **These are the existing tests rev 1 asked for and I could
  not name; here they are.**

  Two further nil producers make this a production rule, not just a test rule:
  (1) **Every already-shipped on-disk cache.** `serializeAsCatalogsFeed` drops `numberOfItems`
  today, so after this build installs, *every existing user's* `accounts_catalog_<hash>.json`
  decodes with nil. "nil ⇒ partial" ⇒ refused preload ⇒ empty bucket on the first launch after
  upgrade, for everyone. A migration cliff that ships to 100% of installs.
  (2) **The direct-GET recovery path.** `fallbackFetchFromNetwork` (`:589-615`) GETs
  `TPPConfiguration.prodUrl` = `https://registry.palaceproject.io/libraries` — the
  **non-crawlable** endpoint, whose feed does not carry `numberOfItems` (the field's own doc-comment
  says "from crawlable endpoint"). That path returns the *complete* registry and is the offline/
  crawler-failure recovery. "nil ⇒ partial" would refuse the recovery.

  So: **nil ⇒ complete (unknown-but-assume-complete)**, and partialness is asserted by the *writer*
  via `isCompleteFeed:` — the byte predicate is how a *writer computes its own argument*, not how
  the store decides. Reconcile the two statements in §"INV-2" so there is one source of truth.

**B-4 (warning) — do NOT route `storeSlim` through `replaceBucket`.** `hydrateSlimLaunchSnapshot`
(`:290`) deliberately writes the *separate* slim map; the store header states the slim set "MUST
NOT flip `currentBucketIsLoaded` — a truncated-picker bug". A 1–2 account slim set is partial by
construction and would be refused (or, worse, accepted into the bucket). Add an explicit
"`storeSlim` is out of scope for INV-2" line so an implementer doesn't "finish the job".

---

## The rest

### §6 criteria — **re-ran all twelve against `ea61dd998`; every observation matches**

C1 `0` · C2 `1` · C3 `0` · C4 `0` · C5 `0` · C6 `0` · C7 `1` · C8 `1` · C9 `1` · C10 `0` · C11 `0` · C12 `0`.
The three rev-1 defects are gone and the replacements are genuinely red. Two residuals:

- **R-1 (warning) — C7/C8 over-constrain the implementation.** Requiring
  `grep -c "guard let account = accountsManager.currentAccount else"` **== 0** mandates that the
  `guard` be *deleted*. A perfectly correct fix keeps it and changes the else-arm:

      guard let account = accountsManager.currentAccount else {
          return storedCredentialFallbackForCurrentAccountId()
      }

  …and C7/C8 then fail a correct fix. That is the mirror image of rev 1's defect — less dangerous
  (it fails loud) but still a criterion measuring shape instead of behaviour. Anchor on the arm's
  *outcome* instead (e.g. `grep -c "return false" ` in that arm is 0, or count `hasCredentials`
  in `AudiobookSessionManager` rising from 8), and let §7.7/§7.8 be the real gate.
- **R-2 (nit) — C5 counts lines, not occurrences.** `grep -c` is line-based; the 4 `Metadata(`
  sites are at `:277` and `:330` (multi-line) and `:367`, `:412` (single-line), so ≥4 is reachable —
  but if two labelled args ever share a line the count undercounts. Use `grep -o … | wc -l`.

### F-3 mitigation — **your choice is right, and better than my suggestion**

`requireFullCrawlOnNextRun()` over "merge only into network-origin bytes": agreed, and your reason
is the correct one — the case we actually have IS bundled bytes, so my variant would have left the
truncation unfixed. Accepting my suggestion uncritically would have been the wrong call. Two
follow-ups:
- Clearing `lastSuccessfulCrawlDate` **and** `lastFullCrawlDate` makes `CrawlState.needsFullCrawl`
  return true at its first branch (`CrawlState.swift:52-54`). Correct. Also confirm
  `orderModifiedFacetURL` is *preserved* — `crawlFirstPage` (`:324-327`) just saved it, and a full
  crawl still wants it for the next incremental.
- Ordering: `requireFullCrawlOnNextRun()` must run **after** `crawlFirstPage`'s `saveCrawlState`
  (`:327`) or the save clobbers the clear. The contract says "the loader calls it on every
  provisional write" — the provisional write is at `:543`, after `:327`. Ordering holds; say so.

### `crawlerFetcher` seam — **W-1 (warning)**

`var crawlerFetcher: CrawlerNetworkFetching = URLSessionCrawlerFetcher()` follows the
`snapshotResourceResolver` precedent, which does compile (it is read inside the `@Sendable` closure
at `:504`). But `CrawlerNetworkFetching` is explicitly **not** `Sendable` — the crawler file says so
and already boxes it via `CrawlerFetcherBox` to cross into task-group children. The loader's
file-header `@unchecked Sendable` invariant block (`:24-31`) enumerates *every* mutable member and
its synchronisation, and lists neither `snapshotResourceResolver` nor a future `crawlerFetcher`.
**Extend that block** with the justification you are actually relying on — "written only from tests
before any crawl is spawned; production never mutates it" — the same shape `LibraryRegistryCrawler`
uses for its `weak var delegate`. Otherwise the next Swift-6 pass has no recorded reason to believe it.

### §4 / §5 / §7 / §8 — accepted

- Commit split B-then-A, with the sibling-sweep statement in B's body: correct.
- Rename dropped, doc-comment widening kept: correct. The partial write passing `isBundled: true`
  with an inline comment is the right minimal call.
- Shrink vector 2's post-condition ("`allPublications.count >= numberOfItems`, else serialize as
  partial and do not stamp `lastFullCrawlDate`"): correct, and §7.5 tests it.
- Ledger rows 1, 2, 3, 5, 6: sound. Row 6's page-7/page-9 detail is the right closer.
- §5 prose corrections (discarded `Bool`, the banner cost, path-2, missing-metadata): all verified
  against source; all now accurate.

### One thing rev 2 still does not specify — **W-2 (concern)**

**What `numberOfItems` does `mergePartialPage` emit?** The merged bytes are `bundled ∪ page1`
(1142 catalogs). If it carries page 1's `1457`, the merged feed self-reports PARTIAL — correct and
desirable, and it is what makes the later complete crawl able to replace it under INV-2. If it
carries the bundle's `1142`, the merged feed self-reports COMPLETE and the fix's own output claims
a completeness it does not have. **State it: the merged feed inherits the network page's
`numberOfItems`.** This single line is what ties INV-2, the provisional write, and
`requireFullCrawlOnNextRun` into one consistent story; without it an implementer will pick by coin
flip and §7.1's table will not catch it (it tests catalogs, not metadata). Add a `mergePartialPage`
cell asserting the emitted `numberOfItems`.

---

## To clear the block

1. **B-3** — declare `numberOfItems == nil ⇒ COMPLETE`, name the three nil producers (the 171-account
   fixture, every shipped on-disk cache, the `/libraries` direct-GET recovery), and say where the
   resident bucket's completeness bit lives + its `clearCache`/hash-switch semantics. *(blocker)*
2. **B-2** — replace the INV-2 one-liner with the 4-cell table; add the absent-bucket and
   partial→partial cells to §7.4; add a test that a refusal never yields an empty bucket **and**
   never reports `success: true` over one. *(blocker)*
3. **B-1** — require `replaceBucket` to be a single `accountSetsLock.write` critical section, a peer
   of `mutate`, never composed from `performRead` + `mutate` and never nested. Record it in the
   store's header invariant block. *(blocker)*
4. **(a)** — re-argue ledger row 4 on the bundle-commits-under-the-active-hash grounds; note the
   custom-registry residual. *(concern)*
5. **W-2** — state the merged feed's `numberOfItems` + add the §7.1 cell. *(concern)*
6. **R-1** — re-anchor C7/C8 on outcome rather than on deleting the `guard`. *(warning)*
7. **B-4 / W-1** — exclude `storeSlim` from INV-2 explicitly; extend the loader's `@unchecked
   Sendable` invariant block to cover `crawlerFetcher` (and, while there, `snapshotResourceResolver`). *(warning)*

Items 1–3 are one paragraph and one table between them. Nothing here requires re-opening the
diagnosis — the causal chain, the ledger, the shrink-vector census, and the criteria are settled
and I re-verified each. Re-request and I will re-run C1–C12 plus the INV-2 cell table before approving.
