# Architect post-review — PP-5191 fix-contract **rev 5**

**Branch:** `fix/PP-5191-registry-truncation` · **Base:** `ea61dd998` · 2026-09-21
ForgeOS OFF — no MCP call, no signed verdict.

## VERDICT: **BLOCKED** — one blocker, found by asking (b) against the whole contract

A-4 and A-5 are closed correctly, and closed with measurement (`/libraries` → 1457 rows, no
`numberOfItems` — thank you for curling it rather than accepting my assumption). B-6/B-7/B-8/B-9
are closed. The rule form for A-4 is the right form.

The block is the answer to your own question (b): **there is a fifth instance, it is load-bearing,
and I raised it in rev 3 and it has not been answered in rev 4 or rev 5.** There is also a sixth
instance in the report you just sent me. Details below, in the order you asked.

---

## (a) Is the detector scoped right?

### First, the finding that matters more than the scoping question

    $ ls scripts/check-contract-criteria-red.py
    ls: scripts/check-contract-criteria-red.py: No such file or directory
    $ find . -maxdepth 4 -name 'check-contract-criteria-red.py'    → (nothing)

**The detector does not exist anywhere in the tree.**

The wall entry is honest about this — `wall_status: open`, and the Application log says *"detector
not yet written."* Your message to me was not: *"The permanent artifact **is** a detector,
`scripts/check-contract-criteria-red.py`, which re-executes every verification criterion … that
**makes** instance 1 structurally impossible."* Present tense, as an accomplished fact, for a file
that does not exist.

That is **instance #5 of the pattern, inside the report about the pattern**: an unwritten gate
renders, in the summary, as a gate that exists and passes. It is also the harness's
`never-narrate-an-action-you-have-not-taken` rule verbatim. I am not scolding — you asked me to ask
the question once more against the whole contract, and the most valuable place it landed was the
paragraph describing the fix for it. Restate it as *proposed*, keep `wall_status: open`, and let the
Application log stay the source of truth. The wall entry already does this correctly; only the
narration drifted.

### The scoping question, answered

**Re-execution is strictly stronger. The recorded column is not a gate at all.**

A recorded "Observed on base-ref" value is an assertion by the same author who wrote the criterion —
which is precisely the trust relationship that produced rev 1's three already-green criteria. The
column is *evidence for a reader*; the re-execution is the *gate*. Your framing — "one gate that
always runs beats one that half-runs" — is right, and it resolves the opposite way from your
suggestion: **re-execution is the one that always runs**; the recorded column is the one that
half-runs, because its reliability is exactly the author diligence that failed four times. Keep
both (the column is cheap and it makes the contract readable), but the column is documentation.

