# Architect post-review — PP-5191 fix-contract **rev 3**

**Branch:** `fix/PP-5191-registry-truncation` · **Worktree:** `/Users/mauricework/PalaceProject/wt-5191`
**Base verified:** `HEAD` → `ea61dd998` · **Reviewer:** architect (independent) · 2026-09-21
ForgeOS OFF — no MCP call, no signed verdict.

## VERDICT: **BLOCKED** — one blocker, and it is the one you asked about in (a). It is worse than the case you named.

B-1, B-2 and B-3 are genuinely closed, and closed with the right reasoning — you re-derived the
fixture claim rather than taking mine, which is the correct instinct. I re-ran the four new/changed
criteria on `ea61dd998`: **C7 `0`, C8 `0`, C13 `0`, C14 `0`** — all red as stated. Build numbers
re-read from the actual refs: `origin/develop` = `CURRENT_PROJECT_VERSION 498 / MARKETING_VERSION 3.4.0`,
`origin/release/3.3.0` = `508 / 3.3.0`. Your §9 numbers are correct.

The block is that the four-cell table is **not monotone in information**, and the first casualty is
not the case you asked about — it is the fix's own primary write.

---

## (a) The `PARTIAL → PARTIAL ⇒ ACCEPT` cell — **yes, and there is a worse cell above it**

### A-1 (BLOCKER) — cell 3 refuses the fix's own merged write, on the main success path

Trace path 3 with rev 3 fully implemented:

1. `:504-508` bundled snapshot → 1142 catalogs, `numberOfItems: 1142` (verified in the file) ⇒
   `feedIsPartial` = **false** ⇒ `replaceBucket` ACCEPTs. **Resident = COMPLETE(1142).**
2. `:515` → `fetchFromNetwork` → `:542` page 1 succeeds → `mergePartialPage(page1, into: cached)`
   → ~1242 rows, and per rev 3 it emits **the network page's** `numberOfItems: 1457` ⇒
   `feedIsPartial` = **true** ⇒ incoming PARTIAL.
3. Table row 3: resident COMPLETE + incoming PARTIAL ⇒ **REFUSE.**

So the merged 1242-row feed — strictly a *superset* of the resident 1142 and the whole point of the
change — is rejected by the invariant the change introduces. Consequences: disk holds 1242, memory
holds 1142, and the 100 rows that page 1 exists to deliver (the **most-recently-modified** libraries,
i.e. exactly the rows whose catalog URL or logo just changed) never reach `accountSets` this session.
It self-heals on the next launch (preload reads 1242 into an empty bucket ⇒ ACCEPT), so it would ship
green and present as "the fix works, just a day late."

Note the inversion underneath it: the bundled snapshot is COMPLETE by the predicate (1142 == 1142)
even though it is a build-time artifact that may be months stale. "Complete" correctly means
"not truncated" — but combined with cell 3 it makes a stale-but-whole feed outrank every fresh
partial one, forever.

### A-2 (BLOCKER) — and yes, your asked case loses libraries

`PARTIAL(1242) ← PARTIAL(100)` ⇒ ACCEPT ⇒ 1142 libraries gone. The table has no size term, so a
smaller partial silently replaces a larger one. Two reachable producers, both created by this
changeset:

- **Your own vector-2 fix.** §"shrink sites" item 2 now says a short parallel crawl "serialize[s] as
  partial". A crawl that returns 800 of 1457 is PARTIAL; resident merged is PARTIAL(1242);
  cell 2 ACCEPTs ⇒ 442 libraries lost. The fix for vector 2 routes directly into this hole.
- **`mergePartialPage`'s `existing == nil` cell** (§7.1) passes the bare page through ⇒ PARTIAL(100).
  Reachable when `readCatalogData` returns nil while the bucket is populated — e.g. `clearCache()`
  (user-reachable from Settings) sweeps the files via `clearFileCaches()` but leaves `accountSets`
  resident (`AccountsManager.swift:786-792`). Today that lands on cell 3 and is refused by luck; one
  ordering change and it is cell 2.

### A-3 — the fix: make the invariant about information LOSS, not about the label

Replace all four cells with one rule:

> **INV-2.** A write is REFUSED iff it would **remove** uuids the resident bucket holds, **unless**
> the incoming feed is COMPLETE (a complete feed is authoritative, so its deletions are real).

Check it against every cell:

| case | old table | new rule | right? |
|---|---|---|---|
| resident absent/empty | ACCEPT | removes nothing ⇒ ACCEPT | ✓ |
| COMPLETE(1142) ← merged PARTIAL(1242 ⊇ 1142) | **REFUSE** ✗ | removes nothing ⇒ **ACCEPT** | ✓ fixes A-1 |
| PARTIAL(1242) ← PARTIAL(100 ⊂ 1242) | **ACCEPT** ✗ | removes 1142 ⇒ **REFUSE** | ✓ fixes A-2 |
| COMPLETE(1142) ← page-1 PARTIAL(100) | REFUSE | removes 1042 ⇒ REFUSE | ✓ the original bug |
| COMPLETE ← COMPLETE(N−3), real deletion | ACCEPT | incoming COMPLETE ⇒ ACCEPT | ✓ |

