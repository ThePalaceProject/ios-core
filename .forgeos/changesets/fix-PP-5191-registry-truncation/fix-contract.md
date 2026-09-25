# Fix-contract — PP-5191 (rev 2, after architect BLOCK)

Rev 1 blocked on: 3 of 8 criteria green-before-the-work, a magic-ratio invariant where a
provenance predicate already exists, 1 of 3 shrink sites covered, an unnamed staleness
regression, and an out-of-scope rename. All addressed below; changes marked **[rev2]**.

---

## 1. Hypothesis ledger — why the cause is the one named, and not the five rivals

Fact to explain: two 3.2.4 problem reports render the UUID branch of
`ProblemReportEmail.libraryFieldValue(name:uuid:)`, which in shipped 3.2.4 is fed
`(name: currentAccount?.name, uuid: currentAccountId)`. That branch is reachable **only** when
`currentAccountId != nil` **and** `currentAccount == nil` — i.e. `AccountRegistryStore.account(uuid)`
returned nil for the patron's selected library.

    HelpSpot 19030 → urn:uuid:8aff215f-… Cortland Community Library
    HelpSpot 19012 → urn:uuid:b3a28b6d-… Catoosa County Library

| # | Rival cause | Discriminating evidence | Verdict |
|---|-------------|-------------------------|---------|
| 1 | Registry never loaded this session (offline cold launch) | **[rev2, F-1]** Both UUIDs are in `bundled_registry.json` verbatim, and `loadCatalogs` path 3 writes + commits the 1142-account bundle **before** any network call (`:507` → `:735`, synchronous `registryStore.mutate`, then `:515`). A never-loaded registry cannot have named them either; a loaded one must have had them. | **RULED OUT** |
| 2 | Library deregistered from the production registry | `GET registry.palaceproject.io/libraries` (2026-09-21) returns both UUIDs; Cortland `modified 2025-12-03`. | **RULED OUT** |
| 3 | Filtered out by `availability` facet | Both found via `crawlable?...&availability=production` — the exact facet the app crawls. | **RULED OUT** |
| 4 | Bucket keyed under a different hash (prod↔beta / custom URL) | **[rev3]** Path 3 commits the bundled 1142 under *whichever* hash is active (`:456-463` → `:507` → `:735`), so the active hash always receives the full bundle before any network write. The hash cannot be the discriminator. (Rev 2 argued this from `buildAccountIndex` flattening `sets.values`; that fact is true but proves only that a uuid loaded under *any* hash resolves — it is silent on a bucket whose feed never contained the library. Non-sequitur, withdrawn.) | **RULED OUT** |
| 5 | Corrupt/garbage `currentAccountId` in UserDefaults | The UUID resolves to a real, currently-listed library. | **RULED OUT** |
| 6 | **A whole-bucket replacement overwrote a committed registry with a partial feed** | Only writer class that can *remove* an already-committed account. Both libraries sit on crawl pages 7 and 9 of 15; page 1 is the 100 most-recently-modified of 1457. | **SURVIVES** |

## 2. The mechanism

`AccountRegistryLoader.fetchFromNetwork` first-page fast path (`:542-547`):

    case .success(let firstPageData, let firstPage):
        self.registryCache.writeCatalogData(firstPageData, hash: hash)            // 100 libs → disk, isBundled:false, timestamp:now
        self.loadAccountSetsAndAuthDoc(fromCatalogData: firstPageData, key: hash) // → registryStore.mutate { $0[hash] = newAccounts }  (:735)

`loadAccountSetsAndAuthDoc` ends in a **whole-bucket replacement**, and `LibraryCatalogMerger`
is not on this path. 1142 → 100, on disk and in memory, clobbering the complete bundled
snapshot the same causal chain wrote moments earlier.

Live measurement (2026-09-21): `/libraries/crawlable` → 100 items, `numberOfItems: 1457`,
`order=modified`, 15 pages. Cortland page 7, Catoosa page 9. 93% of libraries are off page 1.

Entry condition — **[rev2]** `hasFreshCatalogData` returns `!metadata.isExpired` (24h) and is
also false when the **metadata file is missing or undecodable** (`:198-201`), independent of
age. So path 3 is entered when the cache is absent, >24h old, **or its metadata was lost**.

