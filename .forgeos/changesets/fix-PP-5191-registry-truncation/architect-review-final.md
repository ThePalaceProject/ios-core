<!-- FINAL architect verdict (round 6 of 6). Rounds 1-5 were intermediate and are
     not retained: every finding they raised is folded into fix-contract.md's [rev2]
     .. [rev6] annotations and into the commit bodies. What they found, in order —
     verification criteria that were already green on the base ref; `numberOfItems ==
     nil` read as PARTIAL (would have emptied the registry for 100% of installs on
     upgrade); an invariant that refused the change's own merged superset; a declared
     total inherited from cache (deletions could never reconcile); and a disk write
     ahead of the guard (an invariant one session deep). -->

# Architect post-review — PP-5191 fix-contract **rev 6** (final)

**Branch:** `fix/PP-5191-registry-truncation` · **Base:** `ea61dd998` · 2026-09-21
ForgeOS OFF — no MCP call, no signed verdict. This file is the verdict.

## VERDICT: **APPROVED**, conditional on three mechanical additions to §7 and one line in §8

No further architect round. The conditions below are enumeration, not design — they are
self-verifying and I do not need to see them again.

---

## Your direct question: is the residue only S-4/S-5/S-7?

**Almost. There is one more, and it is bookkeeping rather than design.**

**R-1 (concern, and the only condition on this approval) — §7 does not carry the rev-6 fixes.**
The S-1/S-2/S-3/S-6 rules are stated correctly in §4 (lines 160-189), but §7's enumeration still
stops at test 15 and §8 gates on §7. So the three rules with the highest blast radius in this
revision have **no row in the list the Acceptance section checks**. That is the wall entry's own
finding applied to the contract's own gate: a rule asserted in prose, with nothing executable
behind it, renders as done.

Three rows and one line close it:

- **Test 16 (S-1/S-2).** A REFUSED write leaves the **on-disk cache byte-identical**, and a fresh
  manager constructed over that disk state still comes up non-short. This is the test that makes
  INV-2 more than one session deep; without it the whole rev-6 fix is unverified.
- **Test 17 (S-3).** After a refused write, `AccountStateStore` holds **no** new state for the
  uuids that did not enter the bucket, and no `.TPPCurrentAccountDidChange` was posted.
- **Test 3 amendment (S-6).** Fold the slim-seeding requirement into test 3's *text*, not only into
  §4's prose — the cell must drive the slim path explicitly (the
  `AccountsManagerLaunchSnapshotTests.seedSlimSnapshot` pattern) or assert which branch was taken.
- **§8 (S-8).** "Tests 2 and 7 fail on `origin/develop`" — say which tests are the red-was-possible
  set and mark 13-17 as new-surface (they name symbols that do not exist at the base ref, so they
  cannot be run there at all). One clause.

**R-2 (implementation note, not a condition) — the "applied" signal must not ride the existing
completion `Bool`.** `loadAccountSetsAndAuthDoc`'s completion is `(Bool) -> Void` meaning *parse
succeeded*, and §4 correctly keeps a refusal completing `true`. The cache-write gate therefore needs
`replaceBucket`'s applied-flag on a **separate channel** — a return value or out-param. Folding both
meanings into that one `Bool` would be a fresh instance of the pattern (refusal rendering as success
through an overloaded flag), and it is the obvious shortcut an implementer will reach for. Worth an
inline sentence in §4 so it is decided now rather than in review.

Otherwise: **yes, the residue is S-4, S-5 and S-7**, each recorded in §4 with its render-as-success
description. I am content to ship all three deferred. For the record, my read on each:

- **S-4** (dead `.noChanges` arm) — zero current risk; it is unreachable. Delete it opportunistically
  when someone is next in that switch.
- **S-5** (`saveCrawlState` is `try?`) — pre-existing, and the F-3 mitigation failing open degrades to
  today's behaviour, not worse than it.
- **S-7** (short-crawl post-condition returns `.success`) — the log line is one line and I would take
  it if the implementer is already there, but it is observability, not correctness.

---

## What I verified this pass

