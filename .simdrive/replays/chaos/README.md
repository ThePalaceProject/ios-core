# Chaos replay corpus — `.simdrive/replays/chaos/`

This directory is the **curated, kept-in-tree chaos replay corpus**. Each entry
is a chaos-QA-discovered scenario that proved valuable enough to lock into CI
forever: a live chaos exploration found a bug (or a bug-adjacent smell), the
finding was fixed, and the recording was curated here so the same regression
can never silently reappear.

Live chaos exploration is non-deterministic by design (it hunts for *new* bugs
via vision + timing-sensitive HID input) and runs advisory-only
(`chaos-qa-on-demand.yml` / the local `chaos-qa` agent — never fails a check).
This corpus is the opposite: **deterministic, cheap, and blocking** — a fixed
set of replays with SSIM post-state assertions.

## What gates this corpus

`.github/workflows/chaos-replay-on-pr.yml` — the `chaos-replay-on-pr` workflow.

It is **DORMANT** today. The `replay` job is `if: vars.ENABLE_CHAOS_QA_RUNNER == 'true'`
and `runs-on: [self-hosted, macos, palace-ios]`. Until BOTH are true —
a self-hosted `[macos, palace-ios]` runner is provisioned AND the repo variable
`ENABLE_CHAOS_QA_RUNNER` is set to `"true"` — the job **skips cleanly** (run =
success), it does not error. Do NOT flip that flag as part of seeding the
corpus; that is a runner-provisioning decision, not a content decision.

When enabled, the gate:
1. Builds the PR candidate and installs it on a sim.
2. Globs `.simdrive/replays/chaos/*.yaml` and, for each, sets
   `NAME=$(basename "$yaml" .yaml)`.
3. Runs `simdrive replay --name "$NAME" --on-drift halt --drift-threshold 0.85`.
4. If any replay's post-state SSIM diverges from the recorded baseline, the job
   fails and comments on the PR: *"a previously-fixed chaos-discovered bug
   appears to have regressed."*

## How the gate resolves a replay (IMPORTANT — read before adding entries)

The workflow globs the **top-level `*.yaml`** files here to get the list of
replay NAMES (`basename .yaml`). But the simdrive replay engine
(`recorder.replay(name, ...)`) resolves that name to a **recording directory**:

```
rec_dir = recordings_root() / name          # recordings_root() = $SIMDRIVE_HOME/recordings
yaml    = rec_dir / "recording.yaml"         # + snapshots/NNN_{pre,post}.png for SSIM
```

So each corpus entry is a **pair**:

| File | Role |
| --- | --- |
| `<name>.yaml` | Curated metadata the gate's glob discovers: intent, `expected_invariants`, `structural_checks`, `ssim_gating`, and a `recording.path` pointer. Human-readable; this is the "why this replay exists" doc. |
| `<name>/recording.yaml` + `<name>/snapshots/` | The replayable payload the engine actually loads (raw `simdrive.record_stop` output — steps + per-step pre/post PNGs SSIM is computed against). |

To make the engine resolve `<name>` from *this* directory, the CI job must run
with `SIMDRIVE_HOME` pointed at the repo's `.simdrive` (so
`recordings_root()` = `<repo>/.simdrive/recordings`) **or** the runner copies /
symlinks `.simdrive/replays/chaos/<name>/` into `$SIMDRIVE_HOME/recordings/<name>/`
before replaying. See the "Dormant-gate concern" note at the bottom — this wiring
is unresolved in the current workflow and must be settled when the runner is
provisioned.

Snapshots ARE committed here (they are the SSIM reference — the gate does
per-step visual drift, not just structural checks, so the reference PNGs must
travel with the corpus). They are ~3–7 MB per recording; keep the corpus lean.

## Seeded entries

| Replay | Bug class it kills | Lineage |
| --- | --- | --- |
| `rapid-tap-ask-me-later` | Rapid multi-tap on a tap-outside-dismiss modal ('Ask me later' on the app-rating gate) double-dismissing or **bleeding through** to the content behind. | Epic PP-4086 app-rating gate chaos pass — the dismiss tap-bleed-through finding. Same 2026-07-02 gate sweep as the dark-mode/dismiss-bleed lineage (`.forgeos/wall-failures/2026-07-02-pr1168-darkmode-contrast.md` is the contrast sibling). |
| `trigger-spam-stacking` | Firing the same modal trigger repeatedly ('Trigger Rating Prompt Now') **stacking** multiple rating gates, trapping the patron in a dismiss-reveals-another loop. | Epic PP-4086 app-rating gate chaos pass, 2026-07-02 sweep. Present-once / coalesce presentation-guard regression detector. |

Both were captured 2026-07-02 (simdrive 1.0.0b12, app build 484, iPhone 16 Pro
iOS 26.0) during the app-rating sentiment-gate chaos-QA sweep that recorded zero
crashes across rapid-tap, trigger-spam, background/foreground, swipe-dismiss,
reset-during-display, and network-loss. They sat uncurated in
`~/.simdrive/recordings/` until seeded here.

## How to add a new chaos replay

1. **Record it locally.** During a `chaos-qa` agent session, when a finding is
   worth locking in, `simdrive.record_start name=<flow>-<descriptor>`, drive the
   tight adversarial sequence, `simdrive.record_stop`. This writes
   `~/.simdrive/recordings/<name>/recording.yaml` + `snapshots/`.
2. **Curate it here.** Copy the recording dir to
   `.simdrive/replays/chaos/<name>/` (drop the `_capture/` scratch dir), then
   author a top-level `.simdrive/replays/chaos/<name>.yaml` in the same schema
   as the seeded two: `scenario.id`, `expected_invariants`, `structural_checks`,
   `ssim_gating`, and a `recording.path` pointer. Name it `<flow>-<descriptor>`.
3. **Explain the bug class it kills** — add a row to the "Seeded entries" table
   with the finding lineage (Epic / wall-failure), so the corpus stays a
   readable ledger of "what chaos found and we now guard forever."

Naming convention (per the workflow header):
`.simdrive/replays/chaos/<flow>-<descriptor>.yaml`.

## Dormant-gate concern (unresolved wiring)

The workflow's `simdrive replay --name ... --on-drift halt --drift-threshold ...`
is written as a **CLI** invocation, but simdrive 1.0.0b12 exposes `replay` only
as an **MCP tool** (`on_drift` / `drift_threshold` args), not as a `simdrive
replay` CLI subcommand (the CLI has `run`, `ci`, `lint-recordings`,
`migrate-recording`, `version`, `doctor`, `demo`, `trial`, `auth`, `license`).
AND the engine resolves `<name>` against `$SIMDRIVE_HOME/recordings/<name>`, not
`.simdrive/replays/chaos/<name>`.

Because the whole job is gated behind `ENABLE_CHAOS_QA_RUNNER == 'true'` (unset
today), this mismatch **cannot fire** on the seeded corpus — the job skips, it
does not error. But before the flag is flipped, the workflow's replay step must
be reconciled with the actual simdrive surface (invoke the MCP tool or add a
`simdrive replay` CLI shim, and point `SIMDRIVE_HOME` at the repo `.simdrive` or
stage the corpus recordings into the recordings root). Do not enable the runner
until that is fixed. This is a workflow-wiring task, deliberately left untouched
here (corpus content only).
