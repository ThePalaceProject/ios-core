# Architect post-review — PP-5191 fix-contract (contract only, no code yet)

**Branch:** `fix/PP-5191-registry-truncation` · **Worktree:** `/Users/mauricework/PalaceProject/wt-5191` · **Base:** `origin/develop` (tip `ea61dd998`)
**Reviewer:** architect (independent) · **Date:** 2026-09-21
**Governance:** ForgeOS OFF in this environment — no MCP call made, no signed verdict submitted. This file is the verdict.

## VERDICT: **BLOCKED**

The root cause is **correct and well-evidenced** — I re-derived it independently and found a
discriminating fact the contract does not state (F-1). Blocking is for the *contract's*
defects, not its diagnosis: three of eight Verification criteria are already satisfied on
`origin/develop` or can never match (a gate that cannot fail reports a pass), INV-2 is
specified as a magic threshold when a precise provenance predicate already exists in the
data model, and the fix closes one of three bucket-shrink write sites.

---

## 1. Does the causal chain hold against the code? — **YES, confirmed, with one correction**

Traced in `Palace/Accounts/Library/AccountRegistryLoader.swift`:

- `loadCatalogs` path 3 (`:496-516`) spawns ONE owned task that (a) writes the bundled
  snapshot to disk with `isBundled: true` (`:507`), (b) calls `loadAccountSetsAndAuthDoc`
  on those bytes, then (c) calls `fetchFromNetwork` (`:515`). `loadAccountSetsAndAuthDoc`
  performs `registryStore.mutate { $0[hash] = newAccounts }` **synchronously** at `:735`
  (the `DispatchGroup.notify` only defers the *completion*, not the bucket write), so the
  1142-account bucket is committed before `:515` runs. **The bundled write does precede
  the page-1 write.** Confirmed.
- `fetchFromNetwork` first-page branch (`:542-547`): `writeCatalogData(firstPageData, hash:)`
  → protocol-extension convenience → `isBundled: false` (`AccountRegistryCache.swift:159-161`),
  then `loadAccountSetsAndAuthDoc(firstPageData)` → `:735` **whole-bucket replacement**.
  `LibraryCatalogMerger` is not on this path. **1142 → 100 on both disk and in memory.**
  Confirmed.
- Strictly it is a *nested* Task (`:532`), not the same Task as (a)/(b). Same causal chain,
  ordered by `await`; the contract's "same task" is loose but the ordering claim is sound.

**CORRECTION to §"Consequences" item 3.** The contract says "*Every launch for the next 6
hours takes `loadCatalogs` path 1/2 and never refreshes.*" Path 2 (`:477-489`) calls
`refreshInBackground` **unconditionally** — it is not gated on staleness. Only path 1
(`:467-474`) gates on `isCatalogStale`. The conclusion survives because on a cold launch
`preloadAccountsFromDiskCacheSync` fills the bucket first, so `loadCatalogs` takes path 1 —
but fix the prose, because a reader who checks path 2 will conclude the contract is wrong.

**F-1 — the discriminating fact the contract does not make explicit (use it).**
Both reported UUIDs are present in the bundled snapshot, verbatim:

    $ python3 -c "...json.load(open('Palace/Accounts/Library/bundled_registry.json'))..."
    urn:uuid:8aff215f-9143-480b-8106-30947f919ce6 | Cortland Community Library
    urn:uuid:b3a28b6d-3821-42f5-b821-8943185b1c1c | Catoosa County Library

Because path 3 writes the bundle **before** anything else, "the registry never loaded" and
"the library was deregistered" are both ruled out: something must have *removed* an account
that had already been committed. The only writers that can do that are the whole-bucket
replacements. This is the strongest sentence in the case and it is missing.

