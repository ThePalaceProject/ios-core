# Chaos-QA dogfood retro — 2026-04-29

Three sessions against the PP-4164 candidate. Captured here to inform
the next iteration of chaos-qa.md and to document the first real bugs
the agent surfaced.

## Sessions at a glance

| Run | Seed | Paths | Findings | Replays | Budget | Notes |
|---|---|---|---|---|---|---|
| 1 | `anonymous-borrow/03-catalog` | 3 | 2 (1 downgraded) | 1 | 8/6 min ⚠️ over | Tap-zone pipeline issue cost 2 paths |
| 2 | `anonymous-borrow/05-after-borrow` | 2 | 0 | 0 | 5/6 min ✓ | Discipline: discarded all paths for missing log evidence |
| 3 | `cold-launch` | 2 | **3** | 2 | 5.5/6 min ✓ | Cold-launch is genuinely fertile |

Sessions live under `~/.simdrive/chaos-runs/2026-04-29T*-dogfood-*`.
They are NOT checked into the repo — they're local artifacts. Anything
worth keeping was promoted explicitly: real bugs to the regression
findings.csv, retro learnings to chaos-qa.md, this doc to here.

## What chaos found that humans likely wouldn't have

### F-007 (was DD3-002) — major regression

**Anonymous Palace Bookshelf hits authenticated `/patrons/me/` on every
cold launch, gets 401, logs the full error dump, repeats indefinitely.**

```
Palace[48403] [...] Api call failure: problem document available Code=902
Palace[48403] [...] BookRegistrySync.swift: Loans sync failed: PalaceError 0
Palace[48403] [...] currentAccountUUID=urn:uuid:6b849570-070f-43b4-9dcc-7ebb4bca292e (Palace Bookshelf)
Palace[48403] [...] HTTP 401 application/vnd.opds.authentication.v1.0+json
Palace[48403] [...] URL: https://dpla.thepalaceproject.org/bookshelf/patrons/me/
```

This is a real bug in anonymous-flow handling — `/patrons/me/` is an
authenticated endpoint and shouldn't be requested for an account whose
auth-doc says no credentials are needed. The fix lives in
`TPPSignInBusinessLogic.swift` or `BookRegistrySync.swift` (gate on
`accountAuthDocURL.requiresAuth`). Replay YAML at
`~/.simdrive/chaos-runs/2026-04-29T18-58-34Z-dogfood-3-cold-launch/replays/cold-launch-add-library-mid-load-cancel.yaml`
— **this becomes the regression guard once the bug is fixed.** Per the
curation discipline in `.simdrive/replays/chaos/README.md`, replays
only enter the protected corpus AFTER the underlying bug is fixed.

### F-008 (was DD3-001) — minor pre-existing

**Book detail invokes `canOpenURL:` on book metadata strings instead of
real URLs.** Audiobook, "October 15, 2018", "Books on Tape", "Palace
Marketplace", "10 hours 27 minutes", "Women's Fiction;Contemporary
Romance;Literary Fiction" all get fed to `canOpenURL:`. Log spam, no
crash, but the over-greedy linkify heuristic in the book-detail
formatter should scope to URL-shaped strings.

### DD1-002 — minor, pre-existing

**`libxpc.dylib` assertion failure on every cold launch.** Non-fatal;
catalog still renders. Documented for awareness; not promoted.

### Build-config artifact (correctly classified, not a bug)

When `xcodebuild build-for-testing` produces a Palace.app and that's
installed on the candidate sim, `PalaceTests.xctest` lands in
`Palace.app/PlugIns/`. iOS loads PlugIns at app launch, so the test
bundle's `NSPrincipalClass=PalaceTestSetup` runs and registers
`NoNetworkURLProtocol` globally — silently blocking all network requests.

The chaos-1 agent first reported this as a major test-target leak.
After incorporating Lesson D (build-config artifact rule) into the
system prompt, chaos-3 correctly classified the same observation as a
build-config artifact / cosmetic / "does not occur in release builds."
The rule worked: the agent self-corrected on the second exposure.

## Pipeline issues found and fixed