It is strictly simpler than what rev 3 proposes, and it **deletes state**: with a superset test you
no longer need the per-hash `bucketIsPartial: [String: Bool]` map, so the `clearCache` / hash-switch
semantics for that map stop needing definition, and the critical section shrinks. (C14 then has to
change — see D-2.)

**Cost, since I was the one who raised the launch-window concern:** building a `Set<String>` of ~1242
uuids and testing ~1457 memberships, inside the existing `accountSetsLock.write`. That is the same
order as the `buildAccountIndex` rebuild the lock already performs on every `mutate` over *all*
buckets. No new order of magnitude, same critical section, and `hydrateFullAccountSets:322` already
has the decoded feed. **Acceptable at launch.** Do *not* substitute `incoming.count >= resident.count`
as a cheap proxy — it is wrong under churn (100 added + 100 removed passes while losing 100).

**Also required:** when a write is REFUSED, say what happens to the *disk*. Right now the cache write
(`:543`) precedes the bucket write, so a refused bucket still leaves the short bytes on disk to be
loaded next launch. Either write the cache only after `replaceBucket` reports applied, or state
explicitly that disk may lead memory by one launch and why that is safe.

---

## (b) Where `feedIsPartial` belongs — **not the loader. Put it on `LibraryCatalogMerger`.**

You are right to be suspicious of the loader. The loader is the orchestrator; the store is *below*
it (the loader already depends on the store, `AccountRegistryLoader.swift:72`). Defining the store's
invariant in the store's own consumer inverts that edge, and both types are headed into the
`PalaceAccounts` package, where the inversion becomes a package-surface problem rather than a style one.

`LibraryCatalogMerger` is the right home, and the case is not close:

- It is already an `enum` namespace of pure statics over exactly this data — `merge(existing:updates:isFullCrawl:)`
  and `serializeAsCatalogsFeed(publications:metadata:)`.
- It sits below both the loader and the store, so the store can call it without inverting anything.
- **It is already being edited by this changeset** to carry `numberOfItems` through serialization.
  Putting the *producer* of that field and the *interpreter* of that field in one file is what makes
  the emit/interpret contract reviewable in a single diff — and that contract is precisely where A-1
  went wrong.
- It already has a test target in your Acceptance list (`PalaceTests/Crawl/LibraryCatalogMergerTests.swift`).

Do **not** put it on `OPDS2CatalogsFeed.Metadata` in `PalaceCatalog`: "count vs numberOfItems means
truncated" is a registry-crawl concept, not an OPDS2 one, and it would widen a package's public
surface for an app-layer invariant.

### B-1 (BLOCKER-adjacent, must be resolved either way) — rev 3 contradicts itself on the signature, and the parameter cannot actually be removed

Three statements in rev 3 disagree:

- §4 table (line 101): `replaceBucket(hash:accounts:isCompleteFeed:)` — parameter present.
- §"Single producer" (lines 130-132): "The `isCompleteFeed:` parameter of rev 2 is removed."
- §"Lock composition" (line 181): `replaceBucket` "reads the resident bucket + its completeness" and
  updates `bucketIsPartial`.

The decisive fact: **`replaceBucket` receives `[Account]`, not feed bytes.** `Account` carries no
`metadata.numberOfItems`. The store therefore *cannot* re-derive partialness and the parameter must
exist. Reinstate it.

And you over-corrected my B-3. A parameter is **not** a second source of truth when exactly one
function computes it — rev 2's defect was that INV-2 was defined *twice*, once as a byte predicate and
once as a caller-supplied bool, with nothing forcing them to agree. One `LibraryCatalogMerger.feedIsPartial`,
called by each writer on the bytes it is committing, result passed down as a parameter, is one source
of truth with a transport. Say it that way.

C13 then greps `LibraryCatalogMerger.swift`, not the loader.

---

## (c) §9 Release plan — **"no bump on develop" is CORRECT. Two gaps, neither blocking.**

I re-read the refs rather than the contract: develop `498 / 3.4.0`, release/3.3.0 `508 / 3.3.0`.
Both as stated. And 3.3.0 is demonstrably still an open, moving line (builds 505, 506 landed on it
recently), so porting into it is not the "never cherry-pick onto a shipped release branch" case.

**No bump on develop is right.** A merge into develop uploads nothing; minting a build number there
would consume a number from the one global sequence for a build that never exists. Correct call.

