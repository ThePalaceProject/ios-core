# QA / test-quality review — PP-5191 (independent qa_test role)

**Branch:** `fix/PP-5191-registry-truncation-3.3.0` · **Base:** `origin/release/3.3.0`
**Commits:** 555ba957f, 615952ed4, 35882839c · **Contract:** rev6 (architect APPROVED)
Governance OFF — no MCP call, no heka verdict. This file is the verdict.
Scope: test quality only. Design was reviewed by the architect across six rounds.

## VERDICT: **BLOCKED** — 2 fail, 5 concern, 3 warning, 2 pass

The diagnosis, the fixtures and the naming are strong, and the fluff audit comes back
clean. The block is narrow and specific: **the two tests the rev-6 architect made
conditions of approval (§7 tests 16 and 17) do not test what they name.** One asserts
against a store production never writes to; the other never produces the refusal whose
gating it exists to prove. Both are green today for reasons unrelated to the code they
guard.

---

## 1. `fail` · vacuity · the S-3 state-store assertion cannot fail

`PalaceTests/Accounts/RegistryTruncationRegressionTests.swift:251-255`

`Account._setState` writes to the process-wide singleton —
`Palace/Accounts/Library/Account+State.swift:204` → `AccountStateStore.shared.setState(...)`.
The loader's injected `accountStateStore` is only ever **read**
(`AccountRegistryLoader.swift:872`). The test injects a fresh `AccountStateStore()`
(line 206), which returns `.notLoaded` for every uuid by construction.

So deleting the S-3 skip (`guard applied else { return }`, `AccountRegistryLoader.swift:849`)
and letting the `_setState` loop run for `intruder` leaves this assertion green. It is
mathematically guaranteed to pass. This is contract §7 test 17, one of two rev-6
conditions.

**Fix:** assert on `AccountStateStore.shared.state(for: uuid)`, with a per-run unique
uuid (`"intruder-\(UUID().uuidString)"` — `.shared` outlives the test, and a fixed id
invites bleed), reset it in `tearDown`, and prove red by reintroducing the loop.

## 2. `fail` · coverage · the "disk" test never produces a refusal

`PalaceTests/Accounts/RegistryTruncationRegressionTests.swift:177-197`

Traced end to end: bundled 3 → `replaceBucket` applies → bucket = 3; page 1 merges to
4 (a **superset**) → INV-2 cell 2 → `applied == true` → `guard applied`
(`AccountRegistryLoader.swift:571`) passes → disk write happens. `applied` is true at
every step, so **deleting the S-1 gate changes nothing and this test stays green.**
What it actually pins is `mergePartialPage` reaching disk, which line 164 of test 1
already asserts.

The commit body says "removing the S-1 gate fails the disk test." By this trace it
cannot — please name the exact edit that was made. If it was restoring
`writeCatalogData(firstPageData, ...)`, that removes the *merge*, not the gate.

Contract §7 test 16 — "a REFUSED write leaves the on-disk cache **byte-identical**, and
a fresh manager over that disk comes up non-short", described by the architect as *"the
test that makes INV-2 more than one session deep; without it the whole rev-6 fix is
unverified"* — is therefore unimplemented.

The refusal IS reachable at that call site: resident bucket populated while the cached
bytes are absent/unparseable (`clearCache()` sweeps files but leaves `accountSets`
resident) ⇒ `mergePartialPage` returns the bare page ⇒ INV-2 refuses. Drive that, assert
the cached blob is byte-identical to the pre-write bytes, then hydrate a fresh store off
those bytes.

## 3. `concern` · coverage · the page-1 partial-ness signal is untested end to end

Drop `numberOfItems: page.metadata.numberOfItems` at
`LibraryRegistryCrawler.swift:341-344` (`crawlFirstPage` re-serializes, so this is the
only carrier) and: the merged feed declares nil → `displayIsPartial == false`
(`AccountRegistryLoader.swift:566`) → `isCompleteFeed: true` handed to INV-2 → and
`requireFullCrawlOnNextRun()` never fires (`:578-583`). **Both** truncation tests still
pass. Nothing asserts the `if displayIsPartial` branch in either direction, i.e. contract
§7 test 15 ("NOT called when the merged feed is complete") and the drive-it-through half
of test 6 are missing. C5 is a `grep` criterion, not a behavioral one.