**F-2 — the contract UNDERSTATES persistence (in its own favour).** It claims a 6-hour
window. Trace `refreshInBackground` (`:618-663`) on a truncated cache: `existingPubs` = the
100 from disk; `LibraryRegistryCrawler.crawl` (`:128-303`) takes the INCREMENTAL branch
whenever `CrawlState.needsFullCrawl` is false (`CrawlState.swift:48-65`), and an incremental
walk that early-stops merges with `isFullCrawl: false` → `LibraryCatalogMerger.swift:63-85`
preserves `existing` (100) and adds only recently-modified entries. The 1042 missing
libraries are **not** restored. They come back only when `needsFullCrawl` fires — app-version
change, or `lastFullCrawlDate` older than 7 days. **Truncation can be sticky for up to a
week, across many refreshes.** Say so; it raises the severity and it changes test 2's shape.

## 2. Is "entered whenever the cache is absent or >24h old" correct? — **YES, and the isExpired/isStale distinction is right**

`hasFreshCatalogData` (`AccountRegistryCache.swift:195-203`) returns `!metadata.isExpired`;
`isExpired` is `> maxAge` = 86400s (`:63`, `:101-103`). `isCatalogStale` (`:205-209`) routes
through `isStale` = `staleTTL(serverMaxAge)` (6h default, clamped [5m, 12h]) with the
`isBundled` force-stale short-circuit (`:87`). The two predicates are distinct exactly as the
contract depends on. **Verified.**

Two omissions to fold in:
- `hasFreshCatalogData` is also false when the **metadata file is missing or undecodable**
  (`:198-201`), independent of age. So path 3 is entered on "absent, >24h old, **or metadata
  lost**". Worth a sentence — it widens the exposed population.
- Pre-existing comment/code drift at `:199`: the comment says "*treat as usable but stale*"
  while the code `return false` = **not usable**. Not yours to fix, but do not trust that
  comment while reasoning.

## 3. Is marking the partial page "provisional" SAFE? — **YES for refresh/battery. NO as written for data freshness.**

Traced `isCatalogStale == true` forever-until-full-crawl:
- Path 1 (`:467-474`): every `loadCatalogs` call now spawns `refreshInBackground`. Call sites
  are bounded — `AccountsManager.init`, `TPPAppDelegate.swift:617` (first-run flow), and
  `updateAccountSet` (`AccountsManager.swift:777-780`), which only calls `loadCatalogs` when
  the bucket is EMPTY. There is no per-view or per-notification caller. **No refresh storm.**
- Path 2 (`:477-489`): unaffected — it already refreshes unconditionally.
- `hasFreshCatalogData` does **not** consult the flag, so provisional never prevents the cache
  from being read, hydrated, or trusted for display. **There is no path where the cache
  becomes permanently untrusted.** The exposure is identical to today's `isBundled: true`
  first-launch state, which already ships.
- Missing dedupe worth knowing: path 1 has no in-flight guard (unlike path 3's
  `addLoadingHandler`), so two near-simultaneous `loadCatalogs` calls spawn two crawls. That
  is pre-existing, and provisional makes it reachable more often. Accept, but note it.

**F-3 (concern) — the merge introduces a NEW stale-data vector the contract does not name.**
After `mergePartialPage`, the on-disk cache is `bundled ∪ page1`. `refreshInBackground` then
feeds those bytes in as `existingPublications`, and per F-2 an incremental crawl **preserves**
them. Build-time bundled entries (libraries since deleted, catalog URLs since changed) are
thereby promoted into the live cache and survive until the next full crawl — up to 7 days.
Today they are clobbered within ~260ms, so this is new. **Required mitigation:** whenever a
provisional write happens, force the next crawl to be full (clear `lastFullCrawlDate` /
`lastSuccessfulCrawlDate` in `crawl_state_<hash>.json`, or merge only into the previous
**network-origin** bytes and not into bundled bytes). Either is a few lines; without it the
fix trades a truncation bug for a staleness bug and no test in the contract would see it.

## 4. Is `isBundled` → `isProvisional` worth the diff? — **NO. Scope creep. Cut it, or land it separately.**

Full census (`grep -rn isBundled Palace/ PalaceTests/`): 2 production files, ~16 production
sites, **3 test files / ~22 test sites** (`CatalogCacheMetadataTests.swift` ×15,
`AccountRegistryCacheSeamTests.swift` ×6, `AccountRegistryLoaderSeamTests.swift:125`).

