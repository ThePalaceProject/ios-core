# Blast-radius review — PP-5191 registry truncation + missing-registry-row auth gate

- **Branch:** `fix/PP-5191-registry-truncation-3.3.0`
- **Base:** `origin/release/3.3.0` (ships as build 509 — a regression here reaches patrons)
- **Worktree:** `/Users/mauricework/PalaceProject/wt-5191-330`
- **Head:** `35882839c` (3 commits: `555ba957f` auth gates, `615952ed4` registry, `35882839c` build bump)
- **Reviewer scope:** blast radius only. Architect (6 rounds) and QA reviewed separately.
- **Date:** 2026-09-21

## VERDICT: **APPROVED**

Six warnings, no blockers. Every gap I found is a *pre-existing* behaviour that this
change does not make worse on any path; the change is monotone-improving on the paths
it touches; the rollback story is clean and verified. The warnings are real and should
be carried forward to 3.4.0 on `develop`, not patched onto a release branch where an
amend would invalidate six architect rounds.

### Evidence run (diff-fed, not vacuous)

| script | exit | note |
|---|---|---|
| `check-blast-radius.py --diff` | 0 | 0 findings over a 3,427-line diff |
| `check-superpartner-spectrum.py --diff` | 0 | 5 new items, 5 have a test, 0 missing |
| `check-adjacency-staleness.py --diff` | 0 | no removed declarations |
| `check-contract-reconciliation.py --diff --commit-msg --swarm-contract` | **1** | 4 unsupported claims — **all four are parser false positives** (see F-9) |
| `check-intent-recorded.py` | 0 | — |

*Note on method:* running these five with bare `--quiet` and no `--diff` exits 0 on all
five because they read the diff from **stdin** and got an empty one. That is a gate that
cannot fail reporting a pass. Every result above was re-run against
`git diff origin/release/3.3.0...HEAD` written to a file.

---

## F-1 — PUBLIC / PACKAGE SURFACE — **PASS**

No ABI break and no new externally-visible symbol. Enumerated mechanically.

**`loadAccountSetsAndAuthDoc` gained two defaulted parameters.** It is `internal` on an
`internal` class (`AccountRegistryLoader.swift:67`, `:805`). Adding defaulted parameters is
source-compatible; no existing call site needs editing and none was edited. All nine
call sites:

```
AccountRegistryLoader.swift:499  disk-cache SWR            default isCompleteFeed: true
AccountRegistryLoader.swift:524  bundled snapshot          default
AccountRegistryLoader.swift:571  merged page-1             EXPLICIT (!displayIsPartial)
AccountRegistryLoader.swift:621  background pagination     default
AccountRegistryLoader.swift:646  fallback GET success      default
AccountRegistryLoader.swift:655  fallback cached-after-fail default
AccountRegistryLoader.swift:700  refreshInBackground       default
AccountRegistryLoader.swift:725  fallbackDirectRefresh     default
AccountsManager.swift:748        facade (internal)         default
```

**`AccountRegistryStore.replaceBucket`** (`:264`) is `internal`, `@discardableResult`-less
and both call sites handle the return (`AccountRegistryLoader.swift:342` explicitly
`_ =`, `:844` binds it). No conformer exists — `AccountRegistryStore` is a final class,
not a protocol, so nothing downstream must implement it.

**`AccountRegistryLoader.crawlerFetcher`** (`:108`) is an `internal var` on an `internal`
class. It is NOT `public`, not `#if DEBUG`-gated, and it ships. It follows the exact
precedent of `snapshotResourceResolver` (`:98`) directly above it, whose `@unchecked
Sendable` invariant is documented in the same file header, and the new property carries
the same documented invariant. Production binds a stateless struct over `URLSession.shared`.
See F-5 for the one caveat.

**`PalaceCatalog` is untouched.** `OPDS2CatalogsFeed.Metadata.numberOfItems` already
existed on `origin/release/3.3.0` as `public let numberOfItems: Int?` with a defaulted
init parameter (verified: `git show origin/release/3.3.0:Palace/Packages/PalaceCatalog/
Sources/PalaceCatalog/OPDS2CatalogsFeed.swift:16-22`). The change only starts *populating*
a field that already shipped. No package ABI change.