Needs a seam: the crawler is constructed inline at `:552`/`:582` with no
`stateDirectory`, so the reset is unobservable from a test.

## 4. `concern` · coverage · INV-2's completeness argument is supplied at 2 of 6 writers

Computed: `hydrateFullAccountSets` (`:339`) and the page-1 path (`:566`). Defaulted to
`isCompleteFeed: true` — i.e. **removals licensed unconditionally** — at
`AccountRegistryLoader.swift:622` (crawlRemainingPages success), `:647` and `:656`
(fallbackFetchFromNetwork), `:700` (refreshInBackground), `:723` (fallbackDirectRefresh).
All five also write disk unconditionally *before* the bucket write, so S-1 does not cover
them either. No test touches any of the five.

Two consequences worth a test even if the behavior is accepted as-is:

- **Vector-2 recurrence.** A short crawl (`reachedDeclaredTotal == false`,
  `LibraryRegistryCrawler.swift:428`) serializes an honestly PARTIAL feed, and the loader
  then tells INV-2 it is complete. Because `crawlRemainingPages` is passed
  `existingPublications: firstPage.catalogs` (`:614`) — page 1, not the cache — the
  merged output can be shorter than the resident bucket. The named defect recurs one path
  over.
- **Contract §7 test 14 is absent and would FAIL as implemented.** nil `numberOfItems` ⇒
  `feedIsPartial == false` ⇒ `isCompleteFeed: true` ⇒ a nil-metadata feed that removes
  uuids is applied. That is exactly the rev-5 A-5 split ("nil must not license a DELETE")
  not landing. The commit body's "Both bucket writers route through it, so it is an
  invariant rather than a patch on one caller" overstates what the diff does.

Either compute `!LibraryCatalogMerger.feedIsPartial(feed)` at each site, or add the tests
that pin today's behavior so the gap is visible rather than implied.

## 5. `concern` · mutation · V-2 asserts half its own rule

`PalaceTests/Crawl/CrawlerCompletenessTests.swift:90-111` asserts only
`lastFullCrawlDate`. `reachedDeclaredTotal` also drives `isFullCrawl:`
(`LibraryRegistryCrawler.swift:431`), and the test passes `existingPublications: []`, so
that half is unobservable: reverting to `isFullCrawl: true` **survives**. It is the
dangerous half — `isFullCrawl: true` on a short crawl deletes every existing row the
short set lacks.

**Fix:** pass an existing publication absent from the short crawl; assert it survives in
the serialized output.

## 6. `concern` · coverage · `mergePartialPage` is 2 of 5 contract cells

Covered: page ⊄ existing (`RegistryCompletenessTests.swift:75`), existing nil (`:101`),
malformed (`:107`), declared-total provenance (`:86`). Missing from contract §7 test 1:
**page updates an existing entry (newer wins)**, page ⊂ existing, and the
"existing decodes but `catalogs.isEmpty`" branch (`AccountRegistryLoader.swift:765`).

The newer-wins gap leaves a live surviving mutant: swap `existing:`/`updates:` at
`:769-772` and the union is identical, so `:75-84` stays green while the merge's
stale-bundled-row semantics invert — which is precisely the F-3 staleness vector this fix
introduced.

## 7. `concern` · isolation · an unpinned `TPPSettings()` inside the pinned suite

`RegistryTruncationRegressionTests.swift:107` —
`TPPAgeCheck(ageCheckChoiceStorage: TPPSettings())`. The suite's own setUp comment
(`:38-46`) says an unpinned `TPPSettings` both pollutes `UserDefaults.standard` and
reaches `AppContainer.production()` through the `settingsAccountIdsList` getter. Line 217
in the same file does it correctly with `settings`. Pass `settings`.

## 8. `concern` · isolation · production crawl state written to the real app-support dir