- **Wall entry moved and staged.** `.forgeos/wall-failures/2026-09-21-guard-refusal-renders-as-success.md`
  exists, `.harness/wall-failures/` is gone, `INDEX.md:24` carries the row, and the summary names
  instance 5 explicitly. `detector_script: ""` with `wall_status: open` is the correct encoding —
  the entry cannot close while the gate is unwritten. `git status` shows both files staged.
- **Instance 5 recorded as a numbered finding**, and "Instance 5 was caught by `ls`" is in the entry.
  That is the right level of bluntness for canon.
- **S-1 in §4 (lines 160-175)** — the trace is reproduced correctly (`:543` unconditional disk,
  `:544` where INV-2 lives, B-7 making the resident empty each launch, `:595`/`:674` defeating A-5),
  and the fix gates the cache write on `replaceBucket` applying. I re-checked the consequences of
  reversing that order: `mergePartialPage` still reads the cached bytes before writing, the slim
  carve reads the older-and-better bytes on a refusal, and a refused write correctly leaves the
  metadata timestamp unrefreshed so refresh pressure persists. **Sound.**
- **S-3 (177-180)** — skipping the `_setState` loop, the auth-doc drive and the notification on a
  refused write, with a state-store assertion. Correct.
- **S-6 marked MUST-fix** — right call; a test that passes without touching production is the
  same shape.

The ledger, mechanism, three shrink vectors, INV-2 (rev-5 form), lock composition, the A-4 rule,
the A-5 split, the criteria table and §9 all hold. I re-derived each across these six rounds and
have re-checked the parts I had previously accepted.

---

## On the process cost — you asked, so here is a straight answer

**Your instinct is right, and this is the round to stop.** The marginal return has clearly turned:
rounds 1-5 each surfaced a defect that would have shipped either a broken fix or a false green —
criteria that could not fail, an invariant that refused its own write, a nil rule that would have
emptied the registry for 100% of installs on upgrade, a deletion path that could never reconcile,
and an invariant one session deep. Round 6 surfaced four missing rows in a list. That is the curve
flattening, and continuing past it would be process for its own sake.

Two things worth saying against the "~10 LOC" framing, though, because I think the cost was
correctly spent:

1. The change is not ~10 LOC. Commit B is; **commit A is a new invariant enforced inside a
   non-recursive lock on the launch thread, a new pure predicate, a metadata contract change across
   four serialize sites, and a merge helper** — touching the type that decides which library a
   patron is signed into. Two of the six rounds found launch-path failures (a recursive-wrlock
   deadlock, an empty-registry-on-upgrade) whose cost would have been measured in releases.
2. Five of the six defects were **invisible to every automated gate you have.** They are pre-code
   contract defects; TDD, mutation and CI cannot see them, and one self-heals across launches so no
   suite could. That is exactly the surface a second reader exists for — and it is the argument for
   the detector being worth writing, since it converts the cheapest of the five into something a
   machine catches for free forever.

The honest lesson is not "fewer review rounds" — it is that rounds 2-5 were spent re-deriving the
same class of defect because nothing mechanised the first instance. Write the detector and this
review is two rounds next time.

---

## Conditions on approval (no further architect round)

1. Add §7 tests 16 and 17; fold S-6 into test 3's text; amend §8's red-was-possible clause. *(R-1)*
2. Add the one-sentence note that the applied-flag is a distinct channel from the completion `Bool`. *(R-2)*
3. S-4 / S-5 / S-7 ship deferred as recorded.

**Implementation-time reminders**, already agreed in the contract, restated so they are in one place:
re-census the `loadAccountSetsAndAuthDoc` drivers for a smaller nil-metadata replacement before
relying on the A-5 delta; pin the resident read to `accountSets[hash]`; `replaceBucket` is one
`accountSetsLock.write` and never calls `mutate`; update the accounts verification-checklist §1 + §9
as part of commit A; release-first then forward-port, `--merge` never `--squash`.

Good contract. The diagnosis was right in rev 1 and survived every round of attack — what changed
was the machinery around it, which is the correct outcome of review.