These were observed across the three sessions and are now incorporated
into `.claude/agents/chaos-qa.md` (see "Lessons from the 2026-04-29
dogfood retro" section):

1. **Tap-zone guardrail extension.** Original prompt said swipes need
   to stay in y∈[200,2200] for iPhone 16 Pro. Rapid-fire taps near the
   tab bar (y∈[2470,2520]) ALSO leak into iOS home gesture. Now: insert
   ≥200ms wait between tab taps and observe between actions to verify
   Palace stays frontmost.
2. **`simdrive.logs` default predicate.** Original `(crash|fatal|exit|exception)`
   was too narrow — F-007 only surfaced under the broader
   `(error|warn|fail|exception|exit)` filter. Now: broader predicate is
   the documented starting point.
3. **Empty-log interpretation.** `simdrive.logs` returns the
   header line `"Timestamp ... Process[PID:TID]"` even when zero events
   match. Header-only ≠ success. Now: explicitly documented in the
   prompt.
4. **Replay output path.** `record_stop` saves to
   `~/.simdrive/recordings/<name>/recording.yaml`, NOT to the
   configured `replays_dir`. Now: prompt instructs the agent to `cp` it
   over after each `record_stop`.
5. **Build-config artifact rule (Lesson D).** Now: agent must check for
   `PlugIns/PalaceTests.xctest` BEFORE filing test-symbol-related
   findings. If present, classify as cosmetic / build-config artifact,
   not as production bug.
6. **App-relaunch hint (Lesson E).** When Palace drops to home,
   `xcrun simctl launch` is the right recovery — `simdrive.tap` on the
   home-screen icon can hit a folder label.
7. **Logs window (Lesson F).** `simdrive.logs` is a 30-second tail.
   Long paths need multiple log captures, not one at the end.
8. **Hard-stop discipline.** dogfood-1 went 8min/6min. Now: explicit
   prompt rule that the cap is hard, no "one more path."
9. **Content vs. state matching.** When seeded mid-flow on a sim with
   pre-existing state, the visible content (book titles) may differ
   from the fixture even though the structural state matches. Agents
   should match on STATE markers (Read+Remove buttons present, Borrow
   absent), not content (specific book title). This was already implicit
   in the fixture design but is now explicit in the dogfood notes.

## What I'd change about the agent design itself

These are deeper than prompt tweaks; they're scope-of-work questions:

- **Continuous log capture.** A single `simdrive.logs` query at the end
  of a path can miss the action→reaction window if the path takes more
  than 30s. A version where `simdrive` (or chaos-qa) starts log
  streaming at session_start and stops at session_end would let chaos
  reason about ANY moment in the run. Worth raising with the simdrive
  team.
- **`pre_seed_defaults` extension.** The chaos-qa system prompt
  references this for state injection (`xcrun simctl spawn defaults
  write` before launch) but doesn't actually wire it. With this,
  AccountsManager-class internal mutants (the F-001 / F-005 family)
  become reachable. Estimated 1 day to add.
- **App-state pre-flight.** Several runs started with the candidate sim
  in unexpected states (app already in foreground, leftover library,
  etc.). A standard pre-flight that resets to a known clean state would
  remove a class of seed-mismatch issues. Could be a CLI flag on
  `run-chaos-pass.sh` (`--pristine`).
- **Cold-launch is the sweet spot.** dogfood-3 produced 3 findings in 2
  paths. Cold-launch + boundary-state strategies yield more value per
  budget unit than mid-flow seeds when the candidate is fresh. Future
  scheduling should weight cold-launch heavier.

## What this proves about chaos-qa as a capability

- **It works.** Three sessions, three mostly-clean runs (one budget
  violation early, fixed via prompt update). The agent followed the
  log-evidence rule strictly — discarded findings without log proof
  rather than hallucinating bugs.
- **It finds real bugs the deterministic suite missed.** F-007 is the
  best example: the anonymous-borrow fixtures all pass; the bug only
  appears at cold-launch with a stored library, on a path no human had
  thought to script.
- **It self-corrects.** The build-config artifact rule was added after
  dogfood-1 mis-classified the test-bundle leakage. dogfood-3 hit the
  same pattern and classified it correctly. Iterative prompt refinement
  works.
- **Cost is manageable.** Three sessions in roughly 18 minutes of
  wall-clock + token cost from the Agent calls. Manual QA would not
  have caught F-007 in that time window.

## Next steps

- F-007 fix in a separate PR. Once that PR merges, promote the replay
  YAML into `.simdrive/replays/chaos/` as the regression guard.
- F-008 fix in a separate PR (lower priority — log spam, not breakage).
- One more dogfood pass once `pre_seed_defaults` is wired, targeting
  AccountsManager mutants that the UI surface can't reach.
- After the runner is set up: re-enable `chaos-qa-nightly.yml` and let
  the corpus grow.