Both truncation tests reach `LibraryRegistryCrawler(fetcher:hash:)` with no
`stateDirectory` (`AccountRegistryLoader.swift:552`, `:582`), which defaults to
`.applicationSupportDirectory` (`LibraryRegistryCrawler.swift:113-121`). So the suite
writes — and `requireFullCrawlOnNextRun()` then CLEARS — `crawl_state_<prod-hash>.json`
for the **production** URL hash, in shared storage, and `tearDown` (`:49-54`) does not
remove it. Every other crawler suite pins a temp dir
(`CrawlerFallbackTests.swift:39-44`, `LibraryRegistryCrawlerTests.swift:146`). Shared
mutable state across suites is this repo's entire flake history. Add a stateDirectory
seam on the loader (which #3 needs anyway) or delete the file in tearDown.

## 9. `warning` · flake · assert-zero on a global NotificationCenter

`RegistryTruncationRegressionTests.swift:229-233, 256`. Observer on
`NotificationCenter.default`, `object: nil`, counting into an unsynchronised `var`,
asserted `== 0`. A lingering background `AccountsManager` from an earlier suite posts the
same name — the documented polluter in this repo — and reddens this suite for someone
else's work. The assertion is genuinely red-capable (the applied path posts
unconditionally at `AccountRegistryLoader.swift:905`), so keep it; scope it to the window
between two markers, or use an inverted expectation bounded by the completion.

## 10. `warning` · vacuity-by-skip · the auth-gate suite is keychain-gated

`MissingRegistryRowAuthGateTests.swift:44`. `KeychainAvailability.skipIfUnavailable()` is
a correct throwing `XCTSkip` (not the bare-XCTSkip trap), and CI's test host has been
ad-hoc signed since b57b3af43, so this should not fire today. But it is the **only**
coverage of a critical-path auth gate, and a skip renders as a pass with nothing
asserting it did not happen. After the re-run, confirm from the result bundle that all
four cells **executed**, not merely "did not fail".

## 11. `warning` · dead premise machinery

`ScriptedFetcher.failedPageRequests` (`RegistryTruncationRegressionTests.swift:275`) is
now unused. Delete it so the flapping premise cannot be reintroduced by a later reader
who finds it sitting there.

## 12. `pass` · fluff / tautology audit: clean, 25/25

No banned pattern in the diff: no constructor-not-nil, no enum-raw-value, no
`XCTAssertTrue(x is T)`, no toggle-a-bool, no assert-initial-state, no coverage-only
test. Every assertion I traced except finding 1 has a production line whose mutation
flips it.

Closest call, accepted:
`MissingRegistryRowAuthGateTests.swift:66-71` `XCTAssertEqual(currentAccountId, libraryUUID)`
is formally set-then-assert, but it is a premise guard that pins that `AccountsManager`
reads the **injected** defaults — without it, the two credential cells could pass from a
different account's keychain. Keep the `testPremise_` prefix; never count it as coverage.

By design (not defects): the two no-credentials cells survive the original defect —
they are the monotonicity guards and they kill the `return true` mutant, which is the
right pairing.

## 13. `pass` · fixture and premise hygiene is the strongest in this repo

`assertFixtureDecodes` (`:88-92`) with the recorded first-fixture failure (`:58-64`)
directly closes the "fixture does not decode ⇒ the test fails looking exactly like the
production defect" class. Replacing the racy `failedPageRequests > 0` premise with the
synchronously-recorded cache-write trace (`:161-165`) is the right correction.

I re-checked the remaining premise assertions for the same defect and they are clean —
`cache.writes.first?.count == 3` (ordered, same task), the seeding assert at
`RegistryCompletenessTests.swift:116`, and the `guard case .success` guards at
`CrawlerCompletenessTests.swift:78, 105`. **None depends on a background task having
started.**

---

## Coverage tables, enumerated rather than sampled

**INV-2 (`replaceBucket`) — resident × completeness × removes**

| resident | complete? | removes? | test | status |
|---|---|---|---|---|
| empty | true | — | `store(seeded:)` assert, `RegistryCompletenessTests.swift:116` | ✅ |
| empty | false | — | `:121` | ✅ |
| non-empty | false | no (superset) | `:128` | ✅ |
| non-empty | false | yes (subset) | `:137` | ✅ |
| non-empty | false | yes (same count, swap) | `:154` | ✅ |
| non-empty | true | yes | `:145` | ✅ |
| non-empty | true | no | — | gap, trivial |
| other hash resident | false | — | `:161` | ✅ |
| **called on the launch thread via `hydrateFullAccountSets:339`** | — | — | no new test | gap — relies on `AccountsManagerCacheReadTests` / `…LaunchSnapshotTests`; confirm both green in the full run (a recursive-wrlock regression here hangs, it does not fail) |

