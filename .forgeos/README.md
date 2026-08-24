# `.forgeos/` — governance artifacts

Machine-written records produced by the maintainer tooling as work happens. They
are **evidence**, not documentation: each one records what was claimed, checked,
or found at a moment in time. Nothing here is maintained after the fact, and
nothing here should be read as a description of how the code works today. For
that, start at [`docs/README.md`](../docs/README.md).

| Directory | What it holds | Still written? |
|---|---|---|
| `intent/` | Pre-change contracts — Claims, Anti-claims, Files-in-scope — that `check-intent-recorded.py` and `check-contract-reconciliation.py` verify a diff against. `verify-pr.sh` matches these by branch subject, so the directory is **live**: do not prune it. | yes |
| `wall-failures/` | Post-mortems of verification that passed while the defect was live. The highest-value corpus here — indexed in [`wall-failures/INDEX.md`](./wall-failures/INDEX.md). | yes |
| `changesets/` | Per-changeset review records from the ForgeOS era. | no |
| `audits/`, `reviews/`, `handoffs/`, `swift6-a6/` | One-off campaign records. | no |
| `swarms/` | **Archived — see below.** | no, and blocked |

## The swarm archive

26 swarm campaigns (351 files, 10.9 MB) were removed from the working tree on
2026-08-24. They were agent run transcripts, per-campaign plans, manifests, and
review dumps — a record of how a campaign executed, not of what the code does or
why. At 10.9 MB they were the single largest documentation surface in the repo
and roughly two-thirds of all doc bytes, so every future grep for a symbol paid
for them, and what it surfaced was stale campaign scaffolding ranked alongside
maintained architecture docs.

Nothing was lost. The content is in git history, reachable by tag:

```bash
git show archive/forgeos-swarms-2026-08-24:.forgeos/swarms/<campaign>/outcome.md
git ls-tree -r --name-only archive/forgeos-swarms-2026-08-24 .forgeos/swarms/
```

`scripts/check-doc-hygiene.sh` denies new files under `.forgeos/swarms/`, and did
so before this cleanup — the removal finishes a rule that was already in force.
**The durable half of a campaign belongs in an ADR under `docs/architecture/`**,
distilled by hand. If a swarm outcome is worth citing a year from now, that is
where it goes, not back here.