- The flag's only behavioural reader is `isStale` (`:87`). Renaming buys comprehension, zero
  behaviour. Meanwhile it churns `CatalogCacheMetadataTests` — the suite the Acceptance
  section names as the green-gate — so a rename failure and a fix failure become
  indistinguishable in the same run. That is the wrong thing to bundle with a critical-path
  fix (CLAUDE.md single-purpose-commit discipline).
- **On-disk compatibility risk the contract missed:** the rename does not stop at the struct.
  `writeCatalogData(_:hash:isBundled:)` is a **protocol requirement** on `AccountRegistryCaching`
  (`:133`) — a surface the accounts verification-checklist §2 lists as "*what changes here is
  a contract break*", destined for the `PalaceAccounts` package move. Renaming the label
  forces every conformer to change (`DiskAccountRegistryCache` + 2 test doubles) and is a
  package-surface break, not a local rename. The contract says "Swift level" without saying
  whether the protocol label moves. **Specify it.**
- The other on-disk detail is fine: `case isProvisional = "isBundled"` keeps the JSON key, and
  `encode(to:)` is synthesized off `CodingKeys`, so round-trip is preserved. But see F-6 —
  your own verification grep for this is broken.

**Recommendation:** keep the *doc comment* widening (name both origins — that is the part
with value), drop the rename from this changeset, or land it as a separate no-behaviour
commit AFTER the fix is green.

## 5. Is the INV-2 shrink guard well-specified? — **NO. Under-specified, and the threshold is the wrong mechanism. A precise one already exists.**

Threshold risks, re-traced:
- **prod↔beta hash switch — NOT a risk.** `registryStore.mutate { $0[hash] = ... }` is keyed
  by the URL hash; beta and prod occupy different buckets (`AccountsManager.swift:768-778`).
  Remove it from the contract; a stated risk that isn't one costs reviewer trust.
- **`clearCache()` — NOT a risk.** It clears the network cache + files only
  (`AccountsManager.swift:786-792`); the in-memory bucket is untouched, and `loadCatalogs`
  then takes path 1 on the surviving bucket.
- **Legitimate deletion reconciliation — REAL.** `LibraryCatalogMerger.merge(isFullCrawl: true)`
  returns exactly `updates` (`LibraryCatalogMerger.swift:56-60`); a registry-side availability
  change that halves the feed is a legitimate >50% shrink that the guard would silently
  refuse, leaving deleted libraries resident forever with only a `Log.error`.
- **Existing tests — I could not find one that breaks.** `registryStore` is per-`AccountsManager`
  instance, and the four test drivers of `loadAccountSetsAndAuthDoc`
  (`AccountsManagerCacheReadTests.swift:257`, `AccountsManagerStateMachineWiringTests.swift:254`,
  `AccountsManagerLaunchSnapshotTests.swift:245,521`) all load the SAME or a larger feed into
  a fresh manager. `_seedAccountForTesting` (`AccountsManager.swift:619-637`) appends rather
  than replaces. `storeSlim` writes a separate map. **No named breakage** — but that is a
  weak clearance, because "less than half" and "materially-populated" have no numbers in the
  contract, so the blast radius is literally unspecified. **Give both constants.**

**F-4 (concern) — the guard is placed at one of THREE shrink sites, and the contract names one vector.**
1. `fetchFromNetwork` page-1 verbatim write (`:543-544`) — the one the contract fixes.
2. **`crawlRemainingPages` can write a SHORT list as authoritative.** `LibraryRegistryCrawler.swift:381-388`
   derives page offsets from `firstPage.metadata.numberOfItems`; if the server under-reports
   it, `fetchPagesParallel` computes too few offsets, no child throws, and `:406-410` merges
   with `isFullCrawl: true` → the truncated set is written with `isBundled: false` and
   `lastFullCrawlDate` set. `mergePartialPage` does **not** cover this. There is no
   post-condition check that `allPublications.count >= numberOfItems`.