**`mergePartialPage` — see finding 6.** 2 of 5 contract cells; newer-wins missing ⇒ live
surviving mutant.

**Crawler `numberOfItems` rule — 4 serialize sites**

| site | test |
|---|---|
| `crawl():280` (deletion reconcile) | ✅ `CrawlerCompletenessTests.swift:67` — asserts the emitted total AND `feedIsPartial == false` |
| `crawlFirstPage:341` | ❌ finding 3 — dropping it passes every test |
| `crawlRemainingPages:381` (single-page branch) | ❌ unreachable from `fetchFromNetwork` (it breaks at `:600`), but untested |
| `crawlRemainingPages:441` | ❌ the V-2 test asserts only `lastFullCrawlDate`, never the emitted metadata |

**Contract §7 rows with no test in this diff:** 1 (partially — 2 of 5 cells), 3 (the F-2
incremental cell **and** the rev-6 S-6 slim second-launch cell, which rev6 marked
*"test defect, MUST fix"* — absent entirely), 11, 14, 15, 16, 17 (vacuous).

---

## What I could not evaluate

- **Measured test outcomes.** Mutation is recorded only for `AccountRegistryStore`
  (3/3 killed, baseline PASS); the other three files' runs were interrupted. Every
  survivor named above is derived by reading, not measured — findings 3, 5 and 6 are
  concrete predictions worth confirming with `palace_mutate.py --diff-only` on
  `AccountRegistryLoader.swift` and `LibraryRegistryCrawler.swift`.
- **Full-suite interaction.** Findings 7, 8 and 9 are pollution *vectors*, not observed
  failures; I did not run `find-test-polluter.sh`.
- **Design.** Findings 4 and part of 3 touch behavior the architect approved in prose. I
  raise them as coverage gaps — the tests the contract requires for those rules are
  missing, and test 14 would fail as written today.

## To unblock

1 and 2 are mandatory (both are rev-6 approval conditions and both are currently inert).
3–6 need either a test or an explicit, recorded deferral with the reachability named.
7 and 8 are two-line changes. 9–11 at the author's discretion.

Re-review on the amended tree; per the amend-invalidates-approval rule, this verdict
binds to the tip reviewed (35882839c).

---
---

# Round 2 — re-review of the rebuilt tip

**Tip:** 8f4576a59 (555ba957f gates · 9a70f2b1d registry · 8f4576a59 bump) ·
**Base:** `origin/release/3.3.0` @ bbf5a5b00 · never pushed.

## VERDICT: **BLOCKED** — one mandatory finding (A), one strong (B), rest accepted

Round-1 findings 1, 3, 5, 6, 7, 11 are **properly fixed** and I verified each is now
red-capable by tracing the mutation it is supposed to catch. Finding 2 was handled
honestly and that is the right instinct — the reasoning is 90% correct and I am flagging
the remaining 10% because, as written, it invites a future reader to delete a live guard.
Finding 4's predicate split is correct and is the most valuable thing in this revision.

The block is a **new** finding, adjacent to finding 4 and of the same shape: the
changeset's vector-2 post-condition now detects a short crawl correctly, and the caller
discards the finding.

---

## A. `fail` · `crawlRemainingPages` clobbers the merge the fix just protected

`Palace/Accounts/Library/AccountRegistryLoader.swift:611-628`

Field sequence, cold launch, every registry with more than one page — i.e. always:

1. bundled 1142 → bucket + disk (`:527`)
2. page 1 (100, declares 1457) → merged **1242** → bucket (superset, applied) + disk,
   `requireFullCrawlOnNextRun()` (`:568-598`) — **the fix working**
3. `crawlRemainingPages` returns, seconds later (`:611-628`)

Step 3 undoes step 2 whenever the walk ends short of the declared total:

- the merge base is `existingPublications: firstPage.catalogs` (`:614`) — **page 1, not
  the 1242-row cache** — so the output cannot contain the bundled-only libraries;
- `writeCatalogData(fullData, hash:)` at `:626` is **unconditional** — no
  `didApplyBucketWrite` gate, unlike the path 20 lines above it;