**[rev2] Persistence is up to 7 days, not 6 hours** (architect F-2). Rev 1 said "path 1/2 never
refreshes" — wrong: path 2 (`:477-489`) refreshes *unconditionally*; only path 1 (`:467-474`)
gates on staleness. The conclusion survives via a worse route: on cold launch
`preloadAccountsFromDiskCacheSync` fills the bucket, so `loadCatalogs` takes path 1. And when
a refresh *does* run, `refreshInBackground` feeds the truncated 100 in as
`existingPublications`; `LibraryRegistryCrawler.crawl` takes the **incremental** branch and
`LibraryCatalogMerger.merge(isFullCrawl: false)` (`:63-85`) *preserves* `existing` and adds
only recently-modified entries. The 1042 missing libraries are **not** restored until
`CrawlState.needsFullCrawl` fires — app-version change, or `lastFullCrawlDate` > 7 days old.

## 3. Why the patron is told to sign in

`currentAccount == nil` is converted into an **identity verdict** at two sibling gates, neither
of which consults the keychain, while `currentAccountId` is still set and the credentials are
still present — hence *"It shows that I am logged in."*

    Palace/Audiobooks/AudiobookSessionManager.swift:2661   guard let account = … else { return false }   ⇒ .notAuthenticated
    Palace/CarPlay/CarPlayAudiobookBridge.swift:61         guard let account = … else { return false }

PP-5135 already applied the correct treatment to the **sibling arm** of the audiobook gate
(the `awaitReady()` catch now falls back to `hasCredentials()`), and its own comment records
that the nil-account arm was seen and left failing closed.

Second symptom: `TPPSettings.settingsAccountsList` is
`settingsAccountIdsList.compactMap { accountsManager.account($0) }`, so a truncated registry
empties the Settings Libraries list — HelpSpot 19012's *"there isn't a place to relogin or even logout."*

---

## 4. Scope — **[rev2] two commits, B first** (architect §7)

### Commit B — the gates (mitigation, ~10 LOC, ships relief independent of A)

| File | Change |
|------|--------|
| `Palace/Audiobooks/AudiobookSessionManager.swift:2661` | Nil-`currentAccount` arm falls back to stored credentials for `currentAccountId`, mirroring the PP-5135 treatment of the sibling arm. |
| `Palace/CarPlay/CarPlayAudiobookBridge.swift:61` | Same. |

Use `accountsManager.currentUserAccount` (which carries the `lastKnownCurrentUserAccount`
ride-out, checklist §5) — **never** `TPPUserAccount.sharedAccount()`.
Monotonicity (architect-verified): the change can only flip `false → true`, and only for a
patron who already has stored credentials. A no-auth library already returned `true` via the
`defaultAuth` branches; a patron with no credentials still returns `false`.
**B's commit body must state the sibling sweep**: both files, both arms, audited.
**B is a mitigation, not the fix** — with B alone Settings still shows an empty library list
and the catalog is still 93% short.

### Commit A — the registry (the fix)

| File | Change |
|------|--------|
| `Palace/Accounts/Library/LibraryCatalogMerger.swift` | **[rev4]** Home of `feedIsPartial(metadata:catalogCount:)`. `serializeAsCatalogsFeed` carries `numberOfItems` through (today it is dropped, so a partial feed is indistinguishable from a complete one on disk). |
| `Palace/Accounts/Library/LibraryRegistryCrawler.swift` | **[rev5] RULE, not call-site edits: `numberOfItems` is NEVER carried forward from cache — it always comes from the response just fetched.** See the A-4 box below. Add the `crawlRemainingPages` post-condition (shrink vector 2, below). Add `requireFullCrawlOnNextRun()`. |
| `Palace/Accounts/Library/AccountRegistryStore.swift` | New `replaceBucket(hash:accounts:isCompleteFeed:)` enforcing INV-2. `mutate` semantics unchanged. |
| `Palace/Accounts/Library/AccountRegistryLoader.swift` | Pure `mergePartialPage(_:into:)` — **[rev3]** emits the NETWORK PAGE's `numberOfItems` (1457), not the bundled base's, so the merged feed stays correctly PARTIAL until a full crawl lands.  `fetchFromNetwork` overlays page 1 onto the bytes already cached for `hash` instead of writing verbatim, then calls `requireFullCrawlOnNextRun()`. Both bucket writers route through `replaceBucket`. New `var crawlerFetcher: CrawlerNetworkFetching = URLSessionCrawlerFetcher()` seam (matching the existing `snapshotResourceResolver` pattern) so the regression test can drive the real call site. |
| `docs/architecture/areas/accounts/verification-checklist.md` | **[rev2, F-8]** §1 call-site rows for the registry write sites (absent today) + a §9 refresh row. |

