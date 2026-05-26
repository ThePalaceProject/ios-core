# Chaos-Discovered Replay Corpus

Curated YAML replays generated from chaos-qa sessions. Each file here was
recorded by `simdrive.record_stop` during a chaos run and promoted by a
human as worth-keeping. Together they form the deterministic guard layer
that runs on **every** PR via `.github/workflows/chaos-replay-on-pr.yml`.

## How a replay gets here

```
chaos-qa session                          curation                checked in
────────────────                          ────────                ──────────
seed: anonymous-borrow/05-after-borrow
strategy: rapid-tap on Borrow during   →  human reviews finding,  →  .specterqa/replays/chaos/
          200ms loading window             reproduces locally,         double-borrow-during-load.yaml
finding: book registered twice            decides to keep
record_stop wrote: ~/.specterqa/                                       SHA-checked into repo
  recordings/double-borrow-…/
```

A replay must satisfy three checks before being committed:

1. **Reproducible.** Run the YAML twice in a row → identical end state
   (SSIM ≥ 0.95 between runs). Non-deterministic captures don't go here.
2. **Fixed in the candidate.** When the underlying bug is patched, the
   replay's drift threshold (≥ 0.85 by default) becomes a regression
   alarm. Don't commit a replay until the bug is fixed AND you've
   verified the patched build still passes the replay (state is
   stable, not broken-in-a-new-way).
3. **Mutation-killing.** At least one mutation on the production-code
   path the replay exercises should cause the replay to drift. If
   chaos found a flaky timing window but no mutation surface lives
   along the path, the replay is theatre — discard.

## Naming convention

`<flow-id>-<short-descriptor>.yaml`

Examples:

- `anonymous-borrow-double-tap-during-load.yaml`
- `multi-account-bg-fg-credential-bleed.yaml`
- `reader-rapid-page-turn-pos-loss.yaml`

The `<flow-id>` matches a key in `.specterqa/fixtures/flows/*.yaml` so
replays are visible in the same coverage matrix as fixture tests.

## What lives in each YAML

simdrive's `record_stop` writes the standard format. We add a sidecar
`.notes.md` next to the YAML with:

- The original finding's CSV row id (e.g. `F-042`)
- The seed used (`<flow>/<step>`)
- The mutation targets the replay covers
- The PR that introduced the test guard
- The PR that originally fixed the bug

Without the sidecar, the replay is opaque six months later. The sidecar
is the test's documentation.

## What does NOT belong here

- **Happy-path replays.** Use `.specterqa/replays/<flow-name>.yaml` for
  those. The `chaos/` subdir is reserved for adversarial-discovery
  replays that prevent regression of fixed-once-already bugs.
- **Replays that don't break on mutation.** Run `palace_mutate.py`
  against the production code touched by the replay's actions; if no
  mutant flips its outcome, the replay is fluff. Discard.
- **Replays that depend on volatile content** (specific book titles,
  carousel order). Re-record with a more stable interaction surface, OR
  use SSIM-tolerance > 0.85 to absorb expected variation. If neither
  works, the scenario isn't suitable for replay-based guarding — keep it
  as a fixture-based test instead.

## Empty for now

This directory is empty in the initial PR — no chaos sessions have been
run yet. As chaos-qa-nightly runs accumulate findings and humans curate,
replays land here and the PR-time guard becomes meaningful. Until then,
the workflow has nothing to replay (and exits 0 immediately, which is
correct).