3. **`hydrateFullAccountSets` (`AccountRegistryLoader.swift:326`) is a second unguarded
   whole-bucket replacement**, reached from `preloadAccountsFromDiskCacheSync`. A guard that
   lives only in `loadAccountSetsAndAuthDoc` is not an invariant — it is a patch on one caller.

**F-5 — proposed better mechanism (provenance, not ratio).** The completeness predicate you
need is already in the model and already in the data:

- `OPDS2CatalogsFeed.Metadata.numberOfItems` is `Codable`
  (`Palace/Packages/PalaceCatalog/.../OPDS2CatalogsFeed.swift:16`), so it round-trips on disk
  for free.
- `bundled_registry.json` already carries `"numberOfItems": 1142` alongside 1142 catalogs.
- The only reason a partial page is indistinguishable from a complete feed on disk is that
  `LibraryCatalogMerger.serializeAsCatalogsFeed` is handed a metadata built from
  `(adobe_vendor_id, title)` only — `LibraryRegistryCrawler.swift:330-339` (first page) and
  `:367, :412` (full) **drop `numberOfItems`**.

So: **carry `numberOfItems` through serialization**, and define INV-2 as
> a feed with `catalogs.count < metadata.numberOfItems` is PARTIAL, and a PARTIAL feed may
> never replace a bucket derived from a complete feed.

This is a pure function of the bytes, needs no threshold, has **zero** false positives on
legitimate deletion (a full crawl reports `numberOfItems == count`), covers all three write
sites including vector 2 above, is durable across process restart (unlike an in-memory
heuristic), and makes the "provisional" flag derivable rather than asserted. It is also
strictly easier to mutation-test than a ratio. I recommend replacing the threshold with it.
If you keep a ratio as a belt-and-braces backstop, state both constants and make the failure
mode "write anyway + `Log.error` + telemetry", not "refuse".

## 6. Are the Scope(out) exclusions correct? — **YES. Both traces verified independently.**

- **`HoldsViewModel.swift:112`** — `currentLibraryNeedsAuth = { currentAccount?.needsAuth ?? true }`.
  Only consumer is `:252`: `anonymous = !currentLibraryNeedsAuth() || !hasCredentials()`.
  With `currentAccount == nil` the closure yields `true`, so `anonymous` collapses to
  `!hasCredentials()` — for a credentialed patron, `false`. Its sole effect is whether a sync
  **error banner** is suppressed. `refresh()` (`:327-337`) — the only `presentSignIn` caller
  (`:332`) — reads `accountsManager.currentUserAccount.needsAuth` / `.hasCredentials()`, the
  keychain path, never `currentAccount`. **A credentialed patron is not prompted. Exclusion correct.**
  (Cost of the nil: an error banner that would otherwise be suppressed. Worth one line in the
  contract so the deferral is honest about what it leaves broken.)
- **`BookDetailViewModel.swift:870`** — `libraryAccountID: currentAccount?.uuid ?? ""` feeds
  `TPPSignInBusinessLogic`; the prompt decision at `:879-893` reads
  `accountsManager.currentUserAccount` → `needsSignIn = account.needsAuth && !account.hasCredentials()`.
  Keychain-backed, and `currentUserAccount` resolves via `userAccount(for: currentAccountId)`
  regardless of `currentAccount`. **Not prompted. Exclusion correct.** One nit: the contract's
  reasoning ("*`ensureAuthenticationDocumentIsLoaded` returns `false` for the empty ID*") is
  irrelevant — the completion's `Bool` is discarded (`{ [weak self] (_: Bool) in`). Right
  answer, wrong reason; fix the prose so the next reader doesn't rely on a false premise.
- The `awaitReady()` feature-degradation exclusions and the `LibraryRegistryCrawler.crawl()`
  exclusion are correct — that path does go through `LibraryCatalogMerger`.
- `AccountRegistryStore.mutate` "replacement semantics stay" — **see F-4(3)**: that decision is
  what leaves `hydrateFullAccountSets` unguarded. Either guard both callers or say explicitly
  that the preload path is accepted-unguarded and why.

