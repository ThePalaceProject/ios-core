---
name: superpartner-spectrum
type: evolving
status: active
created: 2026-06-03
last_refresh: 2026-06-03
freshness_window: 365d
owners: [general]
description: "Superpartner Spectrum — a pre-commit check that flags new code shipped without a test"
---

# Superpartner Spectrum — flag new code that shipped without a test

**Status:** Proposed (2026-06-03). Wired warn-only into `verify-pr.sh` and the
`scripts/git-hooks/pre-commit` checks. Implemented by
`scripts/check-superpartner-spectrum.py`.

## What it does

It scans a diff for three kinds of new code:

- **new functions**
- **new enum cases**
- **new state changes** (`setState(…)`, `_setState(…)`, `self.state = …`)

…and warns about any of them that don't have a matching test in the same
change. That's it. The whole idea is one question: **"you added this — did you
add a test for it?"**

It runs in seconds on every commit, so it catches the simplest and most common
gap — shipping a new function or case with zero tests — before it ever reaches
review.

## What it does *not* do

It does **not** prove your test is any good. A test can mention a function and
still not really exercise it (we've shipped exactly those — see the
`.forgeos/wall-failures/` catalog). Proving a test actually catches bugs is a
different, slower tool: **mutation testing** (`scripts/palace_mutate.py`), which
runs before release.

So there are two levels, and they work together:

| Level | Tool | Question | Speed |
|---|---|---|---|
| 1 | this check | Is there a test at all? | seconds, every commit |
| 2 | mutation testing | Does the test actually catch bugs? | minutes, pre-release |

Level 1 is the cheap safety net. Level 2 is the real proof. Neither replaces the
other — this check just makes sure you never *skip* level 1 by accident.

## How "has a test" is decided

| New code | Counts as tested when… |
|---|---|
| **function** | a `func test…` name mentions it, or an added test line calls it directly |
| **enum case** | the case name appears anywhere in the added test code |
| **state change** | a round-trip test (name has reset / roundtrip / across / reenter / redrive and mentions the value), or any test that references the value |

The matching is deliberately generous. We'd rather occasionally say "this looks
tested" when it's thin than cry wolf on code that's actually covered — false
alarms are how a check loses trust and gets ignored. Mutation testing is the
backstop that catches a thin test.

For enum cases specifically, a new case usually deserves a test that pins *what
it means*. This comes straight from a real bug: `.accountNotFound` was used to
mean two different things (a real failure **and** an eviction marker), and
nothing tested the difference. See the wall-failure catalog.

## Skipping a test on purpose is fine — just say so

Some new code genuinely has no behavior worth testing: a fire-and-forget
analytics call, an empty delegate stub. Mark it with a comment on the same or
previous line:

```swift
// no-superpartner: fire-and-forget analytics, no observable behavior
func logBorrowTelemetry() { analytics.track("borrow") }
```

(`// no-superpartner(TICKET-123): …` also works.)

Marked items are counted and shown in the summary, but they never block. The
point is to make "we chose not to test this" a **visible, deliberate decision**
instead of a silent gap. This matches how `check-blast-radius.py` already lets
you justify a discarded result with `// TODO(ticket):`.

## What it doesn't look at: branches

`if` / `guard` / `switch` branches are **not** checked here. Matching an
individual branch to a test by name is too unreliable to be useful, so it would
just produce noise. Branch coverage is mutation testing's job. The summary line
says this on every run, so the gap is never hidden.

## Severity and which findings block

- **high** — untested new code on a **critical path**: auth, sign-in, borrow,
  return, download, DRM, audiobooks, migrations, or the auth-error seam
  (`TPPNetworkResponder` / `TPPNetworkExecutor`). These are the paths where a
  regression hits real users, so "air-tight" is the bar regardless of size.
- **medium** — untested new code anywhere else, or any untested state change.

The default level is **high**, so only critical-path findings can ever block. A
medium finding is advisory — it shows up, but it won't fail your build.

## Rollout: warn-only first

This follows the same path the `adjacency-staleness` check took: **warn-only at
both layers to start.** It surfaces findings but never fails a commit or the
PR battery yet, so we can watch it on real changes and confirm it isn't noisy
before letting it block anything.

A quick backtest over the last 5 commits (2026-06-03) showed the medium tier
carries some expected noise (localized-string helpers, feature-flag enum cases,
UIKit `@objc` button handlers), while the high tier produced exactly one real
finding: `stopPlayback` was added to `AudiobookSessionManager` (an audiobook
critical path) with no test referencing it in that change. That's precisely the
kind of thing we want flagged.

**To turn on blocking** (do this only after the warn-only period confirms the
high tier rarely false-alarms):

1. In `scripts/git-hooks/pre-commit`, move the `superpartner_spectrum` line out
   of the warn-only `|| true` form and into the `if ! run_m1_check …; then
   M1_FAIL++` form, so it counts toward the block decision.
2. In `scripts/verify-pr.sh`, change the failure branch from `record … "pass"`
   to `record … "fail"`.

## If it ever lets a bug through

If this check **passes** a change that later regresses because new code shipped
without a real test, that's a hole in the check itself. File it under
`.forgeos/wall-failures/` per the catalog protocol and propose the fix (a new
code kind to detect, a tighter matching rule) that closes the hole — not just
"be more careful next time."

## Where the name comes from (optional)

You don't need this to use the tool. The name is a nod to *supersymmetry*, a
physics idea where every particle has a partner particle. The analogy here is
simple: every new piece of code should have a partner test. That's the whole
borrowed idea — no physics required. Everything above is plain English on
purpose.
