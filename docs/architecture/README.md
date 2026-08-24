---
name: architecture-readme
type: evolving
status: active
created: 2026-04-27
last_refresh: 2026-08-24
freshness_window: 365d
owners: [general]
description: Palace iOS Architecture Documentation — index of every decision record
---

# Palace iOS Architecture Documentation

Why the code is shaped the way it is. These record the *reasoning* — the
constraint that is invisible from the source, the alternative that lost, the
failure that produced a rule — because that is the part the code cannot hold.

**Every document in this directory is listed below**, and
`scripts/check-doc-index-complete.py` fails the build if one is not. An
unindexed doc is one nobody finds, which costs every future search while helping
no one. New here? Read [`../README.md`](../README.md) for the wider map and for
where a new document belongs.

## Doctrine — read before changing shared structure

| Doc | What it covers |
|---|---|
| [`architectural-triad.md`](./architectural-triad.md) | The post-modernization "honesty epic": closing the gap between the refactor's claimed state and its actual state, across DI adoption, the Store reducer pattern, and the singleton/god-class purge. Plan, phases, exit criteria, decision log. |
| [`state-management-doctrine.md`](./state-management-doctrine.md) | Accepted rules for where state lives and who may mutate it. Supersedes the ambient convention that preceded it. |
| [`critical-path-review-policy.md`](./critical-path-review-policy.md) | What counts as a critical path, and the review bar a change to one must clear. |
| [`release-merge-policy.md`](./release-merge-policy.md) | Why merges into `main` use `--no-ff` and never squash — with the 296-conflict forensic that established the rule, and the recovery recipe. |

## Area verification checklists

What to re-verify when you touch an area, and which seams are load-bearing.
Refresh the relevant one before a swarm or rigorous-fix run.

| Area | Checklist |
|---|---|
| Accounts | [`areas/accounts/verification-checklist.md`](./areas/accounts/verification-checklist.md) |
| Audiobook | [`areas/audiobook/verification-checklist.md`](./areas/audiobook/verification-checklist.md) |
| Auth | [`areas/auth/verification-checklist.md`](./areas/auth/verification-checklist.md) |
| Holds | [`areas/holds/verification-checklist.md`](./areas/holds/verification-checklist.md) |
| MyBooks | [`areas/mybooks/verification-checklist.md`](./areas/mybooks/verification-checklist.md) |
| Network | [`areas/network/verification-checklist.md`](./areas/network/verification-checklist.md) |
| Reader | [`areas/reader/verification-checklist.md`](./areas/reader/verification-checklist.md) |
| Sign-in modal | [`areas/signin-modal/verification-checklist.md`](./areas/signin-modal/verification-checklist.md) |

## Decomposition and Swift 6

| Doc | What it covers |
|---|---|
| [`god-class-decomposition-plan.md`](./god-class-decomposition-plan.md) | The wave plan for breaking up the god classes into `Palace/Packages/*`. Extends the triad's Phases 6–7. The map for why files now live where they do. |
| [`singleton-census.md`](./singleton-census.md) | Captured inventory of `.shared` declarations and reads; feeds the `.shared`-read ratchet. |
| [`wave3-coupling-map.md`](./wave3-coupling-map.md) | Write-ahead characterization scouting for the decomposition — which seams are genuinely coupled versus incidentally adjacent. |
| [`wave2b-mutation-baseline.md`](./wave2b-mutation-baseline.md) | Recorded mutation baseline for the Wave 2b surfaces, captured 2026-07-27. A measurement, not a plan. |
| [`app-target-swift6-modernization-plan.md`](./app-target-swift6-modernization-plan.md) | The app target's route to Swift 6 language mode: phases, gates, and what each one is allowed to defer. |
| [`swift6-a5-remainder-plan.md`](./swift6-a5-remainder-plan.md) | What phase A5 deliberately left behind, and the order to take it in. |
| [`swift6-phaseB-followup.md`](./swift6-phaseB-followup.md) | Phase B's residue — the items that outlived the phase. |
| [`swift6-phaseC-handoff-2026-07-07.md`](./swift6-phaseC-handoff-2026-07-07.md) | Phase C handoff: state at the boundary, and what the next agent needs. |
| [`swift6-modernization-handoff-2026-07-02.md`](./swift6-modernization-handoff-2026-07-02.md) | Modernization handoff, 2026-07-02. |
| [`swift6-modernization-handoff-2026-07-06.md`](./swift6-modernization-handoff-2026-07-06.md) | Modernization handoff, 2026-07-06 — supersedes the 07-02 state. |

## Subsystem designs

