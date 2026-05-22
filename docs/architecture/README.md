# Palace iOS Architecture Documentation

Engineering decisions and case studies for major architectural work in this codebase. These docs capture *why* we did things, not just *what* — the rationale future maintainers (and outside contributors curious about the design) need.

## Documents

| Doc | What it covers |
|---|---|
| [`architectural-triad.md`](./architectural-triad.md) | The post-modernization "honesty epic" — closing the gap between the modernize/whole-shot refactor's claimed state and the actual state, on three axes: dependency injection adoption, the Store reducer pattern, and the singleton / god-class purge. Plan, phases, exit criteria, decision log. |
| [`audiobook-systemic-overhaul.md`](./audiobook-systemic-overhaul.md) | Three-phase Palace-side refactor of the audiobook stack — vendor adapter extraction, position-writer unification, and singleton elimination. Closes six recurring failure patterns including the PP-4407 Marketplace regression class. Plan, per-phase outcomes, and the toolkit-side work that remains. <!-- audit-verified --> |
| [`parallel-agent-rebase-walkthrough.md`](./parallel-agent-rebase-walkthrough.md) | How we ran 5 concurrent refactor agents on disjoint file partitions and merged their work into a single linear stack via cherry-pick + rebase. The recipe, the conflict-avoidance strategy, what worked, what we'd change. |
| [`triad-retro-2026-04-27.md`](./triad-retro-2026-04-27.md) | Retrospective on the triad work after PRs landed. What delivered, what surprised us, process improvements for next time. |

## Why these are public

This is an open-source iOS reading app. Architecture decisions of this scope deserve daylight — they're the kind of context outside contributors need to make sense of the codebase, and they help anyone evaluating modernization patterns for their own iOS app.

The PRs that delivered this work are public:

- [#866 — Architectural Triad: DI adoption, Store pattern, singleton purge (Phases 1-4)](https://github.com/ThePalaceProject/ios-core/pull/866)
- [#867 — Architectural Triad: Borrow + Auth reducers (Phase 5)](https://github.com/ThePalaceProject/ios-core/pull/867)

Internal team members may have additional governance / planning docs that aren't published here (e.g. risk-scored changesets, gate evidence). Those are workflow artifacts, not architectural decisions, so they live elsewhere.