**Scope of what it checks: correct.** Grep-shaped only is the right boundary — "already satisfied"
is mechanically decidable only there. Extending to test-shaped criteria ("test 2 must fail on
develop") means running a suite against the base ref: slow, flake-exposed, and it would get disabled,
which is worse than not having it. Good call to exclude, and worth writing the exclusion *reason*
into the script's header so the next person doesn't "finish" it.

**Three requirements, or the detector becomes instance #6:**

1. **Cannot-evaluate must FAIL, never skip.** Unparseable row, unresolvable base ref, file absent at
   the base ref, a criterion that isn't grep-shaped — each must exit non-zero with a named reason.
   Note the house pattern it will be dropped into: `scripts/verify-pr.sh:846` does
   `record "committed_signing" "skip" "…not found"`. A skip-when-absent for *this* detector is the
   very failure it exists to prevent. Make the presence of `.forgeos/changesets/*/fix-contract.md`
   make the leg **mandatory** — contract present + detector absent ⇒ fail, not skip.
2. **It belongs in `~/harness`, not `scripts/`.** It parses `.forgeos/changesets/**`, which is
   governance substrate. CLAUDE.local.md constraint #8 is explicit that anything referencing forge /
   the governance stack lives in `~/harness` and never in `ios-core`, with closed PR #1351 as the
   precedent — and `verify-pr.sh` is named there as the *harness-free* leg any contributor can run
   unaided. The wall entry's "wire into `scripts/verify-pr.sh` and `tooling-checks.yml`" would
   reverse that decision. Wire it into the harness hooks instead, and **add it to
   `~/harness/bin/install`** or it reaches one checkout and silently no-ops in every other — the
   36-of-41-worktrees audit is the recorded cost of skipping that step.
3. **CLAUDE.md #4 in full:** a pytest, an end-to-end wiring test that includes a
   **clean-contract-passes** assertion (a detector invoked with an interface it rejects must not
   block), and a dry-run over the existing `.forgeos/changesets/*` for zero false positives. Don't
   land it faster than you can verify it.

**One free strengthening:** the same machinery answers the converse. Red-on-base proves the criterion
*could* fail; **green-on-tip** proves the work happened. Assert both in one pass — it costs one more
grep per row and closes "criterion was red, still red, nobody noticed."

**On the location of the wall entry itself (warning):** `.harness/wall-failures/` is gitignored
(`.git/info/exclude:58`). This repo's established, **tracked** location is `.forgeos/wall-failures/`
— 40 entries, and the one this review brief points reviewers at. A canon entry in a 41st location
that no reader's tooling looks at is a doc that will not be maintained, which CLAUDE.md says is worse
than none. Either move it to `.forgeos/wall-failures/` or make the readers point at `.harness/`.

---

## (b) Where a refusal, an early return, or a skipped call still renders as success

Swept the whole contract and the code it names. Six, one of them a blocker.

### S-1 (BLOCKER) — the disk write is unconditional and precedes the bucket write, so **every INV-2 refusal is undone at the next launch**

This is the rev-3 question ("when a write is REFUSED, say what happens to the *disk*") that rev 4 and
rev 5 did not answer. It has now become load-bearing, because rev 5's two new rules both depend on
refusals sticking.

Order in every writer, unchanged by the contract:

    :543  writeCatalogData(merged, hash)          ← disk, unconditional
    :544  loadAccountSetsAndAuthDoc(merged, hash) ← bucket, INV-2 applies here
    :649/:650, :595/:596, :674/:675               ← same order

Combine with **B-7**, which rev 5 states plainly and correctly: the resident bucket is empty on the
first write of any launch, so INV-2 cannot fire there. The consequence is not stated:

    session N   : incoming would remove uuids ⇒ INV-2 REFUSES  ⇒ bucket protected ✓
                  …but the short bytes are already on disk
    session N+1 : preload hydrates those bytes into an EMPTY bucket ⇒ cell 1 ⇒ ACCEPT ⇒ short

**INV-2 is exactly one session deep, and the refusal is silent in both directions** — the user sees a
normal launch, and nothing distinguishes "we refused and then installed it anyway" from "nothing
happened". It defeats A-5 specifically: the nil-metadata direct-GET write you just stopped from
deleting in memory still lands on disk (`:595`, `:674`) and is hydrated unopposed next launch.

Rev 5 says *"the durable, across-launch guarantee is `mergePartialPage` writing a superset to disk"*
— true on the page-1 path, but it does not cover the other two disk writers that can shrink:
`crawlRemainingPages`' short-crawl result (`:570`) and the direct-GET fallbacks (`:595`, `:674`).

**Fix, and it uses the return value the contract already defines:** commit to memory first and write
bytes only if `replaceBucket` applied. `replaceBucket` already returns whether it applied; make the
cache write its consumer. A crash between the two loses the bytes, which is harmless — the next
launch re-fetches. Add a test: a REFUSED write leaves the **on-disk cache** unchanged, and a fresh
manager over that disk state still comes up non-short. (This is also the honest completion of test
3's new second-launch cell.)

### S-2 (concern) — `replaceBucket`'s return value has no stated consumer

The contract says it "returns whether it applied", then says the caller completes `true` regardless.
If nothing reads it, the refusal is invisible at the API boundary and a `@discardableResult` will
appear within one refactor. S-1 gives it a consumer; say so explicitly, and add the `Log.error` with
both operand counts on the refusal path (the contract already promises that log for the *applied*
large-removal case — the refused case needs it more).

### S-3 (concern) — on refusal, the rest of `loadAccountSetsAndAuthDoc` still runs

The bucket write at `:735` is followed by the state-machine loop at `:737-744`, then `loadLogo` +
the auth-doc drive at `:751-766`, then `.TPPCurrentAccountDidChange` at `:781`. If `replaceBucket`
refuses, those still execute against `newAccounts` that never entered the bucket — so
`AccountStateStore` ends up holding `.basicInfoLoaded` for uuids that `account(uuid)` cannot resolve,
and a `.TPPCurrentAccountDidChange` fires for a change that did not happen. The refusal does not
fully refuse. State what happens on that path — skip the loop, or justify why the orphan states are
harmless (they may well be; the instances are unreferenced) — but do not leave it unsaid in the one
function this changeset rewrites.

### S-4 (warning) — a dead `.noChanges` branch that completes `true` having written nothing

`fetchFromNetwork:578-579`:

    case .noChanges:
        self.callAndClearLoadingHandlers(for: hash, true)

`crawlFirstPage` never constructs it — its body returns only `.success` or `.failure` (verified: the
only `return .noChanges` in the file is `crawl():266`, a different enum). So this arm is unreachable
today and, if a future edit reaches it, reports a successful catalog load having written nothing.
It is the hunted shape, latent, inside the switch this changeset edits. Delete it or make it
`Log.error` + `false`.

### S-5 (warning) — `requireFullCrawlOnNextRun()` is best-effort by construction

`saveCrawlState` is `try? data.write(to:)` (`LibraryRegistryCrawler.swift:559-562`) — a failed write
is swallowed, and the result renders as "no full crawl needed". The F-3 mitigation therefore cannot
be the only thing standing between the user and stale bundled rows. Name it as best-effort, and keep
test 6 driving it through a real `stateDirectory` (it does).

### S-6 (warning) — test 3's second-launch cell will silently exercise the wrong path

`refreshSlimLaunchSnapshotOffMain` opens with `guard !Self._isRunningUnderXCTest else { return }`
(`:341`), so under XCTest the slim snapshot is never produced. A second-launch cell that just
re-constructs a manager will take the *non-slim* branch and pass while never touching the path
production takes. Seed the slim file explicitly — `AccountsManagerLaunchSnapshotTests.seedSlimSnapshot`
is the existing pattern — or the test is a skipped call rendering as a passing test.

### S-7 (nit) — vector 2's post-condition still returns `.success`

"Serialize as partial and do not stamp `lastFullCrawlDate`" leaves the loader logging *"Background
pagination complete: N total libraries cached"* (`:569`) with no way to tell a short crawl from a
whole one. Add a `Log.error` with `count` and `numberOfItems` at the post-condition.

### S-8 (nit) — Acceptance overstates what can be red on develop

"Tests 2 and 7 fail on `origin/develop`" is right; tests 13/14/15 reference symbols that do not exist
there, so they cannot run at all. Name the red-was-possible set explicitly and mark the rest as
new-surface.

---

## What I re-verified this pass, and what holds

- A-4's rule form, against source: `crawl():274-280` `feedMetadata ?? …`, loader `:628-632` supplies
  the cached feed's metadata, `crawlRemainingPages` gets `firstPage.metadata` at `:564`. Your
  restatement is correct and test 13 is the right shape.
- A-5: rule split matches what I proposed; no cell of the table moves; the implementation obligation
  to re-census the smaller-nil-metadata drivers is recorded. The `/libraries` measurement (1457, no
  `numberOfItems`) confirms the vector was real.
- B-6 gating, B-7 statement, B-8 `accountSets[hash]` pin, B-9 acceptance: all present and correct.
- The ledger, mechanism, shrink census, lock composition, criteria table, and §9 (now with the
  spent-number list 499–508, which is a better record than my version) all hold. §9's sequence
  paragraph is now the clearest thing in the contract.

## To clear the block

1. **S-1** — gate the cache write on `replaceBucket` applying; add the "refused write leaves disk
   unchanged, and a fresh manager over that disk is still non-short" test. *(blocker)*
2. **S-2 / S-3** — name the return value's consumer and the refusal-path log; say what the rest of
   `loadAccountSetsAndAuthDoc` does on refusal. *(concern)*
3. **S-4 / S-5 / S-6 / S-7 / S-8** — dead `.noChanges` arm; best-effort `saveCrawlState`; seed the
   slim file in test 3's new cell; log the short-crawl post-condition; fix the Acceptance wording.
   *(warning / nit)*
4. **(a)** — restate the detector as proposed rather than done; move it to `~/harness` with
   `bin/install` wiring; fail-not-skip on cannot-evaluate; add the green-on-tip converse; decide
   whether the wall entry moves to the tracked `.forgeos/wall-failures/`.

S-1 is one conditional and one test. Nothing else in the contract needs re-opening — I re-derived
the parts I had previously accepted and they hold. Re-request and I will re-run C1–C13, re-walk the
launch-1/launch-2/launch-3 traces against the disk-ordering change, and expect to approve.
