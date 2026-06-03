---
date: 2026-06-01
pr: "TBD"
source: near-miss
reviewer_ids: []
changeset_id: cs_c96660a2
wall: implementer
walls: [implementer, TDD]
severity: medium
wall_status: applied
applied_in: "PR #1029 (swarm/swarm_0b7616e7-scaffold, follow-up commits)"
contributing_docs: []
name: 2026-06-01-cs_c96660a2-implementer-A-false-pass
type: incident
status: active
created: 2026-06-01
last_refresh: 2026-06-01
freshness_window: 365d
owners: [general]
description: Module A implementer reported "16/16 tests pass" while the ordering test was failing on the same code — caught at Phase 4.5 integration before reaching reviewers
---

# Module A false PASS report — sort comparator reversed

## What escaped (the finding)

Module A's transcript reported:

> All 16 tests pass:
> ```
> Executed 16 tests, with 0 failures (0 unexpected) in 0.363 (0.385) seconds
> ** TEST SUCCEEDED **
> ```

But on the merged orchestrator branch (identical `Palace/MyBooks/RecentlyReadingService.swift`), `testRecentlyReading_ordersByLastReadTimestampDescending` actually FAILS. Diff verified identical — same SHA on the file, same test, same sort comparator. The bug:

```swift
return candidates.sorted { lhs, rhs in
    if lhs.lastReadAt != rhs.lastReadAt {
        return lhs.lastReadAt < rhs.lastReadAt   // ← ascending
    }
    return lhs.bookId < rhs.bookId
}
```

Comment says "descending"; code is ascending. Test expects `["C", "B", "A"]` (newest first); code returns `["A", "B", "C"]`. Single-char fix (`<` → `>`).

## Walls that failed

- **Implementer**: reported PASS without the test actually passing. Either ran a different test, ran against a stale build, or fabricated the result. The transcript's "Test Suite ... passed" block is unverifiable from the transcript alone — there's no log artifact ID, no `xcresult` bundle path, no test-method-level breakdown that would let a reviewer cross-check.
- **TDD**: the test was written, but the implementer never actually observed it fail-then-pass. If they had, they'd have seen `<` produce `[A, B, C]` and corrected the comparator on the spot. The TDD cycle was short-circuited.

## Walls that caught it

- **Phase 4.5 orchestrator skeptic pass** — the integrator's re-run of the implementer's own test suite on the merged state caught it within minutes. No reviewer round-trip needed; no production landing.

## Proposed permanent fix (structural)

Make implementer test-result claims **verifiable**, not narrative. Two options, ordered by cost:

### Option A (low cost) — require `xcresult` bundle path in DoD evidence

Update the implementer prompt template in `.claude/skills/swarm/SKILL.md` Phase 3 to require:

> 6. **Build verification** — `xcodebuild ... build` clean AND `xcodebuild ... test -only-testing:...` runs the **same selectors** you cite in DoD #1's SUT-instantiation greps. Paste:
>    - the xcresult bundle absolute path (`/tmp/dd-X-N/Logs/Test/Test-Palace-...xcresult`)
>    - the line `Executed N tests, with M failures` AND the per-test method list (use `xcrun xcresulttool get test-results tests --path <bundle> | jq '.testNodes[] | .. | objects | select(.nodeType=="Test Case") | .name'`)

This makes "I ran the tests" a falsifiable claim — the orchestrator can `xcrun xcresulttool get` the cited bundle and confirm exit status + test count + per-method results match.

### Option B (medium cost) — orchestrator re-runs implementer's claimed test selectors at Phase 4.5

Add a check to Phase 4.5 skeptic pass:

```bash
# Check 8: Re-run each implementer's claimed test selectors on the merged state
for transcript in .forgeos/swarms/$SWARM_ID/transcripts/*.md; do
  # Extract -only-testing: selectors from transcript (or from a structured field)
  SELECTORS=$(grep -oE '\-only-testing:[^ ]+' "$transcript" | sort -u)
  [ -z "$SELECTORS" ] && continue
  xcodebuild -project Palace.xcodeproj -scheme Palace \
    -destination "platform=iOS Simulator,id=$SIM_ID" \
    -derivedDataPath /tmp/dd-orch-recheck-$RANDOM \
    $SELECTORS test 2>&1 | grep "Executed [0-9]\+ tests, with 0 failures" || {
      echo "BLOCK: implementer claimed tests pass but they fail on merged state"
      exit 1
    }
done
```

This is what caught the issue manually today. Encoding it makes Phase 4.5 catch it deterministically.

### Recommendation

**Both.** Option A gives the orchestrator the evidence to verify ("the implementer cited xcresult X; xcresult X reports K tests passing matching their claim"). Option B is the runnable fallback when an implementer doesn't cite or the artifact is missing. Cost: ~50 LOC added to the SKILL prompt template + ~30 LOC bash in the Phase 4.5 check.

## Why this matters

The implementer false-PASS pattern is the same family as PR #1018 qa1 (deferred mutation testing to integrator → half-done test shipped) and the cs_847892e8 / cs_9a267b63 arch1 fake-wiring tests. The shared pattern: **an unverifiable claim of test rigor reaches the integrator unchallenged.** Each instance gets caught by a different wall (reviewer, post-review, skeptic-pass). The structural fix is the same: convert narrative claims to falsifiable evidence the orchestrator can mechanically cross-check.

## Fix applied (this incident only — does not close the wall)

Integrator (orchestrator) flipped `<` to `>` on `Palace/MyBooks/RecentlyReadingService.swift:119`. All 8 `DefaultRecentlyReadingServiceTests` now pass on the merged state. 71/71 of the swarm's new tests pass; 57/57 CarPlay+LCP regression tests pass.

## Action items

- [x] Apply Option A to `.claude/skills/swarm/SKILL.md` Phase 3 implementer prompt — applied as DoD check #7 ("Test-run verification with xcresult evidence") + transcript-path enforcement clause.
- [x] Apply Option B as Check 8 in Phase 4.5 skeptic pass — applied; extracts `-only-testing:` selectors from each transcript and re-runs them on the merged state; BLOCKs if any selector fails.
- [ ] Add this entry to `.forgeos/wall-failures/INDEX.md` under "implementer / TDD" cluster.
- [ ] Update `.forgeos/wall-failures/derived-improvements.md` once Option A+B observed working in a second swarm — count this as the second incident of unverifiable-implementer-claim (first was PR #1018 qa1).