**New module edge:** `AccountRegistryStore.swift:55` gains `import PalaceLogging`. For the
future `PalaceAccounts` move this is already a dependency of the sibling loader, so the
package manifest edge is not new.

**Verdict on the verification-checklist §2 "contract break" test:** nothing here is a
break for an existing caller or conformer. Zero grep hits outside the `Palace` module.

**Note for the package move (not a 3.3.0 issue):** if these types become `public` in
`PalaceAccounts` with library evolution on, the two defaulted parameters on
`loadAccountSetsAndAuthDoc` and the settable `var crawlerFetcher` become resilience
surface. Re-derive `crawlerFetcher` as `internal(set)` or a `_setForTesting` seam at
move time.

## F-2 — LAUNCH PATH / LOCK RE-ENTRANCY — **PASS**

`hydrateFullAccountSets` (`AccountRegistryLoader.swift:330`) is reached synchronously from
`preloadAccountsFromDiskCacheSync` (`:271`), called from `AccountsManager.init`
(`AccountsManager.swift:420/423/447`), which is constructed inside
`_buildCachedAppContainer()` under `_cachedLock.withLock` — the exact stack that a
recursive `wrlock` crashed for every signed-in user. Traced it line by line.

**No recursive acquisition.** `replaceBucket` (`AccountRegistryStore.swift:264-281`) takes
exactly one `accountSetsLock.write`. Inside the critical section it executes only:
a dictionary subscript, `Set(box.accounts.map(\.uuid))`, `resident.filter`, one
`Log.error`, `accountSets[hash] = …`, and `buildAccountIndex`. None of those re-enter
`AccountRegistryStore`:

- `Account.uuid` is `let uuid: String` (`Account.swift:644`) — a stored property, no
  computed accessor, no lock.
- `Log.error` (`PalaceLogging/Log.swift:91` → `:45`) touches only its own
  `OSAllocatedUnfairLock`s, `os_log`, and a detached `Task` for `PersistentLogger`.
  It never reads the account registry, so it cannot re-enter the composition root.
- `buildAccountIndex` is a pure static over the dictionary — and it already ran in the
  same critical section under the `mutate` path this replaces.

