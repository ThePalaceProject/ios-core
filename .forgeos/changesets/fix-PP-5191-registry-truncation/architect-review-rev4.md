# Architect post-review — PP-5191 fix-contract **rev 4**

**Branch:** `fix/PP-5191-registry-truncation` · **Base:** `ea61dd998` · 2026-09-21
ForgeOS OFF — no MCP call, no signed verdict.

## VERDICT: **BLOCKED** — two blockers, both inside the "unless COMPLETE" escape you asked about in (a)

Rev 4 adopts A-3 correctly and the five-case table is right. I re-verified the re-targeted criteria
on `ea61dd998`: **C13 on the merger `0`, C7 `1`, C8 `1`** — all red as stated.

Then I attacked the escape, and it does not hold — but not for the reason you proposed. The
escape's **precondition is false under your own serialization plan**: on the primary refresh path a
full crawl does *not* report `numberOfItems == count`, so the escape fails open in one direction and
shut in the other. And `nil ⇒ COMPLETE` hands deletion authority to the one network path whose
completeness nobody has measured.

---

## (a) The "unless COMPLETE" escape

### A-4 (BLOCKER) — "a full crawl is COMPLETE by definition" is FALSE on `refreshInBackground`

Your premise depends on the serialized feed's `numberOfItems` coming from the response that produced
the rows. On one of the three serialize sites it does not. Read the actual wiring:

    LibraryRegistryCrawler.swift:277   crawl():
        let meta = feedMetadata ?? OPDS2CatalogsFeed.Metadata(adobe_vendor_id: nil, title: …)

    AccountRegistryLoader.swift:628-632  refreshInBackground supplies that argument:
        if let cachedData = readCatalogData(hash), let feed = …fromData(cachedData) {
            existingMetadata = feed.metadata          ← the CACHED feed's metadata

So `crawl()` serializes with the **stale cached** `numberOfItems`, not the one it just fetched at
`:156`. (`crawlRemainingPages` at `:367`/`:412` is fine — the loader passes `firstPage.metadata` at
`:564`, which is fresh. The defect is isolated to `:277`.)

Consequence, on the path that exists *specifically* to reconcile deletions:

| registry truth | cached `numberOfItems` | emitted | `feedIsPartial` | INV-2 |
|---|---|---|---|---|
| shrinks 1457 → 1400 (real deletions) | 1457 | count 1400 / nOI **1457** | **PARTIAL** | removes uuids, not complete ⇒ **REFUSE** |
| grows 1457 → 1500 | 1457 | count 1500 / nOI 1457 | COMPLETE | ACCEPT |

**Deletions never reconcile, forever**, and §"INV-2" claims the exact opposite ("Zero false positives
on deletion reconciliation"). Note also that §4's instruction — *"Populate `numberOfItems` at the 4
`Metadata(...)` construction sites"* — does **not** fix this: at `:277` the `??` fallback is only
reached when `feedMetadata` is nil, so populating the fallback leaves the normal path untouched. An
implementer following §4 literally ships this.

**Required:** the serialized feed's `numberOfItems` must come from **the response that produced the
rows**. At `:277`, take `firstPage.metadata.numberOfItems` (already in scope from `:156`) and let it
override the carried-forward `feedMetadata`; keep `feedMetadata` only for `title`/`adobe_vendor_id`.
State it as a rule — *"`numberOfItems` is never carried forward from cache; it is always the count
the server reported in this exchange"* — rather than as four call-site edits, or the next refactor
re-introduces it.

### A-5 (BLOCKER) — `nil ⇒ COMPLETE` grants **deletion authority** to the one path whose completeness is unmeasured

`nil ⇒ COMPLETE` was adopted for three good reasons: legacy on-disk caches, the 171-row test fixture,
and the `/libraries` direct-GET recovery. Every one of those reasons is about **not refusing** a
write. None of them is about licensing a write to **delete**. Rev 4 collapses both permissions into
one word, and the escape then reads: *a feed with no `numberOfItems` may wipe the registry.*

The reachable path is `fallbackFetchFromNetwork` (`:589-615`) / `fallbackDirectRefresh` (`:667-682`),
which GET `TPPConfiguration.prodUrl` = `https://registry.palaceproject.io/libraries` — the
**non-crawlable** endpoint, which does not carry `numberOfItems`. Under rev 4 that response is
COMPLETE by fiat, so whatever it contains becomes the registry, removals included. Nobody in this
review has measured what that endpoint returns. Two aggravating details:

- It is the **crawler-failure** path — i.e. it runs exactly when the network is already misbehaving.
- It writes with `writeCatalogData(data, hash:)` ⇒ `isBundled: false` (`:595`, `:674`), so a
  successful direct GET also **clears the provisional/always-stale marker**, ending the refresh
  pressure that would otherwise have corrected it.

**Required — split the one flag into the two permissions it is actually doing:**

> A write that **removes no uuids** is always applied.
> A write that **removes uuids** is applied only if completeness is **positively asserted** —
> `metadata.numberOfItems != nil && catalogs.count == numberOfItems`. Unknown provenance (`nil`)
> may not delete.

Two lines. Every cell of your five-case table is unchanged; the only behaviour that moves is
"nil-metadata feed deletes", which is the hole. Re-checked against the three reasons nil-is-complete
exists: legacy cache at launch removes nothing (empty resident) ⇒ ACCEPT; the 171-row fixture driven
twice removes nothing ⇒ ACCEPT; test 11 (legacy upgrade) removes nothing ⇒ ACCEPT. **No known
regression** — but this is the one behavioural delta from rev 4, so re-run the census for any test
that loads a *smaller, different* nil-metadata feed over a populated bucket. I found none in the four
`loadAccountSetsAndAuthDoc` drivers or in `_seedAccountForTesting` (which appends), but you own the
re-check now that the rule changed.

**Stated tradeoff, which belongs in the contract:** while crawlable is down, real deletions arriving
via the direct-GET fallback will be refused and stale rows will linger. That is the correct side to
err on — a lingering row is a stale entry in the library picker; a wrongly-removed row is a patron
who cannot reach their library, which is this ticket. It is self-correcting: the next successful
crawl carries `numberOfItems` and applies the deletion.

### Does the rule need a floor? — **No. Answering your question directly.**

A floor is the magic ratio we correctly killed in rev 1: it has no defensible constant, and it blocks
the one case the escape exists for. Your framing is right that *"the server told us the truth and the
truth changed"* is out of scope — **with A-5 applied**, because then the only feeds that may delete
are ones that positively assert their own completeness. A server that returns 400 rows and declares
`numberOfItems: 400` is, from the client's position, indistinguishable from a registry that really
has 400 libraries. Refusing it would mean the client permanently disbelieving the registry, which is
a worse failure than the one it prevents.

**But make it observable rather than silent.** On any applied write that removes more than a notable
share of the resident bucket, emit `Log.error` with both counts (`INV-2: applied COMPLETE write
removing N of M uuids`). Log only — never refuse. That gives the Crashlytics non-fatal ground-truth
hook the team already uses for exactly this kind of "did the world change or did we break" question,
without reintroducing a gate. Pick the threshold for the *log line*, where a wrong constant costs
nothing.

---

## (b) Steady state — second launch, resident = merged 1242 from disk

**The good news first, because it is the important part: the design converges.** I walked launch 2
end to end and it reaches the right terminal state.

    preload → slim fast path hits ⇒ bucket EMPTY, storeSlim only, returns  (:251-254)
    loadCatalogs → path 1 sees empty bucket ⇒ falls to path 2 (:477)
                 → loadAccountSetsAndAuthDoc(merged 1242) vs EMPTY resident ⇒ removes nothing ⇒ ACCEPT
                 → refreshInBackground (unconditional on path 2)
    crawl() → requireFullCrawlOnNextRun cleared lastSuccessfulCrawlDate ⇒ needsFullCrawl TRUE
            → full walk, 1457 rows, isFullCrawl ⇒ merge returns updates ⇒ 1457
            → vs resident 1242: removes the bundled-only rows (libraries deleted since the
              2026-05-22 snapshot cut) — but incoming is COMPLETE ⇒ ACCEPT
    steady state: 1457, COMPLETE.   ✓

Four things move in the steady state that the contract does not account for:

**B-6 (concern) — `requireFullCrawlOnNextRun()` "on every provisional write" forces a full 15-page
crawl on every expired-cache launch, forever.** Consider the *post*-steady-state expiry cycle: cache
>24h ⇒ path 3 ⇒ bundled write ⇒ page 1 merges into the on-disk bytes, which are now the **complete
1457** (`readCatalogData` does not check expiry). Merged = 1457 ∪ 100 = 1457 rows emitting
`numberOfItems: 1457` ⇒ **COMPLETE**, not partial. Good outcome — but if the loader calls
`requireFullCrawlOnNextRun()` unconditionally on that write, it discards `lastFullCrawlDate` and
forces the full 15-page crawl that `CrawlState.periodicFullCrawlInterval` deliberately limits to once
a week. For any user who opens the app less than daily that is a full crawl on **every** cold launch.
**Fix:** gate the call on `feedIsPartial(merged) == true` — one conditional, and it ties the
mitigation to the same single definition you just centralised.

This also corrects a prose over-generalisation: §4 says `mergePartialPage` "emits the NETWORK PAGE's
`numberOfItems` … so the merged feed **stays correctly PARTIAL**". It stays partial only when the
base was short. When the base is a complete cached feed the merged result is correctly COMPLETE, and
that is the steady-state case.

**B-7 (concern) — INV-2 protects within a session only; the contract reads as if it were durable.**
Every launch's first `replaceBucket` sees an EMPTY resident (the slim path does not fill the bucket —
`storeSlim` is a separate map by design), so the removal rule cannot fire on the first write of any
launch. If the disk holds short bytes — written by a pre-fix build, or by the A-5 direct-GET path —
launch N+1 hydrates them into the empty bucket, ACCEPTED, and the session runs short with INV-2 never
engaging. **The durable guarantee is `mergePartialPage` (never write short bytes); INV-2 guards
in-session transitions only.** Say that plainly, or the next reader will trust the invariant for a
job it cannot do. And extend test 3 with a second-launch cell: construct a **fresh manager** over the
post-fix on-disk state and assert `preloadAccountsFromDiskCacheSync` yields a non-short bucket.

**B-8 (warning) — the resident read must be `accountSets[hash]`, not the flattened index.**
`accountByUUID` is rebuilt from **all** buckets (`buildAccountIndex` iterates `sets.values`), and it
will be sitting right there in the same critical section. An implementer who reaches for it will
judge a prod write against beta rows and refuse it. Pin the source explicitly in the contract and in
the store's header note.

**B-9 (warning) — the direct-GET fallback silently clears the provisional marker.** `:595` and `:674`
write with `isBundled: false`, ending the always-stale refresh pressure, on a feed whose completeness
is `nil`. With A-5 applied it can no longer *delete*, but it can still end the corrective loop early.
Either have those two sites preserve the current provisional state, or state why ending the loop is
acceptable there.

---

## Also

**D-6 (warning) — measure `/libraries` before shipping A-5's assumption.** Record in the contract what
`GET https://registry.palaceproject.io/libraries` actually returns: row count, whether it paginates,
whether it carries `numberOfItems`. Two of the last three revisions turned on a measured number
(1142 vs 1457; the 171-row fixture). This one is load-bearing for the recovery path and is currently
assumed. It is one curl.

**D-7 (pass) — the three closures are correct.** A-3 adopted verbatim with `bucketIsPartial`/C14
deleted; B-1 reconciled with the right reasoning (parameter as transport, one definition, and the
store genuinely cannot derive it); `feedIsPartial` on `LibraryCatalogMerger`. §9 is now right:
release-first verified against #1490/#1491, `--merge` stated with the #998 reason, and the 499–509
window recorded as pre-existing with an owner and the correct rule ("above the global high-water, not
above develop's own last value"). C7/C8's third anchoring is the right one — it asserts an outcome
and survives both the keep-the-guard and extract-the-arm implementations.

**D-8 (pass) — on your note about the third instance of the same failure shape.** It is worth naming
precisely, because the three are one pattern: a guard whose *refusal* path renders as a success.
Rev 1's criteria were green before the work; rev 3's cell 3 refused the fix's own write and self-healed
next launch; rev 4's escape lets an unverified feed delete. In all three the wrong outcome is the
quiet one. That is the thing to check first in the implementation review, and it is a good candidate
for the accounts checklist §7 traps list when you update it.

---

## To clear the block

1. **A-4** — `numberOfItems` always comes from the response that produced the rows; fix `crawl():277`
   specifically, and state it as a rule rather than four call-site edits. Add a test: a refresh whose
   cached `numberOfItems` is stale still classifies a genuine full crawl as COMPLETE. *(blocker)*
2. **A-5** — split "may be written" from "may delete"; only positively-asserted completeness
   (`numberOfItems != nil && count == numberOfItems`) may remove uuids. Re-run the small test census
   for the one behavioural delta. Record the lingering-rows tradeoff. *(blocker)*
3. **B-6** — gate `requireFullCrawlOnNextRun()` on `feedIsPartial(merged)`; fix the "stays correctly
   PARTIAL" prose. *(concern)*
4. **B-7** — state that INV-2 is in-session only and `mergePartialPage` carries the durable guarantee;
   add the second-launch cell to test 3. *(concern)*
5. **B-8 / B-9 / D-6** — pin the resident read to `accountSets[hash]`; decide the fallback's
   provisional-marker behaviour; measure `/libraries`. *(warning)*

Items 1 and 2 are a rule sentence and a two-line predicate change. The ledger, the mechanism, the
shrink census, the lock composition, nil-is-complete, the removal rule, the criteria and §9 all hold
and I re-verified each this pass — none of them needs re-opening. Re-request and I will re-run C1–C13
and re-walk the escape against the launch-1 and launch-2 traces before approving.