### **[rev2] INV-2 — provenance, not a ratio** (architect F-5)

Rev 1 proposed "refuse a replacement less than half the bucket size". Dropped: it has no stated
constants, and a legitimate registry-side availability change that halves the feed is a real
>50% shrink it would silently refuse. The precise predicate already exists in the model and in
the data — `OPDS2CatalogsFeed.Metadata.numberOfItems` is `Codable`, and `bundled_registry.json`
already carries `"numberOfItems": 1142` beside its 1142 catalogs.

> **INV-2.** A feed is PARTIAL iff `metadata.numberOfItems != nil && catalogs.count < numberOfItems`.
> **`numberOfItems == nil` means COMPLETE** — unknown provenance is trusted, so the invariant can
> only ever refuse a write we positively know is short. A PARTIAL feed may not replace a bucket
> derived from a COMPLETE feed.

**[rev3] Why nil must mean complete** (architect B-3, independently verified). The canonical
Accounts fixture carries no such field:

    PalaceTests/OPDS2CatalogsFeed.json → catalogs: 171, metadata: {adobe_vendor_id: NYPL, title: Libraries}

It backs `AccountsManagerCacheReadTests`, `…LaunchSnapshotTests`, `…StateMachineWiringTests`,
`…CacheTests`, `…Tests` — five suites, three of them named in Acceptance. Worse, because
`serializeAsCatalogsFeed` drops the field today, **every already-shipped on-disk cache decodes
`nil`**, and `fallbackFetchFromNetwork` GETs the non-crawlable `/libraries`, which never carries
it — that is the recovery path. Under "nil ⇒ partial" the first launch after upgrade would refuse
its own cache and come up with an empty registry for 100% of installs.

**[rev4] Single DEFINITION, parameter as transport.** Rev 3 over-corrected and contradicted
itself (removing `isCompleteFeed:` in one place while requiring its value in another).
`replaceBucket` receives `[Account]`, **not bytes**, so it cannot derive completeness — it needs
the parameter. Rev 2's actual defect was two independent *definitions*, not a parameter. So:
one definition, `LibraryCatalogMerger.feedIsPartial(metadata:catalogCount:)`, called by both
bucket writers on the bytes they are about to commit and passed down as `isCompleteFeed:`.

**[rev4] It lives in `LibraryCatalogMerger`, not the loader** (architect b). `AccountRegistryStore`
is *below* `AccountRegistryLoader`; defining the store's invariant inside its own consumer inverts
that dependency edge, and both types are headed into `PalaceAccounts`. The merger is already the
pure-statics namespace over exactly this data, is already being edited to carry `numberOfItems`,
and already has a test target — putting the *producer* and the *interpreter* of that field in one
file is what makes A-1's arithmetic reviewable in a single diff. Not `PalaceCatalog`: completeness
is a registry concept, not an OPDS2 one.

Zero false positives on deletion reconciliation (a full crawl reports `numberOfItems == count`),
durable across process restart, a pure function of the bytes, and mutation-testable.

### **[rev2] All three shrink sites** (architect F-4)

1. `fetchFromNetwork` page-1 verbatim write — fixed by `mergePartialPage` + INV-2.
2. `crawlRemainingPages` short parallel crawl (`LibraryRegistryCrawler.swift:381-388`): offsets
   derive from `numberOfItems`; if the server under-reports it, too few offsets are computed,
   nothing throws, and `:406-410` writes the short set with `isFullCrawl: true` and sets
   `lastFullCrawlDate`. Fix: post-condition `allPublications.count >= numberOfItems`, else
   serialize as partial and do not stamp `lastFullCrawlDate`.
3. `hydrateFullAccountSets` (`:326`) — a second unguarded whole-bucket replacement reached from
   `preloadAccountsFromDiskCacheSync`. Routed through `replaceBucket` so INV-2 is an invariant
   rather than a patch on one caller.

### **[rev6] S-1 — the disk write is unconditional, so every INV-2 refusal is undone next launch** (blocker)

Verified in source:

    :543  self.registryCache.writeCatalogData(firstPageData, hash: hash)      // disk — UNCONDITIONAL
    :544  self.loadAccountSetsAndAuthDoc(fromCatalogData: firstPageData, …)   // bucket — INV-2 applies HERE