- `loadAccountSetsAndAuthDoc(fromCatalogData: fullData, key: hash)` at `:627` passes
  **no** `isCompleteFeed`, so it takes the `= true` default (`:814`) and INV-2 licenses
  the removal.

So `reachedDeclaredTotal` (`LibraryRegistryCrawler.swift:428`) correctly detects the
short crawl, correctly declines to stamp `lastFullCrawlDate`, correctly merges with
`isFullCrawl: false` — and then **the label has no consumer.** The loader deletes the
libraries anyway, on both disk and bucket, in the same session. Resident 1242 → 400,
patron's library gone, `currentAccount` nil: PP-5191 verbatim, one call site over.

This is the canon entry of this very changeset —
*a guard whose refusal renders as success* — in its post-condition form.

**Fix (mirrors `:568-590`, which is already written and tested):** derive
`isCompleteFeed` from `fullData` via `feedIsPositivelyComplete` and gate the cache write
on the applied signal.

**Test:** the harness is already in the file — `ScriptedFetcher` serving page-1-with-next
plus a short page 2; assert `patron-library` survives both the bucket and
`cache.lastWrittenData`. It is the existing regression test with one more scripted page.

## A2. `concern` · the A-5 comment names two call sites that never call the predicate

`LibraryCatalogMerger.feedIsPositivelyComplete`'s doc comment states: *"The reachable
difference is `fallbackFetchFromNetwork` / `fallbackDirectRefresh`, which GET the
non-crawlable `/libraries`"* — and
`RegistryCompletenessTests.swift:172` repeats it in an assertion message
(*"hands delete authority to the direct-GET recovery endpoint"*).

Neither of those paths calls it. `fallbackFetchFromNetwork` (`:652`, `:661`) and
`fallbackDirectRefresh` (`:731`) reach `replaceBucket` through the
`isCompleteFeed: Bool = true` default and are **still licensed to delete** on a
nil-`numberOfItems` response — which is the measured shape of `/libraries` (1457
catalogs, no total) on the path that runs precisely when the network is misbehaving.

The predicate is consulted at 2 of 8 bucket-write entry points: `hydrateFullAccountSets`
(`:344`) and the page-1 path (`:575-580`). The four new tests pin the rule where it is
consulted — they are good tests — but the integration claim in their prose is not true
yet. The unit test proves the predicate would refuse *if asked*; production does not ask.

**One two-line change closes A and A2 together.** `loadAccountSetsAndAuthDoc` already
decodes the feed at `:813`. Make the parameter `isCompleteFeed: Bool? = nil` and default
to `LibraryCatalogMerger.feedIsPositivelyComplete(feed)`. I checked all seven callers:

| caller | derived value | effect |
|---|---|---|
| `:502` disk cache (path 2) | legacy ⇒ false | resident is empty here (path 1 returns early otherwise) ⇒ cell 1 accepts. No change. |
| `:527` bundled | 1142/1142 ⇒ true | no change |
| `:580` page 1 | already explicit | no change |
| `:627` crawlRemainingPages | computed | **closes A** |
| `:652`/`:731` direct GET | nil ⇒ false | **closes A2** — may ADD, may not DELETE |
| `:661` cached fallback | false | resident is same-or-superset ⇒ accepts |
| `:706` refreshInBackground | fresh total from `crawl()` | a genuine 1457→1400 reconcile is 1400/1400 ⇒ **true ⇒ applied** — this is what makes `CrawlerCompletenessTests.swift:67`'s claim true end to end |

If you would rather not move behavior on six call sites this close to the deadline, that
is a defensible call — but then the comment and the assertion message must stop naming
them, and the deferral must be recorded. Either direction is fine; the claim and the code
disagreeing is not.

## B. `concern` · "structurally unreachable" overstates, and invites deleting the gate

`PalaceTests/Accounts/RegistryTruncationRegressionTests.swift:188-209`

Stopping and establishing *why* the test could not fail — instead of a third attempt at
making it pass — is exactly right, and the record of both failed attempts is the most
useful paragraph in the suite. Fact 1 (path 1 returns early at `:486`, so
`fetchFromNetwork` requires an empty bucket) is correct and decisive.