**No lock-count change.** The replaced call was `registryStore.mutate { $0[hash] = accounts }`
— one `accountSetsLock.write`. `replaceBucket` is one `accountSetsLock.write`. The doc
comment at `:258-262` states the rule ("must never call `mutate` … nor pair `performRead`
with a later `mutate`") and the implementation honours it.

**No added main-thread cost at launch.** The guard body is O(n) but is skipped entirely
when `resident.isEmpty`, and on the launch hydrate path the bucket is empty by
construction (`loadCatalogs` path 1 returns early on `bucketIsNonEmpty`). The only
unconditional new work on this stack is `LibraryCatalogMerger.feedIsPartial(feed)`
(`:341`), which is a nil-check plus an `Int` compare on an already-decoded feed — O(1).

## F-3 — COLD-LAUNCH COST ON A CACHE MISS — **WARNING**

*What got slower.* On the first-page path (`AccountRegistryLoader.swift:566-569`), a
fresh install now performs, on the `.userInitiated` crawl task, work that did not exist
in 508:

```swift
let existingData = self.registryCache.readCatalogData(hash: hash)              // +2.39 MB disk read
let displayData  = Self.mergePartialPage(firstPageData, into: existingData)    // +2 decodes, +1 encode
let displayIsPartial = (try? OPDS2CatalogsFeed.fromData(displayData))          // +1 decode (redundant)
    .map { LibraryCatalogMerger.feedIsPartial($0) } ?? true
self.loadAccountSetsAndAuthDoc(fromCatalogData: displayData, …)                // decodes displayData AGAIN
```

Measured inputs: `Palace/Accounts/Library/bundled_registry.json` is **2,386,937 bytes /
1,142 catalogs / `numberOfItems: 1142`**. So the sequence is ~2.4 MB re-read off disk,
**four** full JSON decodes of ~2.4–2.6 MB feeds (`pageData`, `existingData`, `displayData`
for the partial check, `displayData` again inside `loadAccountSetsAndAuthDoc`), one
~2.6 MB encode, and **1,242 `Account` materializations instead of 100** — immediately
followed by the background pagination doing it again at 1,457.

`AccountRegistryCache.swift:190-194` documents that "the single authoritative byte read
happens exactly once per launch"; this change makes it twice. The suite's own
`AccountsManagerLaunchSnapshotTests.swift:246` budgets 15s for the 1,142-account
decode+materialize, so this is seconds of CPU, not milliseconds.

*Mitigating:* it is **off-main** (`spawnOwnedCrawlTask(priority: .userInitiated,
detached: false)`), it costs **zero extra network requests**, and it only fires on a
cache-miss launch (fresh install, or a cache older than the 24 h `maxAge` at
`AccountRegistryCache.swift:63`). Warm launch and library switch are unchanged.

**Recommendation (3.4.0, not this release):** have `mergePartialPage` return the merged
`OPDS2CatalogsFeed` alongside its `Data` so the `displayIsPartial` decode and the
`loadAccountSetsAndAuthDoc` decode collapse into one. That removes two of the four
decodes with no behavioural change. Also worth noting that this subsystem has a
documented cooperative-pool-starvation history, and this path now holds a pool worker
for materially longer.

## F-4 — CRAWL-STATE RESET FREQUENCY — **PASS** (quantified; the racy reading is wrong)

`requireFullCrawlOnNextRun()` (`LibraryRegistryCrawler.swift:606`) fires from exactly one
site: `AccountRegistryLoader.swift:589-592`, inside `didApplyBucketWrite`, guarded by
`if displayIsPartial`.

**How often, in the field:** essentially **every cache-miss launch**. The merged feed is
`bundled(1142) ∪ page1(100) ≈ 1242` against a declared 1457, so `displayIsPartial` is
true on the normal happy path. This is by design, not an edge case.

**It cannot cause repeated full crawls for a healthy patron, and I verified the ordering
rather than assuming it.** `loadAccountSetsAndAuthDoc` is fully synchronous from entry
through `replaceBucket` → `didApplyBucketWrite` (`:812-847`; the first `DispatchGroup`
hop is at `:874`, well after). So the sequence on the caller's task is deterministic:

```
requireFullCrawlOnNextRun()   clears both dates    (loader :591)
guard firstPage.nextPageURL != nil                  (loader :598)
spawnOwnedCrawlTask → crawlRemainingPages           (loader :606)
  … loadCrawlState() sees the CLEARED state
  … on success: lastSuccessfulCrawlDate + lastFullCrawlDate re-stamped (crawler :452-457)
```

There is no read-modify-write race with `crawlRemainingPages` — the clear strictly
precedes that task's `loadCrawlState`. Net effect: on a healthy network the reset is
superseded inside the same session and costs nothing; when pagination fails it survives
and the next launch does a full crawl. That is precisely the intended semantics.

**The permanently-flaky patron (the explicit ask):** page 1 succeeds, pagination fails,
state stays cleared, so every subsequent launch's `refreshInBackground` takes the FULL
branch of `crawl()` (sequential, ~15 pages, ~2.4 MB) instead of the incremental one.
**This is not new.** In 508 that same patron already had `lastFullCrawlDate == nil` —
`crawlFirstPage` (`crawler :335`) saves only `serverMaxAge` / `orderModifiedFacetURL` and
never stamps the dates, and `crawlRemainingPages` stamps `lastFullCrawlDate` only on
success. `CrawlState.needsFullCrawl` (`CrawlState.swift:57-59`) already returned true for
them. No new data or battery cost for this cohort.

One genuinely new case: a patron whose complete cache **expires** (>24 h) hits the
cache-miss path, the unconditional bundled write (`loader :523`, `isBundled: true`) has
already clobbered their good 1457-row cache with 1142, the merge yields 1242/partial, and
`requireFullCrawlOnNextRun` clears a legitimately-earned `lastFullCrawlDate`. Pagination
then re-stamps it in the same session. Cost: one extra full crawl only if that pagination
also fails — which is the correct outcome, since their cache really is 1242 now.

## F-5 — SERVER-SIDE FAILURE MODES — **WARNING** (2 of 3)

**(a) The registry stops emitting `numberOfItems` on `/libraries/crawlable`. — WARNING.**
`feedIsPartial` returns `false` for `nil` by deliberate design
(`LibraryCatalogMerger.swift:118-121`), and I agree that decision is load-bearing and
correct: reading `nil` as partial would refuse every already-shipped cache and the
direct-GET recovery endpoint, emptying the registry for 100% of installs. But the
consequence is that **a single server-side field removal silently disarms the entire
invariant** — `feedIsPartial` becomes constantly false, every write reads COMPLETE,
`replaceBucket`'s guard never fires, `requireFullCrawlOnNextRun` never fires, and the app
degrades exactly to 508 behaviour. There is **no log, no metric, and no test** that would
distinguish that state from a healthy one. This is the same failure shape as the wall
entry committed with this changeset (`guard-refusal-renders-as-success`), in its dual
form: a guard that *disarms* also renders as success.
**Recommendation:** one `Log.error` in `crawlFirstPage` when the *crawlable* endpoint
returns a feed with `metadata.numberOfItems == nil` and a `rel="next"` link — a paginated
feed that declines to state its total is a server contract violation, and Crashlytics
would surface it. Cheap, non-behavioural, but do it on `develop`.

**(b) `numberOfItems == 0`. — PASS on the paths this change touches.**
`feedIsPartial` returns false for a declared 0 (`count < 0` is never true), so a 0-declared
1457-row feed reads COMPLETE, which is right. The dangerous shape is an empty response
declaring 0. On the page-1 path `mergePartialPage` protects it: `merge(existing: 1142,
updates: [], isFullCrawl: false)` preserves all 1142. On the `crawl()` path an empty
end-of-feed response still wipes the registry via `loader:699-700` — but that is
**identical in 508**, and not covered by INV-2 for the reason in F-6.

**(c) `numberOfItems` reported far larger than reality (e.g. 5000 vs 1457). — WARNING.**
`fetchPagesParallel` (`crawler :488-494`) derives offsets from the declared total, so an
inflated total produces proportionally more page requests (49 rather than 14 at
`size=100`). Each over-range page either 404s — which **throws** inside the
`withThrowingTaskGroup` child (`crawler :528-533`) and aborts the whole crawl to `.failure`,
leaving the merged 1242 intact, acceptable — or returns HTTP 200 with an empty `catalogs`
array, in which case nothing throws, `reachedDeclaredTotal` is false, `lastFullCrawlDate`
is correctly withheld, and the cache is written declaring 5000 against 1457 rows, i.e.
permanently PARTIAL on disk. Consequence of a permanently-partial cache is bounded:
`hydrateFullAccountSets` still applies it (the bucket is empty at launch) and `crawl()`
still stamps `lastFullCrawlDate` off its own `reachedEnd` signal (`crawler :255`,
`:299-301`), not off `reachedDeclaredTotal` — so there is no permanent full-crawl loop.
Cost is the extra page requests.

## F-6 — INV-2 COVERAGE IS NARROWER THAN THE COMMIT BODY CLAIMS — **WARNING** (claim_drift)

The commit body of `615952ed4` states:

> *"Both bucket writers route through it, so it is an invariant rather than a patch on one caller."*
> *"The cache write is GATED on the bucket write, and a refusal skips the state machine…"*

Both sentences are literally true of what they name and misleading about the guard's reach.
Concretely:

1. **Eight of the nine `loadAccountSetsAndAuthDoc` call sites pass `isCompleteFeed: true`
   by default** (enumerated in F-1). The default is an *assertion of completeness*, not a
   derivation from the bytes, so INV-2 is armed on exactly one path — the merged page-1
   path at `:571`. `hydrateFullAccountSets` (`:341`) does derive it, so two of ten sites
   are honest.
2. **Only one of five disk writes is gated.** Gated: `:584`. Still unconditional and
   still *preceding* the bucket write: `:523`, `:620`, `:645`, `:699`, `:724`. The
   fix-contract itself records this at rev6 S-1 — *"it does not cover `:570`, `:595`, or
   `:674`"* — so the durable record is correct and the commit body is the overstated one.
3. **The sharpest instance is `:620-621`.** Thirty lines earlier in the same commit,
   `crawlRemainingPages` computes `reachedDeclaredTotal` (`crawler :429-430`), logs
   `Log.error("Pagination ended short of the declared total…")`, refuses to stamp
   `lastFullCrawlDate`, and merges with `isFullCrawl: false`. The loader then writes those
   same bytes to disk unconditionally and hands them to `replaceBucket` with
   `isCompleteFeed: true`. **The two halves of one commit disagree about the same feed.**
   Compounding it, `:614` passes `existingPublications: firstPage.catalogs` — the crawl
   result is merged onto page 1, not onto the 1,242 rows the app actually holds, which is
   a second-order instance of the "page 1 is the world" assumption this changeset exists
   to remove.

4. **The doc comment at `:797` says "the four pre-existing callers."** There are eight.
   The number matters, because each is a site where the guard is disabled by assertion.

**Why this is a warning and not a blocker:** it is not a regression. In 508, `:621`
replaced a 100-row bucket with a 900-row short crawl (a gain). In 509 it replaces a
1,242-row bucket with the same 900 (a loss relative to 509's own better intermediate
state, still a gain relative to 508). Absolute outcome is never worse than build 508 on
any path I traced, and the trigger requires a server-side short page returning HTTP 200.

**Recommendation:** on `develop`, derive `isCompleteFeed` from the bytes at all eight
sites (the single definition `LibraryCatalogMerger.feedIsPartial` already exists and is
cheap) and gate the remaining four disk writes on `applied`. Do **not** amend on this
release branch — an amend invalidates six architect rounds for a non-regression.

## F-7 — ROLLBACK STORY — **PASS** (verified, no corrupting persistent state)

Revert to build 508 is a clean `git revert` of the three commits. Nothing written by 509
outlives it in a state 508 cannot read.

1. **`crawl_state_<hash>.json`** — schema unchanged. `CrawlState` gains no field;
   `requireFullCrawlOnNextRun` only nils two existing `Date?`s. A 508 binary reads it,
   sees `lastSuccessfulCrawlDate == nil`, and does one full crawl
   (`CrawlState.swift:51-52`). **Self-correcting.**
2. **The catalog cache JSON now contains `"numberOfItems": 1457`.** Verified that
   `origin/release/3.3.0`'s `OPDS2CatalogsFeed.Metadata` already declares
   `public let numberOfItems: Int?` with a defaulted init — so 508 decodes the field and
   ignores it. **No decode failure, no migration.**
3. **The cache *contents* are now `bundled ∪ page1` (~1,242) rather than page 1 (100).**
   A reverted 508 build inherits a strictly larger cache. It would re-truncate it on the
   next cache miss, i.e. resume 508's own bug — but there is no corrupted or unreadable
   state.
4. **No new file, no new key, no schema version, no migration.** `slimSnapshotURL` and
   `clearFileCaches()` sweep the same prefixes as before.

## F-8 — pbxproj: the 6 removed entries are NOT dropped tests — **PASS**

The diff removes six pbxproj entries, which reads as damage. Verified mechanically that
it is not:

```
LibrariesView.swift                              file exists: NO   entries now: 0  (dangling)
MyBooksDownloadCenterCachePurgeTests.swift       file exists: NO   entries now: 0  (dangling)
LocalizationTablesTests.swift                    file exists: NO   entries now: 0  (dangling)
ReaderPageOfFormatTests.swift                    file exists: NO   entries now: 0  (dangling)
DirectionalNavigationAdapterOwnershipTests.swift file exists: YES  base 5 → head 4  (de-duplicated)
TPPReaderPositionsVCTOCTests.swift               file exists: YES  base 6 → head 4  (de-duplicated)
```

Both surviving files still have exactly one `PBXFileReference` and one Sources-phase
entry, so neither is dropped from the test target. The four new test files each have
full wiring (fileref + group + Sources). Four dangling UUIDs cleaned, two duplicates
collapsed. No test leaves the suite.

## F-9 — `check-contract-reconciliation.py` exit 1 — **false positives, disagreed with**

All four "unsupported REM claims" are the naive `remove*` regex matching English prose in
the commit body and contract, not deletion claims:

```
REM args=('no',)     ← "a write that removes no uuids is always applied"
REM args=('uuids',)  ← "a write that REMOVES uuids needs positively-asserted completeness"
REM args=('state',)  ← "a refusal skips the state machine"
```

None asserts a symbol or file removal. I read each and disagree with the script. This is
the known "reconciliation gate parses prose as claims" behaviour, not claim drift.

## F-10 — auth-gate change (`555ba957f`) — **PASS**, one adjacency note

`AudiobookSessionManager.swift:2661-2682` and `CarPlayAudiobookBridge.swift:61-68`.

- **Monotonicity holds.** `return false` → `return hasCredentials`. The range is a
  subset of the old constant's complement, so the change can only flip `false → true`,
  and only for a patron with stored credentials. Verified there is no path where it can
  newly deny.
- **Credential scoping is correct.** `accountsManager.currentUserAccount` resolves via
  `credentialResolver.currentUserAccount` (`AccountCredentialResolver.swift:108-120`),
  which keys on `currentAccountIdProvider()`, so the credentials read are the selected
  library's — not another library's. It takes its own `userAccountsLock` (an `NSLock`
  unrelated to `accountSetsLock`), so there is no re-entrancy into the registry store
  from an auth gate.
- **Adjacency note (pre-existing, not introduced):**
  `CarPlayAudiobookBridge.swift:61` still has
  `accountsManager: AccountsManager = AppContainer.production().accountsManager` as a
  **default argument** — the exact shape that has previously re-entered the composition
  root's non-recursive lock. The diff does not touch that line and does not make it
  reachable from any new stack, so it is out of scope for 509, but it sits one line above
  changed code and should be constructor-injected on `develop`.

## F-11 — injection / test-seam / DEBUG reachability — **PASS**

- **Zero `#if DEBUG`, `XCTest`, or `@testable` lines added to production code** (counted
  over the production diff: 0). Nothing new is DEBUG-gated, so nothing new is
  DEBUG-reachable in TestFlight or App Store builds.
- **The `crawlerFetcher` seam improves injection rather than bypassing it.** It replaces
  three hardcoded `LibraryRegistryCrawler(fetcher: URLSessionCrawlerFetcher(), …)`
  constructions (`:552`, `:590`, `:688`) with one injectable property. No new `.shared`
  read, no new static factory, no new singleton. The one caveat is that it is an
  unsynchronized `var` on an `@unchecked Sendable` class read from background crawl
  tasks; in production it is never written after init, and it matches the documented
  `snapshotResourceResolver` precedent directly above it.
- **No secrets, signing material, or `.env`/`APIKeys`/`GoogleService` files in the diff**
  (counted: 0). `CURRENT_PROJECT_VERSION` 508 → 509 across all four configurations only.
- Constructing a whole `LibraryRegistryCrawler` at `:590` purely to call
  `requireFullCrawlOnNextRun()` runs its `init`'s `FileManager.url(for:
  .applicationSupportDirectory, create: true)` and a `Bundle.main.infoDictionary` read.
  Once per cache-miss launch — negligible, but a static/file-scoped helper would be
  cleaner.

---

## Release risk summary

**Understood and acceptable for build 509.** The change is a mitigation for a live
patron-facing outage (HelpSpot 19030 / 19012), it is monotone-improving on every path I
traced, it introduces no ABI break, no lock hazard, no DEBUG reachability, no extra
network traffic, and no persistent state that survives a revert in a bad shape. The added
cold-launch CPU (F-3) is off-main and bounded to cache-miss launches.

**Carry to 3.4.0 on `develop`, in priority order:**
1. F-5(a) — log once when the crawlable endpoint omits `numberOfItems` on a paginated
   feed. Without it, a server-side field removal silently disarms this entire changeset.
2. F-6 — derive `isCompleteFeed` from the bytes at the eight defaulted call sites and
   gate the four remaining disk writes on `applied`; fix the "four pre-existing callers"
   doc comment at `:797`.
3. F-3 — collapse two of the four redundant JSON decodes in the merge path.
4. F-10 — constructor-inject `CarPlayAuthHelper.isAuthenticated`'s `accountsManager`.

**What I could not evaluate:** I did not build or run the test suite (out of scope for
this role — CI and the QA review cover it), and I have no field telemetry to bound how
often a registry page returns HTTP 200 with fewer rows than `size`, which is the sole
trigger for F-6(3). If that rate is believed to be non-zero, re-weigh F-6 before merge.