## 7. /rigorous-fix or /swarm? — **/rigorous-fix, but SPLIT into two commits**

Three modules, but one causal spine and ~10 LOC outside `Palace/Accounts/`. A swarm's
parallel file-owner model buys nothing and costs an integration step. However, the changeset
contains **two independent fixes with different risk profiles**:

- **B (gates):** `AudiobookSessionManager.swift:2661` + `CarPlayAudiobookBridge.swift:61` —
  ~5 lines each, mirrors the already-shipped PP-5135 treatment of the sibling arm, is the
  user-visible mitigation, and is independently testable. This is also the **structural
  sibling sweep**: the two gates are siblings, and PP-5135 already touched one arm of one of
  them — the commit body must state that both files and both arms were audited.
- **A (registry):** cache semantics + concurrency + a new pure merge. Higher risk, needs the
  mutation gate.

Land B first (fast relief, trivially reviewable), then A. Note in the contract that B is a
**mitigation, not the fix** — with B alone, Settings still shows an empty library list and the
catalog is still 93% short.

**Safety check on B (I looked for a way it could bite):** `validateRequirements`
(`AudiobookSessionManager.swift:2552-2555`) maps `false` → `.notAuthenticated`. Flipping to
`true` on stored credentials is **monotonic** — a library needing no auth already returned
`true` via the `defaultAuth` branches, and a patron with no credentials still returns `false`.
The only new reachable state is "proceed to play a downloaded book for a signed-in patron
whose registry row is missing", which is the desired outcome. Downstream does not force-unwrap
`currentAccount` on that path. **No objection.** Same shape for CarPlay
(`CarPlayTemplateManager.swift:389` → `handlePlaybackError` alert). Use
`accountsManager.userAccount(for: currentAccountId)` or `currentUserAccount` (which already has
the `lastKnownCurrentUserAccount` ride-out, checklist §5) — not `TPPUserAccount.sharedAccount()`.

## 8. Are the Verification criteria valid greps? — **NO. Three of eight are broken. This is the hardest blocker.**

Run against the current tree (no code yet — all should FAIL; three do not):

| # | Criterion | Ran | Verdict |
|---|-----------|-----|---------|
| 1 | `grep -n "mergePartialPage" …Loader.swift` ≥2 | exit 1, 0 matches | OK — correctly red |
| 2 | `grep -c "writeCatalogData(firstPageData" …Loader.swift` == 0 | prints `1` | OK — correctly red. Weak (a local-variable rename satisfies it) but acceptable |
| 3 | `grep -rn "isProvisional" …Cache.swift` ≥3 | exit 1, 0 matches | OK — correctly red |
| 4 | `grep -n "case isBundled" …Cache.swift` ≥1 | **exit 1, 0 matches TODAY** | **BROKEN.** The line is `case timestamp, hash, isBundled` — `"case isBundled"` is not a substring of it, so this never matched even pre-change; and the intended post-change form `case isProvisional = "isBundled"` does not match either. **Unsatisfiable in both directions.** Use `grep -n '"isBundled"' …Cache.swift` (the string literal in `CodingKeys`) plus a decode round-trip test |
| 5 | `grep -c "mergePartialPage\|INV-2" PalaceTests/Accounts/*.swift` ≥1 | multi-file `grep -c` emits per-file counts | Ill-formed as a threshold, and the path is probably wrong: the loader's seam tests live in `PalaceTests/Decomp/` (`AccountRegistryLoaderSeamTests.swift`, `AccountRegistryCacheSeamTests.swift`), not `PalaceTests/Accounts/`. Use `grep -rl … PalaceTests/ \| wc -l` or name the file |
| 6 | `grep -rn "hasCredentials" …AudiobookSessionManager.swift \| grep -c .` ≥2 | **prints `8` TODAY** | **BROKEN — a gate that cannot fail.** Already passes on `origin/develop`; it cannot distinguish "both arms fall back" from "nothing changed". Anchor on the nil-account arm, e.g. assert the `guard let account = accountsManager.currentAccount else { return false }` shape is GONE from `:2661`, or count `offlineAuthFallback` uses |
| 7 | `grep -rn "hasCredentials" …CarPlayAudiobookBridge.swift` ≥1 | **matches `:81` TODAY** | **BROKEN — same class.** Already satisfied pre-change |
| 8 | "every new `await` driven by a named test" | not grep-able | Fine as prose; it is a review instruction, not a criterion. Label it as such |

