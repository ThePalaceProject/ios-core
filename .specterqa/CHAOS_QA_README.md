# Chaos-QA: adversarial iOS testing via simdrive

> **Status (2026-04-29):** on-demand only. The nightly workflow is renamed
> to `chaos-qa-nightly.yml.disabled` until we have a proven track record
> and a self-hosted runner ready to absorb the cost. Re-enable by removing
> the `.disabled` suffix. Until then, the only chaos-qa entry points are
> (a) PR comments containing `@chaos-qa investigate` and (b) running
> `scripts/run-chaos-pass.sh` locally.


Adversarial QA agent that finds the bugs deterministic tests can't.
Seeds from a captured fixture state, then deviates with rapid taps,
pathological inputs, background/foreground races, and other tactics.
Records each finding with log-evidence and an optional simdrive replay.

## Three modes — different cadences

| Mode | Cadence | Trigger | Cost | Determinism |
|---|---|---|---|---|
| **Replay corpus** (`.specterqa/replays/chaos/`) | Every PR | `chaos-replay-on-pr.yml` | Cheap (deterministic) | High — same input, same result |
| **On-demand investigation** | Maintainer comments `@chaos-qa investigate` | `chaos-qa-on-demand.yml` | Medium (LLM + sim) | Low — different findings each run |
| **Nightly discovery** | 06:00 UTC | `chaos-qa-nightly.yml` cron | Medium (LLM + sim) | Low |

The **replay corpus** is what protects PRs. Live chaos sessions
(on-demand + nightly) produce findings; humans curate the worth-keeping
ones into checked-in replays; those replays then run forever in CI.
Discovery and protection are decoupled.

## Why replays are mutation-killing (and fixtures aren't)

`MarksFixture.swift` tests assert against captured JSON files — they
verify the fixture is well-formed and catch fixture drift between
releases, but they **do not run production code**. Mutating
`BorrowReducer.swift` doesn't change the static JSON, so the fixture
tests still pass. PP-4164 finding F-006 documents this: mutation runs
on both `AccountsManager.swift` (0/8 killed) and `BorrowReducer.swift`
(0/4 killed) confirmed the gap empirically.

simdrive **replays** drive the live app on the candidate build, then
compare the resulting screen to the recorded screen via SSIM. A code
mutation that changes any visible behavior changes the SSIM, the drift
threshold trips, the replay fails. That's mutation-killing by
construction.

So the architecture is layered:

| Layer | Catches | Mutation-killing? |
|---|---|---|
| Fixture JSON + marks-diff.py | Fixture drift, layout shifts | No — fixture-only |
| Fixture-based XCTest cases | Fixture corruption | No — fixture-only |
| Replay corpus on every PR | Production-code regressions | **Yes** — drives live |
| Live chaos sessions | New, unknown bugs | **Yes** — drives live |

Both layers are needed. Fixtures provide the reference data, the
coverage matrix, the a11y audit, and the auto-finding generator.
Replays provide the regression guard.

## Why not run live chaos on every PR

1. **Flakiness.** Adversarial exploration is non-deterministic by design.
   Two runs on the same PR will produce different findings. PR authors
   would rage-quit a flaky required check.
2. **Cost.** Every PR pays for an LLM-driven exploratory pass plus
   sim time. That adds up fast.
3. **Noise.** Most PRs touch a narrow surface. Whole-app chaos against a
   small diff produces findings unrelated to the change.

The replay corpus addresses all three: deterministic, cheap, scoped to
already-discovered bugs.

## How chaos-qa picks where to look

When invoked on-demand, the agent receives the PR's changed file list
(`git diff --name-only` between PR and base). `scripts/chaos-targets.py`
reverse-maps changed files → fixture flows whose `mutation_targets`
include those files. The flows' last steps become the seeds.

Example: PR touches `Palace/Book/UI/BookDetail/BorrowReducer.swift`. 
`chaos-targets.py` finds that `anonymous-borrow.yaml`'s mutation_targets
include `BorrowReducer.swift`, returns `anonymous-borrow/06-my-books`
as the seed. Chaos replays `anonymous-borrow` up to step 06, then
explores adversarially from the registry-just-changed state.

