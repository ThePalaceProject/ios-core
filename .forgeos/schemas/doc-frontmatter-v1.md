---
name: doc-frontmatter-v1
type: immutable
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: never
owners: [governance]
description: Canonical YAML frontmatter schema for governance markdown docs.
---

# Doc-frontmatter schema, v1

This is the canonical human-readable spec for the YAML frontmatter that
every governance markdown doc in this repo must carry. The Python
validator at `~/harness/core/lib/validate-doc-frontmatter.py` enforces
this schema; pre-commit hooks (Module C) gate pushes against it; the
harness docs-decay command (Module D) consumes the JSON report to
surface stale docs at SessionStart (Module E).

## Why this exists

Governance docs (wall failures, ADRs, swarm contracts, skill definitions,
area checklists) accumulate without a lifecycle signal. We can't tell at
a glance which docs are immutable historical record vs. living docs that
have decayed past their refresh window. Frontmatter makes the lifecycle
explicit and machine-checkable.

## Where the schema applies

In-scope (validator walks these):

- `.forgeos/**/*.md` — except `.forgeos/swarms/**` (transcripts churn
  faster than schema), `.forgeos/wall-failures/archive/**`,
  `.forgeos/mutation-cache/**`, `.forgeos/audits/**`,
  `.forgeos/contracts/**`, and the `lint-baseline` /
  `crashlytics-baseline` generated artifacts.
- `docs/architecture/**/*.md`
- `.claude/skills/**/*.md`

Out-of-scope: top-level `README.md`, `CLAUDE.md`, `PalaceTests/**`,
`Palace/**` source-tree docs, generated artifacts, anything under the
exclusions above.

## Required fields

```yaml
---
name: <unique-kebab-case-slug>
type: immutable | evolving | ephemeral
status: active | stale | archived | superseded
created: <YYYY-MM-DD>
last_refresh: <YYYY-MM-DD>
freshness_window: 90d | 180d | 365d | never
owners: [<area-slug>, ...]
---
```

### `name` (required, string)

A unique kebab-case slug. Lowercase ASCII alphanumerics plus dashes; must
start and end with an alphanumeric. Used as the cross-doc reference key
in `supersedes` / `superseded_by` / `related`. Must be unique within the
repo (validator flags duplicates).

### `type` (required, enum)

- **`immutable`** — historical record. Wall-failure entries, post-mortems,
  ADR rationale dumps. Frontmatter MUST set `freshness_window: never`
  because the doc is not supposed to be refreshed.
- **`evolving`** — living document that's expected to be refreshed
  periodically. Area checklists, skill definitions, this schema spec.
  Frontmatter MUST set a finite `freshness_window` (90d / 180d / 365d).
- **`ephemeral`** — short-lived doc (sprint handoff, regression run
  report). Frontmatter MUST set a finite window; the doc is expected to
  be archived or superseded within ~one window.

### `status` (required, enum)

- **`active`** — currently authoritative.
- **`stale`** — past its refresh window, not yet refreshed. Set
  automatically by the docs-decay command (Module D) when
  `now - last_refresh > freshness_window`. Owners are expected to either
  refresh-and-bump-`last_refresh` or move to `archived` / `superseded`.
- **`archived`** — kept for archaeology; not authoritative. Move into a
  `archive/` subdirectory if one exists.
- **`superseded`** — replaced by a newer doc. MUST also set
  `superseded_by: <new-doc-name>`.

### `created` (required, ISO date)

`YYYY-MM-DD` of doc creation. Never changes.

### `last_refresh` (required, ISO date)

`YYYY-MM-DD` of the most recent substantive update. Must be `>= created`.
For `immutable` docs, equals `created` and never changes. For `evolving`
/ `ephemeral` docs, owners bump this whenever they review the doc and
confirm it's still accurate.

### `freshness_window` (required, enum)

How long the doc is presumed authoritative after `last_refresh`. Values:

- `90d` — typical evolving doc (skills, area checklists).
- `180d` — slower-moving doc (architectural ADRs that still get touched).
- `365d` — annual review cadence.
- `never` — required for `type: immutable`; invalid for evolving /
  ephemeral.

### `owners` (required, non-empty list of strings)

Area slugs (e.g. `auth`, `audiobook`, `network`, `governance`,
`infrastructure`). Used by docs-decay to route stale-doc surfacing to the
right area. At least one owner; lowercase kebab-case.

## Optional fields

- **`supersedes`** — list of names of older docs this doc replaces. The
  named docs MUST have `superseded_by: <this-name>` set (validator checks
  reciprocity).
- **`superseded_by`** — name of the doc that replaces this one. MUST be
  set together with `status: superseded` for clean lifecycle.
- **`related`** — list of cross-link names; consumed by the query layer.
- **`description`** — single-line summary; recommended.

## Examples

### Immutable wall-failure entry

```yaml
---
name: 2026-05-27-pr1018-arch1
type: immutable
status: active
created: 2026-05-27
last_refresh: 2026-05-27
freshness_window: never
owners: [governance, infrastructure]
description: Submodule gitlinks accidentally staged as absolute-path symlinks.
---
```

### Evolving skill / area doc

```yaml
---
name: swarm-skill
type: evolving
status: active
created: 2026-04-15
last_refresh: 2026-05-21
freshness_window: 90d
owners: [governance]
description: Multi-module triage→dispatch→integrate→promote loop.
---
```

### Superseded ADR

```yaml
---
name: account-state-machine-v1
type: evolving
status: superseded
created: 2026-04-01
last_refresh: 2026-05-10
freshness_window: 180d
owners: [auth]
superseded_by: account-state-machine-v2
description: Original Phase 1 state-machine design.
---
```

## Validator surface

```bash
python3 ~/harness/core/lib/validate-doc-frontmatter.py [options]
```

| Flag | Effect |
| --- | --- |
| `--path ROOT` | Tree to walk (default `.`). |
| `--strict-windows` | Treat past-window `last_refresh` as a failure (not just a warning). |
| `--json` | Emit a JSON report to stdout (consumed by `harness docs-decay`). |
| `--quiet` | Suppress per-file stderr output; exit code only. |
| `--help` | Usage. |

Exit codes:

- `0` — all in-scope docs pass.
- `1` — one or more failed.
- `2` — usage error.

The validator's cross-doc consistency rules:

- **Unique `name`** — duplicate names across docs are an error.
- **Reciprocal supersession** — if `A.superseded_by = B`, then
  `B.supersedes` must contain `A`.
- **Type ↔ window coupling** — `immutable` requires `never`; `evolving` /
  `ephemeral` forbid `never`.

## Compatibility

This is `v1`. Schema changes that add optional fields are non-breaking and
do not bump the version. Changes that add required fields, remove fields,
or change enum values bump to `v2` (and the validator gains a `version:`
sniff to gate which checks run on which docs).