Criteria 6 and 7 are precisely the failure mode in the harness canon: *absence always renders
as the good outcome*. A criterion that is green before the work starts is not a criterion.
**Every criterion must be demonstrated RED on `origin/develop` and cited as such in the
contract**, the same discipline the Acceptance section already applies to test 2.

---

## Additional findings

**F-6 (warning) — Tests required §7 is untestable as written.** "*metadata JSON written by the
pre-fix build decodes into `isProvisional`*" — if the rename is dropped (recommended, §4),
§7 disappears. If it is kept, the test must construct the legacy JSON **as bytes**
(`{"timestamp":…,"hash":"h","isBundled":true}`) and decode; a test that encodes with the new
type and decodes with the new type proves nothing (it is the same `CodingKeys` on both sides).

**F-7 (warning) — Tests required §2 needs a second cell after F-2.** "Assert
`account(currentAccountId) != nil` afterwards" is necessary but not sufficient: it passes if
the merge keeps only the current account. Assert the **count** is preserved
(`accounts(hash).count == seeded.count`) and that a *non-current* seeded library also survives.
Also add the F-2 cell: after the truncating write, a subsequent **incremental** refresh must
not leave the bucket short.

**F-8 (pass) — `docs/architecture/areas/accounts/verification-checklist.md` is stale but not
blocking.** §9 last content refresh 2026-05-28; the 3a seam pass explicitly did not re-audit
§§1-7, and §§1/3/4 still say `.accountNotFound` where the code now says `.detailsEvicted`
(`AccountsManager.swift:732`). Per §"Purpose", *"the architect's first deliverable on ANY
swarm or /rigorous-fix in this area is update this file."* None of the sites this changeset
touches (`AccountRegistryLoader`, `AccountRegistryCache`) appear in §1's call-site map at all.
**Add a §9 row and a §1 entry for the registry-loader write sites as part of this changeset**
— the DoD treats an out-of-date area checklist as scope debt.

**F-9 (pass) — no secrets, no signing, no platform-contract surface.** Nothing in scope
touches CarPlay's `CPInterfaceController` push/completion surface (only `CarPlayAuthHelper`,
a pure predicate), so the iOS-26 nullable-completion-handler lens does not apply here.

---

## What must change before this contract is APPROVED

1. Repair criteria 4, 6, 7; re-path criterion 5; demonstrate every criterion RED on
   `origin/develop` and record the output in the contract. (F-6/§8 — blocker)
2. Replace the INV-2 ratio with the `numberOfItems` completeness predicate (F-5), or state
   both constants and justify the ratio against legitimate deletion. (blocker)
3. Extend the guard to the other two shrink sites, or state explicitly why
   `hydrateFullAccountSets` (`:326`) and the short-parallel-crawl vector are out of scope. (F-4 — blocker)
4. Add the provisional→force-full-crawl mitigation so the merge does not make stale bundled
   entries sticky for up to 7 days. (F-3 — blocker)
5. Drop the `isBundled` → `isProvisional` rename from this changeset, or specify whether the
   protocol label moves and land it as a separate commit. (F-4/§4 — concern)
6. Fix the path-2 prose, add the missing-metadata entry condition, add the F-1 bundled-snapshot
   argument, correct the BookDetail reasoning, and add the F-2 stickiness finding. (concern)
7. Split B (gates) from A (registry) into two commits, B first; state the sibling sweep in B's
   commit body. (concern)
8. Add a §9 refresh row + §1 call-site entries to the accounts verification checklist. (concern)

## Re-review

Re-request once the contract is revised. I will re-verify §8 criteria mechanically and re-run
the §5 test census before approving.