If no flows match (file isn't covered by any fixture), chaos falls back
to `cold-launch` — a generic exploration on a fresh install. This is
the signal that the changed area needs a captured fixture flow added.

## Chaos session structure

Three phases per seed:

1. **Seed** — replay the fixture flow up to the seed step. Verify the
   reached state matches the captured marks (within tolerance for
   volatile content). If divergent: log a `seed-mismatch` finding and
   stop.
2. **Explore** — pick paths randomly from the strategy menu (rapid-tap,
   pathological-input, bg/fg, swipe-noise, tap-during-load,
   network-loss, rotation, etc.). Each path is an independent budget
   unit (one of the N max paths).
3. **Record** — for any anomaly with log evidence, append a row to the
   session's `findings.csv` and (optionally) save a simdrive replay
   YAML for later curation.

## Hard rules — chaos cannot violate these

- **Palace Bookshelf is the only borrow-able library.** A1QA is OK for
  sign-in flows (verify auth UI shows up), NOT for borrows.
- **No `simctl erase`.** Resetting state is `uninstall + install`.
- **No real Apple ID interactions** (Family Sharing, Game Center, etc.).
- **No interactions that lock out test creds** (5 wrong PINs in a row).
- **Hard stop at budget.** When path count or wall-clock minutes hits
  the cap, the session ends. No "one more path."
- **Every finding requires `simdrive.logs` evidence.** Visible-but-not-
  log-confirmed observations are discarded. This stops the LLM from
  hallucinating bugs.

## Running chaos locally

```bash
# Build the candidate Palace.app and install on a sim of your choice.
xcodebuild -project Palace.xcodeproj -scheme Palace \
  -destination 'platform=iOS Simulator,id=<UDID>' \
  -derivedDataPath /tmp/dd-chaos build
xcrun simctl install <UDID> /tmp/dd-chaos/Build/Products/Debug-iphonesimulator/Palace.app

# Targeted run (chaos picks seeds from your local diff):
git diff --name-only origin/develop...HEAD > /tmp/diff.txt
./scripts/run-chaos-pass.sh --diff-files-from /tmp/diff.txt --udid <UDID>

# Explicit seed run:
./scripts/run-chaos-pass.sh --seed anonymous-borrow/06-my-books --udid <UDID>

# All-flows run (mimics nightly):
./scripts/run-chaos-pass.sh --all-flows --udid <UDID> --max-paths 50 --max-minutes 30

# Dry-run to see the prompt that would be sent:
./scripts/run-chaos-pass.sh --seed anonymous-borrow/06-my-books --udid <UDID> --dry-run
```

Output lands in `~/.specterqa/chaos-runs/<timestamp>/`:
- `findings.csv` — CSV rows in the regression-report format
- `replays/` — recorded simdrive YAMLs for any path worth saving
- `summary.json` — final counts by severity
- `prompt.txt` — the exact prompt that was sent (for reproducibility)

## Curating findings into the replay corpus

Most chaos findings should NOT become replays. The bar for promotion:

1. **Reproducible.** Replay the YAML twice; identical end state both
   times (SSIM ≥ 0.95 between the two end-state screenshots).
2. **Fixed.** The underlying bug has been patched in candidate code AND
   the patched build still passes the replay (the replay's drift
   threshold becomes the regression alarm).
3. **Mutation-killing.** Run `palace_mutate.py` against the production
   code path the replay exercises. At least one mutant should flip the
   replay's end-state SSIM below threshold. If no mutants matter, the
   replay is theatre — discard.

Replays that pass all three move to `.specterqa/replays/chaos/` with a
sidecar `.notes.md` documenting the original finding, the seed, the
covered mutants, the bug-fix PR, and the test-guard PR.

## When chaos finds nothing

A "0 findings" session is a legitimate result. It means either (a) the
seed area is robust to the strategies tried, or (b) the budget was too
small for the surface. Both are useful signals:

- (a) — encourage the team to keep that surface that way
- (b) — bump the budget for the next on-demand or nightly run

Don't treat "0 findings" as failure. The replay corpus is what stops
regressions; live chaos is exploratory.