Combined with B-7 (the resident bucket is empty on every launch's first write): session N refuses
and protects the in-memory bucket, but the short bytes are **already on disk**; session N+1 hydrates
them into an empty bucket and accepts unopposed. **INV-2 as specified is exactly one session deep.**
It defeats A-5 specifically — the nil-metadata direct-GET write still lands on disk (`:595`, `:674`).
Rev 5's "the durable guarantee is `mergePartialPage`" is true on the page-1 path ONLY; it does not
cover `:570`, `:595`, or `:674`.

**Fix:** gate the cache write on `replaceBucket` having applied — the disk and the bucket must agree
or the invariant is decorative. This also gives `replaceBucket`'s return value its consumer (**S-2**).

**[rev6, R-2] The "applied" signal MUST NOT ride the existing completion `Bool`.** That `Bool`
means *the feed parsed*, and a refusal correctly completes `true`. Folding both meanings into one
flag is a fresh instance of this changeset's own failure pattern via an overloaded value, and it is
the shortcut an implementer will reach for. `replaceBucket` returns its own distinct value.

**[rev6] S-3 — a refusal must refuse completely.** On refusal the `_setState` loop (`:737-744`), the
auth-doc drive, and the `.TPPCurrentAccountDidChange` post (`:781`) still run, leaving
`AccountStateStore` holding `.basicInfoLoaded` for uuids `account(uuid)` cannot resolve. Skip all
three for a refused write, and assert the state store afterwards.

**[rev6] Accepted, recorded, not fixed here:** S-4 `fetchFromNetwork:578 case .noChanges` is
unreachable (`crawlFirstPage` returns only `.success`/`.failure`) yet reports a successful load
having written nothing — a dead arm inside the switch being edited; S-5 `saveCrawlState` is `try?`,
so `requireFullCrawlOnNextRun()` is best-effort and its failure renders as "no full crawl needed";
S-7 vector 2's post-condition still returns `.success` under a "pagination complete" log.
**[rev6] S-6 (test defect, MUST fix):** test 3's second-launch cell would take the non-slim branch
because `refreshSlimLaunchSnapshotOffMain` is XCTest-gated at `:341` — it would pass while never
touching production's path. Drive the slim path explicitly or assert the branch taken.

### **[rev5] A-4 — the deletion-reconcile path emits a STALE `numberOfItems`** (blocker)

Verified in source. `crawl():274-280` serializes with `feedMetadata ?? OPDS2CatalogsFeed.Metadata(...)`,
and `refreshInBackground` supplies `feedMetadata` from the **cached** feed
(`AccountRegistryLoader.swift:628-632` → `existingMetadata = feed.metadata`), *not* from the response
it just fetched at `:156`. (`crawlRemainingPages` is fine — `:564` passes `firstPage.metadata`.)

Consequence on the one path that exists *specifically* to reconcile deletions: truth shrinks
1457 → 1400, the feed emits `count 1400 / numberOfItems 1457` ⇒ PARTIAL ⇒ removes uuids ⇒ not
positively complete ⇒ **REFUSED, forever.** Deletions would never reconcile — the exact opposite of
INV-2's headline claim, rendering as "there were no deletions".

Rev 4's §4 instruction ("populate `numberOfItems` at the 4 `Metadata(...)` sites") **does not fix
this**: at `:277` the `??` fallback is only reached when `feedMetadata` is nil, which on this path it
never is. An implementer following rev 4 literally ships the bug and every criterion still passes.
Hence the rule form: **`numberOfItems` is never carried forward from cache.** `crawl()` must take it
from the freshly-fetched first page, and a test must drive a genuine shrink end to end.

### **[rev4] INV-2 decision rule — information loss, not the label** (architect A-1/A-2)

Rev 3's four-cell COMPLETE/PARTIAL table **refuses the fix's own write.** Verified on real data:

    resident bundled : 1142 rows, numberOfItems 1142  -> COMPLETE
    incoming merged  : 1242 rows, numberOfItems 1457  -> PARTIAL   (all 100 page-1 rows are new)
    rev3 cell 3 (COMPLETE <- PARTIAL)                 -> REFUSE

The merged superset — the entire point of the change — would be rejected by the invariant the
change introduces; disk would hold 1242 while memory kept 1142, and the 100 freshest rows would
never reach `accountSets` that session. It self-heals next launch, so it would have shipped
**green, doing nothing**. Rev 3's `PARTIAL ← PARTIAL ⇒ ACCEPT` cell was also wrong in the
direction I asked about: `PARTIAL(1242) ← PARTIAL(100)` loses 1142 rows, reachable from both the
vector-2 short-crawl fix and `mergePartialPage`'s `existing == nil` cell (`clearCache()` sweeps
files but leaves `accountSets` resident).