**C-1 (concern) — the direction is backwards relative to this repo's own established pattern.** §9
proposes develop-first, then a `-3.3.0` port. The repo does the opposite, and the evidence is the
branch pair this very tree was cut from:

    fix/PP-2677-sideload-toggle-3.3.0        → cd3916213  "…, build 506 (PP-2677)"
    fix/PP-2677-sideload-toggle-develop-port → 79bb81313  "…(PP-2677, develop port)"
    merged: 71b7183b1 (#1490)  then  ea61dd998 (#1491)   — both MERGE commits, not squashes

Same for `fix/PP-5135-develop-port`, `fix/PP-5134-develop-port`. Release-branch-first, then a
`-develop-port` branch, both merged with merge commits. Release-first is also the safer order here:
the 3.3.0 branch is the one with a ship deadline, and authoring there first guarantees the two lines
carry the same implementation rather than a re-typed one. **Recommend flipping §9 and renaming the
second branch `fix/PP-5191-registry-truncation-develop-port` to match convention.**

**C-2 (concern) — §9 does not state merge mode, and that is the one lever with a 296-conflict precedent
in this repo.** Anything that feeds `main` must merge with `gh pr merge --merge`, never `--squash`
(CLAUDE.md "Release & hotfix merge policy"; the 3.1.0 forensic). `release/3.3.0 → main` will carry
this fix, and `develop → release/3.4.0 → main` will carry a logically-identical change with a
different SHA — which is survivable *only* because both sides are merge commits. Write the merge
mode into §9 explicitly; the existing PRs got it right by habit and habit is not a plan.

**C-3 (warning) — the sequence you asked me to check has a double-bookable window, and §9 is silent on it.**
After the port the 3.3.0 line stands at **509** while develop stands at **498**. The next build minted
on the 3.4.0 line will be **499** — inside the `499…509` range the 3.3.0 line has already consumed.
Per the recorded incident (3.2.4 reused 493 — *"check the SEQUENCE, not the filename"*), that is the
exact failure mode. This is **pre-existing**, not created by this changeset, and §9 is right not to
bump develop here. But a section titled "Release plan" should name it: *when the 3.4.0 line next
produces a build, `CURRENT_PROJECT_VERSION` on develop must be raised past the global high-water
(≥ 510), not incremented from 498* — and name who owns that. Also add the forward-port step itself:
CLAUDE.md requires release-branch work to be forward-ported into develop so the next release branch
absorbs it with original SHAs; §9 currently has two independent landings and no forward-port.

---

## Remaining items

**D-1 (warning) — C7/C8 are better, but still coupled to a name inside a 2-line window.** Verified:
both are `0` on develop, and `-A2` spans exactly `return false` + `}`. But a correct fix that extracts
the arm — the shape PP-5135 itself used, `Self.offlineAuthFallback(...)` — puts `hasCredentials` in the
helper, outside the window, and C7/C8 fail a correct fix. Line-adjacency anchors are brittle for
exactly this reason. **Use the negative form instead:** `grep -A2 "<guard>" <file> | grep -c "return false"`
must be `0` (today: `1` for both — still red, and implementation-agnostic). Keep §7.7/§7.8 as the real gate.

**D-2 (warning) — C14 must follow A-3.** If you adopt the uuid-superset rule, `bucketIsPartial` ceases
to exist and C14 (`grep -c bucketIsPartial …Store.swift` ≥2) becomes a criterion for state the design
no longer has. Re-anchor it on `replaceBucket`'s refusal path (e.g. `grep -c "INV-2" …Store.swift` ≥1
already covers it via C6) or delete it.

**D-3 (nit) — Acceptance §8 still reads "All C1-C12 pass"** after C13/C14 were added. Say C1–C14.

**D-4 (pass) — §7 test 9, 10, 11, 12 are the right four.** Test 11 (legacy-cache upgrade) in particular
is the one that would have caught the 100%-of-installs regression, and it is stated as a behaviour, not
a shape. Test 12 correctly pins `orderModifiedFacetURL` surviving the clear. Good.

**D-5 (pass) — ledger row 4** is now correct, and withdrawing the `buildAccountIndex` inference *in-line*
rather than silently deleting it is the right call — the next reader sees why a true fact was the wrong
argument. That is the standard I want on the other rows too.

---

## To clear the block

1. **A-3** — replace the four-cell table with the no-uuid-removal rule; re-verify it against the five
   cases above; state what happens to the disk write on refusal. Add tests for (i) merged superset over
   a COMPLETE resident is ACCEPTED, (ii) a smaller partial over a larger partial is REFUSED. *(blocker)*
2. **B-1** — reinstate the completeness parameter (the store holds `[Account]` and cannot derive it),
   and reconcile lines 101 / 130-132 / 181 into one statement. *(blocker)*
3. **(b)** — move `feedIsPartial` to `LibraryCatalogMerger`; re-point C13. *(concern)*
4. **C-1 / C-2 / C-3** — flip §9 to release-first with a `-develop-port` branch, state `--merge` for
   anything feeding main, add the forward-port step, and name the 499…509 window + its owner. *(concern)*
5. **D-1 / D-2 / D-3** — re-anchor C7/C8 on `return false` absence; re-anchor or drop C14; fix the
   Acceptance range. *(warning)*

Item 1 is a table swap and item 2 is a three-line reconciliation. Nothing in the diagnosis, the ledger,
the shrink census, the lock composition, or the nil-is-complete rule needs re-opening — I re-verified
each of those this pass and they hold. Re-request and I will re-run C1–C14 and walk the new invariant
against the five cases before approving.