| Doc | What it covers |
|---|---|
| [`account-state-machine.md`](./account-state-machine.md) | Systemic fix for the load-readiness race class: the account state machine, its transition table, and the races it closes. |
| [`audiobook-systemic-overhaul.md`](./audiobook-systemic-overhaul.md) | Three-phase Palace-side refactor of the audiobook stack — vendor adapter extraction, position-writer unification, singleton elimination. Closes six recurring failure patterns including the PP-4407 Marketplace regression class. <!-- audit-verified --> |
| [`in-app-navigation-during-playback.md`](./in-app-navigation-during-playback.md) | Design for letting users navigate the app while an audiobook plays or an ebook session is open. |
| [`sideloading-plan.md`](./sideloading-plan.md) | Sideloaded-content design: registry sync exemption, content-type handling, and the settings surface. |
| [`lcp-first-open-reliable-start.md`](./lcp-first-open-reliable-start.md) | Making the first open of an LCP title start reliably. DRAFT — proposed, not ratified. |
| [`ws3-overdrive-refulfill-loader-seam.md`](./ws3-overdrive-refulfill-loader-seam.md) | The loader seam that lets an expired OverDrive URL re-fulfill instead of failing. Accepted. |
| [`hermeticity-accountdetail-hang-fix-design.md`](./hermeticity-accountdetail-hang-fix-design.md) | Design for the AccountDetail hang, with the hermeticity problem that caused it. Investigation complete; design for review. |
| [`ipad-on-mac-exit-static-destructor-bypass.md`](./ipad-on-mac-exit-static-destructor-bypass.md) | Why iPad-on-Mac exits via `_exit(0)` to bypass static destructors, and what that costs. |
| [`ws4-mac-validation-runbook.md`](./ws4-mac-validation-runbook.md) | How to validate the Mac/iPad-on-Mac path, including the static-destructor bypass above. |

## Triage bot

| Doc | What it covers |
|---|---|
| [`triage-bot-v1-as-built.md`](./triage-bot-v1-as-built.md) | **Read before changing the triage bot.** Behavioral contracts, component architecture, corpus schema — several code comments in the package are stale where this document is correct. |
| [`triage-bot-shared-architecture-proposal.md`](./triage-bot-shared-architecture-proposal.md) | The forward design: a shared triage service across iOS, Android, and the Palace backend. |
| [`triage-bot-privacy-review.md`](./triage-bot-privacy-review.md) | The recorded privacy answer — what the bot collects, what leaves the device, and when. |
| [`triage-bot-telemetry-decision.md`](./triage-bot-telemetry-decision.md) | Where the bot's usage telemetry lands, plus the three metrics and starting thresholds. |
| [`triage-bot-remedy-delivery.md`](./triage-bot-remedy-delivery.md) | How remedies reach the user. Implemented on a spike branch, pending review. |

## Testing and verification machinery

| Doc | What it covers |
|---|---|
| [`mutation-testing.md`](./mutation-testing.md) | First-principles rationale for the mutation-testing system (`palace_mutate.py` and friends) — and what a mutation score cannot tell you. |
| [`critical-path-mutation-coverage.md`](./critical-path-mutation-coverage.md) | The regex methodology for deciding which surfaces are critical-path, with the recorded run that established the baseline. |
| [`phase-3.5-class-scan.md`](./phase-3.5-class-scan.md) | The wall-as-detector pattern: turning a class of failure into a mechanical pre-commit check. |
| [`superpartner-spectrum.md`](./superpartner-spectrum.md) | The pre-commit check that flags new code shipped without a test, and how its threshold was chosen. |
| [`runtime-quiescence-gate.md`](./runtime-quiescence-gate.md) | The runtime-quiescence gate: what it asserts and why a timeout is a failure even at zero assertions. |
| [`runtime-quiescence-gate-backlog.md`](./runtime-quiescence-gate-backlog.md) | Land-ready quiescence designs not blocking the current release. |
| [`pr-report-contract.md`](./pr-report-contract.md) | What a PR body must claim and how those claims are reconciled against the diff. |
| [`readium-money-path-validation.md`](./readium-money-path-validation.md) | One entry per Readium pin, added in the change that moves it. Readium renders and decrypts borrowed content, so a bump can break borrow/fulfillment/playback with no compile error. |
| [`readium-upgrade-validation.md`](./readium-upgrade-validation.md) | The validation procedure a Readium upgrade must pass before the pin moves. |

## Process, retrospectives, and reviews

| Doc | What it covers |
|---|---|
| [`swarm-workflow.md`](./swarm-workflow.md) | The `/swarm` multi-module orchestration loop: triage, dispatch, integrate, promote. |
| [`swarm-rigor-followups.md`](./swarm-rigor-followups.md) | The backlog of rigor gaps swarm runs exposed. |
| [`parallel-agent-rebase-walkthrough.md`](./parallel-agent-rebase-walkthrough.md) | How five concurrent refactor agents on disjoint file partitions were merged into one linear stack via cherry-pick + rebase. The recipe, the conflict-avoidance strategy, and what we would change. |
| [`triad-retro-2026-04-27.md`](./triad-retro-2026-04-27.md) | Retrospective on the triad work after the PRs landed. |
| [`pp4156-retro-2026-05-04.md`](./pp4156-retro-2026-05-04.md) | Retrospective on the PP-4156 audiobook download indicator. |
| [`session-observability-context.md`](./session-observability-context.md) | How session observability feeds session-start context. |
| [`reviews/2026-08-remedy-ladder-review.md`](./reviews/2026-08-remedy-ladder-review.md) | The remedy-ladder review, recovered verbatim from the reviewing agent's transcript on 2026-08-14. Kept as the input the remedy design was distilled from. |

## Why these are public

This is an open-source iOS reading app. Architecture decisions of this scope
deserve daylight — they are the context an outside contributor needs to make
sense of the codebase, and they help anyone evaluating modernization patterns for
their own app. The PRs that delivered the triad work are public:
[#866](https://github.com/ThePalaceProject/ios-core/pull/866) and
[#867](https://github.com/ThePalaceProject/ios-core/pull/867).

Governance and planning artifacts — risk-scored changesets, gate evidence, agent
run records — are **not** architecture and do not live here. See
[`../../.forgeos/README.md`](../../.forgeos/README.md).