> **INV-2 (rev5).** A write that **removes no uuids** the resident bucket holds is **always
> applied**. A write that **removes uuids** is applied only against **positively-asserted
> completeness** — `numberOfItems != nil && catalogs.count == numberOfItems`. Otherwise it is
> refused and the resident bucket stands.

**[rev5] Why `nil` no longer licenses a delete** (architect A-5). `nil ⇒ COMPLETE` was adopted for
three reasons — legacy on-disk caches, the 171-row `OPDS2CatalogsFeed.json` fixture, and direct-GET
recovery — and **all three are about not REFUSING a write, none about licensing a DELETE.** Rev 4
collapsed both into one word. The reachable vector is `fallbackFetchFromNetwork` /
`fallbackDirectRefresh`, which GET the non-crawlable `/libraries`. Measured 2026-09-21:

    GET registry.palaceproject.io/libraries -> 1457 catalogs, metadata {title, adobe_vendor_id}
    numberOfItems: ABSENT

So that response would be COMPLETE by fiat and whatever it contained would become the registry —
on the path that runs precisely when the network is already misbehaving, and which writes
`isBundled: false` (`:595`, `:674`), clearing the provisional marker as well (**B-9**, accepted and
recorded, not fixed here). Splitting the two uses changes no cell of the table below; only
"nil-metadata may delete" moves. **Implementation obligation:** re-census the test drivers of
`loadAccountSetsAndAuthDoc` for any that replace a resident bucket with a SMALLER nil-metadata
feed before relying on this delta.

**No floor.** A size floor is the magic ratio killed in rev 1. "The server told us the truth and
the truth changed" stays out of scope — *with the rule above applied*. Make it observable instead:
`Log.error` with both operand counts on any APPLIED complete write that removes a notable share.
Log only, never refuse; a wrong constant in a log line costs nothing.

Checked against all five reachable cases:

| resident | incoming | removes? | complete? | action |
|---|---|---|---|---|
| absent / empty | anything | no | — | **ACCEPT** |
| bundled 1142 | merged 1242 (superset) | no | no | **ACCEPT** ← fixes A-1 |
| merged 1242 | bare page-1 100 | yes | no | **REFUSE** ← fixes A-2 |
| bundled 1142 | bare page-1 100 | yes | no | **REFUSE** |
| anything | full crawl 1457 | maybe | yes | **ACCEPT** (real deletions) |

This **removes state**: no `bucketIsPartial` map, so no `clearCache` / hash-switch semantics to
define. Cost is one `Set<String>` build plus ~1457 lookups inside a critical section that already
runs `buildAccountIndex` over every bucket — same order, same lock, negligible at launch.
`count >=` is explicitly **not** an acceptable proxy: it is wrong under churn (equal counts can
still drop uuids). `storeSlim` remains excluded — it writes a separate map. **[rev5, B-8]** The resident read MUST be
`accountSets[hash]`, **not** `accountByUUID` — the latter flattens every bucket and will be sitting
in the same critical section, so reading it would compare against other hashes' libraries.

**[rev5, B-7] INV-2 cannot fire on the first write of any launch.** The resident bucket is empty at
that point (the slim path does not populate `accountSets`), so cell 1 accepts unconditionally. INV-2
guards **in-session transitions only**; the durable, across-launch guarantee is `mergePartialPage`
writing a superset to disk. Stated here so the invariant is not mistaken for the whole fix.

`replaceBucket` returns whether it applied. On refusal the caller still completes `true`: the
registry IS loaded, with strictly better data than the incoming write. A test pins that a refusal
leaves the bucket non-empty AND completes `true`, so "refused" can never masquerade as "empty".

### **[rev3] Lock composition — `replaceBucket` is a PEER of `mutate`, never a caller** (architect B-1)

`ReadWriteLock` is a bare non-recursive `pthread_rwlock`. Two shapes are forbidden:

- `performRead { … }` then `mutate { … }` — TOCTOU between the launch thread and an owned crawl task.
- `accountSetsLock.write { … mutate() … }` — recursive `wrlock`, **deadlock on the launch thread
  inside `_cachedLock`**, the same trap that already cost every signed-in user a launch crash
  (`AccountRegistryLoader.swift:303-307`).

`replaceBucket` takes **one** `accountSetsLock.write` and, inside that single critical section,
reads the resident bucket + its completeness, applies the table, mutates `accountSets`, rebuilds
`accountByUUID`, and applies the rev4 removal rule. **[rev4]** No completeness map — the rule reads the resident bucket itself. No added decode
at launch — `hydrateFullAccountSets:322` already decodes; `numberOfItems` rides along for free.