Fact 2 is not quite. "The merged page-1 feed is a SUPERSET of it" holds only while the
**bundled cache write succeeds**: `mergePartialPage` reads the base from **disk**
(`readCatalogData`, `:570`), not from the store. If that write does not stick — disk
full, a sandbox error, or `clearFileCaches()` racing a library switch — the bucket holds
1142 while `existingData` is nil, `displayData` is the bare 100-row page, and INV-2
**refuses**. That is precisely the disk/bucket divergence the gate exists for, and it is
reachable in the field.

It is also constructible today in three lines with the double already in the file: an
`InMemoryRegistryCache` that accepts but drops `isBundled: true` writes. That is contract
§7 test 16, and the recipe is now known.

**Minimum:** change "INV-2 **cannot refuse** at that call site" to "cannot refuse *while
the cache write succeeds*", and name the failed-write cell. As written, the next person
doing dead-code cleanup has a documented licence to delete a live guard.
**Preferred:** write the test; you are three lines from it.

## C. `warning` · two leftovers from the abandoned attempt

- `registryHashForCurrentConfiguration()` (`:58-68`) is now called from nowhere. It is
  also exactly what finding 8's tearDown needs — see D.
- `XCTAssertNotNil(appliedSignal)` (`:267-268`) cannot fail when the
  `XCTAssertEqual(appliedSignal, false)` immediately above it passes; `nil` fails both.
  The message is worth keeping, the assertion is not.

## D. Ruling on finding 8 (asked for explicitly): **deferral, not a blocker**

Every other crawler suite pins its own `stateDirectory`
(`CrawlerFallbackTests.swift:39-44`, `LibraryRegistryCrawlerTests.swift:146`), so nothing
in the suite today reads the production `crawl_state_<prod-hash>.json` this file writes
and clears. The blast radius is CI/dev residue plus a trap for the next person who adds a
loader-driven test. That does not justify holding a release fix.

Cheap ask, not a condition: delete the file in `tearDown` with the helper from C, and put
one line in the file header saying the loader has no state-directory seam so the next
author knows before they discover it.

## E. Contract test 3 (F-2 / S-6): accepted as deferred, with one sentence owed

Shipping without it is reasonable at this point. But the F-2 cell is the claim *"an
incremental refresh does not re-shorten a merged bucket"* — and **finding A is a live
instance of that exact claim failing on the sibling path**. The deferral should say so,
so the gap is recorded as "unverified, and here is the one we found by reading" rather
than as an enumeration chore.

## Re-verified as fixed (each traced to the mutation it now catches)

| round-1 | status | why it is now red-capable |
|---|---|---|
| 1 · S-3 vacuous | ✅ | asserts `AccountStateStore.shared` with a per-run uuid; the loader now reads and writes the same store, so restoring the `_setState` loop flips `.notLoaded` → `.basicInfoLoaded` and fails |
| 2 · disk test | ✅ withdrawn honestly | see B for the residue |
| 3 · declared total | ✅ | `testCrawlFirstPage_carriesTheDeclaredTotalThroughSerialization` — dropping the field at `LibraryRegistryCrawler.swift:341` now fails by name |
| 4 · A-5 split | ◑ | predicate + 4 tests correct; integration half open → A2 |
| 5 · V-2 half-asserted | ✅ | non-empty `existingPublications` + superset assert; `isFullCrawl: true` now deletes `resident-1/2` and fails |
| 6 · newer-wins | ✅ | swapping the merge arguments now keeps `"OLD NAME"` and fails |
| 7 · unpinned `TPPSettings` | ✅ | both loaders take the pinned instance |
| 10 · skip-as-pass | ✅ | "0 skips" answers it — the keychain gate did not fire |
| 11 · dead premise field | ✅ | deleted |
| 9 · global notification observer | accepted as warning | unchanged; still a cross-suite flake vector, still red-capable |

## Still unmeasured

Mutation for `AccountRegistryLoader`, `LibraryCatalogMerger` and
`LibraryRegistryCrawler` is in flight. **A and B are read-derived**, like round 1's
findings 2 and 4 were — both of which held. A diff-only run over the loader should show
`:626-627` as an uncovered region; if it does not, the harness is scoping too narrowly.

## To unblock

**A** (with A2 folded in, if you take the two-line option). **B** at minimum as a comment
correction. C, D, E at your discretion. Re-review on the amended tip — this verdict binds
to 8f4576a59.