### **[rev2] F-3 mitigation — the merge must not make bundled entries sticky**

After `mergePartialPage` the cache is `bundled ∪ page1`, and per §2 an incremental refresh
*preserves* it — promoting build-time bundled rows (libraries since deleted, catalog URLs since
changed) into the live cache for up to 7 days. Today they are clobbered within ~260ms, so this
is a NEW vector introduced by the fix. Mitigation: `LibraryRegistryCrawler.requireFullCrawlOnNextRun()`
clears `lastSuccessfulCrawlDate` / `lastFullCrawlDate` in `crawl_state_<hash>.json`; the loader
calls it on every provisional write, so the next `crawl()` takes the full branch.

### **[rev2] Rename DROPPED** (architect §4)

`isBundled` → `isProvisional` is cut from this changeset. It moves a **protocol label** on
`AccountRegistryCaching` — a package-surface break destined for the `PalaceAccounts` move — and
churns ~22 test sites in `CatalogCacheMetadataTests`, the suite Acceptance gates on, making a
rename failure and a fix failure indistinguishable in one run. **Kept:** widening the flag's doc
comment to name both origins (bundled snapshot, partial crawl page). The partial-page write
passes `isBundled: true` with an inline comment explaining the second origin.

## 5. Scope (out)

- `Palace/Holds/HoldsViewModel.swift:112` — DEFERRED. Architect re-traced: `currentAccount?.needsAuth ?? true`
  feeds only `:252`, where `anonymous` collapses to `!hasCredentials()` — for a credentialed
  patron, `false`. `refresh():332` (the only `presentSignIn` caller) is keychain-backed.
  **What the nil does cost:** a sync error banner that would otherwise be suppressed. Not a prompt.
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift:870` — off-limits. **[rev2]** Rev 1's reason
  was wrong: the `ensureAuthenticationDocumentIsLoaded` completion `Bool` is *discarded*
  (`{ [weak self] (_: Bool) in`). Correct reason: the prompt decision at `:879-893` reads
  `currentUserAccount` (keychain), which resolves via `userAccount(for: currentAccountId)`
  regardless of `currentAccount`.
- `TPPBookRegistryAsync.swift:51`, `OPDSFeedService.swift:354`, `UnifiedOPDSService.swift:358`,
  `TPPReaderBookmarksBusinessLogic.swift:125,217`, `LCPPassphraseAuthenticationService.swift:61`
  — NOT in class: they degrade a *feature*, they do not assert an identity. Fail-closed is correct.
- `ProblemReportEmail` / `AccountsManager+ProblemReportContext` — the PP-5078 diagnostic is
  working as designed and produced the evidence. Do not touch.
- `LibraryRegistryCrawler.crawl()` (refreshInBackground path) — already merges. Off-limits.
- `AccountRegistryStore.mutate` — semantics unchanged; the new `replaceBucket` sits alongside it.

---

## 6. Verification criteria — **[rev2] every one demonstrated RED on `origin/develop`**

Run 2026-09-21 against `ea61dd998` (no code written):

| # | Criterion | Target | Observed on develop | Red? |
|---|-----------|--------|---------------------|------|
| C1 | `grep -c mergePartialPage …/AccountRegistryLoader.swift` | ≥2 | `0` | ✅ |
| C2 | `grep -c "writeCatalogData(firstPageData" …/AccountRegistryLoader.swift` | ==0 | `1` | ✅ |
| C3 | `grep -rl mergePartialPage PalaceTests/ \| wc -l` | ≥1 | `0` | ✅ |
| C4 | `grep -c numberOfItems …/LibraryCatalogMerger.swift` | ≥1 | `0` | ✅ |
| C5 | `grep -c "numberOfItems:" …/LibraryRegistryCrawler.swift` (labeled-arg carry-through) | ≥4 | `0` | ✅ |
| C6 | `grep -c INV-2 …/AccountRegistryStore.swift` | ≥1 | `0` | ✅ |
| C13 | **[rev4]** `grep -c feedIsPartial …/LibraryCatalogMerger.swift` | ≥2 | `0` | ✅ |
| C7 | **[rev4]** `grep -A2 "guard let account = accountsManager.currentAccount else" …/AudiobookSessionManager.swift \| grep -c "return false"` | ==0 | `1` | ✅ |
| C8 | **[rev4]** `grep -A2 "guard let account = accountsManager.currentAccount else" …/CarPlayAudiobookBridge.swift \| grep -c "return false"` | ==0 | `1` | ✅ |
| C9 | `grep -c hasCredentials …/CarPlayAudiobookBridge.swift` | ≥2 | `1` | ✅ |
| C10 | `grep -c crawlerFetcher …/AccountRegistryLoader.swift` | ≥2 | `0` | ✅ |
| C11 | `grep -c requireFullCrawlOnNextRun …/LibraryRegistryCrawler.swift` | ≥2 | `0` | ✅ |
| C12 | `grep -c replaceBucket …/AccountRegistryLoader.swift` | ≥2 | `0` | ✅ |

**[rev4]** C7/C8 re-anchored twice: rev 2 demanded the `guard` line be GONE (fails a fix that keeps the guard and changes its arm); rev 3's `hasCredentials` form fails a fix that EXTRACTS the arm into a helper — the shape PP-5135 itself used. They now assert the arm no longer returns a bare `false`. C14 was deleted with `bucketIsPartial` under the rev4 rule. Rev 1's C4/C6/C7 are **deleted**: `grep -n "case isBundled"` was unsatisfiable in both
directions (the line reads `case timestamp, hash, isBundled`), and the two `hasCredentials`
counts were already green on develop — *a gate that cannot fail reports a pass*.

**Review instruction (not a criterion):** every new `await` / `try await` added in production
must be driven by a named test through the public entry point.

## 7. Tests required

1. `mergePartialPage` table — page ⊂ existing; page ⊄ existing; existing nil; page updates an
   existing entry (newer wins); malformed bytes ⇒ nil.
2. **The regression.** Seed the cache with a complete 3-library feed (`numberOfItems: 3`)
   including the current account; drive `fetchFromNetwork` via the `crawlerFetcher` seam with a
   1-library page-1 that EXCLUDES it. **[rev2, F-7]** Assert all three: `account(currentAccountId) != nil`,
   `accounts(hash).count == 3`, **and** a *non-current* seeded library still resolves.
   Must FAIL on `origin/develop`.
3. **[rev2, F-7]** F-2 cell: after a truncating first-page write, a subsequent *incremental*
   refresh must not leave the bucket short. **[rev5, B-7]** Add a SECOND-LAUNCH cell: resident
   hydrated from the merged 1242 on disk, not the bundled 1142, so the in-session transition is
   actually exercised. **[rev6, S-6]** The cell MUST seed the slim snapshot explicitly or assert
   which branch ran: `refreshSlimLaunchSnapshotOffMain` is XCTest-gated at `:341`, so a test that
   does neither takes the non-slim branch and passes without touching production's path.
4. INV-2 table: partial-may-not-replace-complete; complete-may-replace-complete;
   complete-may-replace-partial; deletion reconcile (`numberOfItems == count`, N → N−3) IS applied.
5. Shrink vector 2: `crawlRemainingPages` with an under-reported `numberOfItems` does not stamp
   `lastFullCrawlDate`.
6. `requireFullCrawlOnNextRun` ⇒ next `crawl()` takes the full branch (drive via `stateDirectory`).
7. Audiobook gate: `currentAccount == nil` + stored credentials ⇒ `true`; no credentials ⇒ `false`.
8. CarPlay gate: same two cells.
9. **[rev3]** `feedIsPartial` table, including `numberOfItems == nil ⇒ COMPLETE`, and a decode of
   `PalaceTests/OPDS2CatalogsFeed.json` (171 catalogs, no `numberOfItems`) asserting COMPLETE.
10. **[rev3]** INV-2 four-cell table including the empty-resident cell, plus: a REFUSED write leaves
    the bucket non-empty AND still completes `true`.
11. **[rev3]** Legacy-cache upgrade: bytes with no `numberOfItems` hydrate the bucket normally at
    launch (guards the 100%-of-installs regression this rev averted).
12. **[rev3]** `requireFullCrawlOnNextRun()` preserves `orderModifiedFacetURL` while clearing the
    completed-crawl markers.
13. **[rev5, A-4]** Deletion reconcile end to end: a genuine registry shrink (1457 → 1400) via
    `refreshInBackground` IS applied. Must fail if `numberOfItems` is carried forward from cache.
14. **[rev5, A-5]** A nil-`numberOfItems` feed that REMOVES uuids is refused; the same feed as a
    superset is applied.
15. **[rev5, B-6]** `requireFullCrawlOnNextRun()` is NOT called when the merged feed is complete.
16. **[rev6, S-1/S-2 — WITHDRAWN at implementation]** ~~A REFUSED write leaves the on-disk cache
    byte-identical~~. **Not satisfiable: INV-2 cannot refuse at the first-page call site.**
    Reaching `fetchFromNetwork` requires an empty bucket (`loadCatalogs` returns at path 1,
    `AccountRegistryLoader.swift:486`, when the bucket is non-empty), an empty resident set is
    INV-2's always-accept cell, and a bundled snapshot landing mid-run yields only a SUPERSET —
    also accepted. Two attempts at this test both passed with the gate deleted: the first because
    bundle-3 + page-1 merges to a superset, the second because seeding the bucket sent
    `loadCatalogs` down path 1 and nothing executed. The gate is retained as defence in depth and
    documented as unreachable in `RegistryTruncationRegressionTests`; what IS reachable — the
    `didApplyBucketWrite(false)` signal the gate consumes — is pinned by test 17.
17. **[rev6, S-3]** After a refusal, `AccountStateStore` holds no new state for the uuids that never
    entered the bucket, and no `.TPPCurrentAccountDidChange` was posted.

## 8. Acceptance

- All C1-C13 pass; each was RED on `origin/develop` per §6.
- **[rev6, R-1] Red-was-possible set:** tests 2, 7, 8, 13, 14, 16 and 17 must fail on
  `origin/develop` and pass here. Tests 13-17 name symbols absent at the base ref
  (`feedIsPartial`, `replaceBucket`, `requireFullCrawlOnNextRun`) and so cannot even run there —
  record that as the reason rather than a pass.
- Mutation ≥80% diff-only on `AccountRegistryLoader.swift`, `AccountRegistryStore.swift`,
  `LibraryCatalogMerger.swift`.
- `AccountsManagerStateMachineWiringTests`, `AccountsManagerCacheTests`,
  `AccountsManagerCacheReadTests`, `AccountsManagerLaunchSnapshotTests`,
  `CatalogCacheMetadataTests`, `CrawlerFallbackTests`, `LibraryCatalogMergerTests` green **in
  isolation** (checklist §7 flake) and in the full suite.
- `scripts/verify-pr.sh --quick --diff-baseline` PASS.
- Accounts verification-checklist §1 + §9 updated.


---

## 9. **[rev4]** Release plan

Global build sequence high-water is **508** on `origin/release/3.3.0` (`MARKETING_VERSION = 3.3.0`);
`origin/develop` is on the 3.4.0 line at 498. Build numbers are ONE sequence across branches.

**[rev4] Release-first, then forward-port** — rev 3 had this backwards. This repo's own pattern,
verified: `fix/PP-2677-sideload-toggle-3.3.0` (cd3916213, build 506) merged as PR #1490, *then*
`fix/PP-2677-sideload-toggle-develop-port` (79bb81313) as PR #1491. Release-first also means the
deadline branch gets the real implementation rather than a re-typed one.

1. **`fix/PP-5191-registry-truncation-3.3.0` → `release/3.3.0`** — commits B then A, plus
   `CURRENT_PROJECT_VERSION` 508 → **509**. Without the bump the merge uploads nothing to TestFlight.
2. **`fix/PP-5191-registry-truncation-develop-port` → `develop`** — same two commits, **no build
   bump** (develop is on the 3.4.0 line; bumping presumes it ships alone).
3. **Merge mode: `gh pr merge <n> --merge`, never `--squash`**, for anything that feeds `main`.
   Squash on a release-bound branch is the 296-conflict lever (PR #998 / 3.1.0).
4. Jira Fix Version **iOS 3.3.0**.

**[rev4] Sequence hazard to record, not to fix here** (architect C-3). Develop is not merely
behind — **every number between it and the high-water is already spent**, by the 3.3.0 line and
the 3.2.4 hotfix:

    499  3.3.0 RC          500  3.2.4 hotfix      502  3.3.0 RC
    503  PP-5128           504  PP-5134           505  PP-4531
    506  PP-2677           507  flag precedence   508  LCP player bar

So the next 3.4.0 build cut from develop, if taken as 498+1, mints **499** — which is the 3.3.0
RC's build. That is the 3.2.4-reused-493 failure shape. It is **pre-existing and not introduced
by this changeset**, and not bumping develop here is still correct; but the release plan names it so
it is owned rather than rediscovered. Owner: whoever cuts the next 3.4.0 build should set
`CURRENT_PROJECT_VERSION` above the global high-water, not above develop's own last value.
