---
name: wall-failures-index
type: evolving
status: active
created: 2026-05-28
last_refresh: 2026-05-28
freshness_window: 365d
owners: [general]
description: Wall-failure catalog — index
---

# Wall-failure catalog — index

One line per entry. Sortable by date, wall, status. Most recent first.

| Date | PR | Wall | Severity | Status | Contributing-docs? | Entry | One-line |
|------|----|------|----------|--------|--------------------|-------|----------|
| 2026-05-28 | cs_9a267b63 (swarm_18b0d071) | contract+implementer+DoD-check-7 | high | proposed | N | [arch1-fake-wiring-3rd-recurrence](2026-05-28-cs9a267b63-arch1.md) | SignInModalLifecycleTests Test 3 — name claims `_TPPReauthenticatorPath_invokesPresentationViaSafelyPresent` but body never instantiates TPPReauthenticator and bypasses production driver. SECOND consecutive wave hit — proves documentation-only DoD clauses don't catch recurrence; runnable greps required |
| 2026-05-28 | cs_847892e8 (swarm_c8fcab76) | contract+implementer+mutation | high | proposed | N | [arch1-fake-wiring-recurrence](2026-05-28-cs847892e8-arch1.md) | AudiobookFirstOpenHangTests recurrence of arch2 pattern — production wiring at AudiobookSessionManager.swift:684-710 never reached because rigor improvements (#1019) weren't on the base branch when this swarm dispatched |
| 2026-05-28 | n/a (backtest) | reviewer | high | proposed | N | [backtest-2026-05-28](backtest-2026-05-28.md) | Paper analysis of 10 prior shipped bugs vs. SoD reviewer agent prompts — 0% definitive WOULD-CATCH; 5 prompt-addition recommendations |
| 2026-05-27 | #1018 | implementer | high | proposed | N | [arch1-discipline](2026-05-27-pr1018-arch1.md) | 7 submodule gitlinks accidentally staged as symlinks |
| 2026-05-27 | #1018 | contract | medium | proposed | N | [arch2-fake-wiring-test](2026-05-27-pr1018-arch2.md) | Wiring test claimed production round-trip but built fresh spies |
| 2026-05-27 | #1018 | contract+implementer | high | proposed | N | [arch3-dead-classifier-call](2026-05-27-pr1018-arch3.md) | TPPNetworkResponder called classifier but only logged outcome — legacy path still ran |
| 2026-05-27 | #1018 | implementer+mutation | high | proposed | N | [qa1-half-done-test](2026-05-27-pr1018-qa1.md) | Circuit-breaker test ran ONE attempt; second half was comments |
| 2026-05-27 | #1018 | contract+orchestrator | critical | proposed | N | [qa2-fake-test-instantiation](2026-05-27-pr1018-qa2.md) | TPPNetworkResponderAuthCoordinatorTests never instantiated TPPNetworkResponder |
| 2026-05-27 | #1018 | contract+orchestrator | critical | proposed | N | [qa3-fake-test-instantiation](2026-05-27-pr1018-qa3.md) | BookReturnServiceAuthCoordinatorTests never instantiated BookReturnService |

## Cluster patterns (updated when a cluster emerges)

- **fake-wiring-test (3)**: tests claim to exercise the production seam but the test setup short-circuits before the wired code runs. Sources: arch2 (PR #1018), arch1 (cs_847892e8), arch1 (cs_9a267b63). **SECOND consecutive wave** — the cluster fix from cs_847892e8 (CLAUDE.md DoD check #7, swarm SKILL.md contract clause) landed in PR #1022 (THIS swarm's base) but DID NOT prevent recurrence. **Escalated cluster fix:** make Phase 4.5 check 5b RUNNABLE not documented — script `~/harness/core/lib/check-test-name-vs-body.py` parses test method names with embedded class-nouns and greps body for noun instantiation; fails the swarm at integration time if mismatch. Also extend implementer DoD check #1 to METHOD-level (not just file-level) noun-instantiation check.
- **fake-test-instantiation (2)**: tests with names referencing a SUT they never instantiate. Source: contract + orchestrator. Cluster fix: contract template requires `grep -c "<SUT>(" <test-file>" ≥ 1` as a verification criterion; orchestrator runs the same grep at Phase 4.5.
- **dishonest migration (1)**: production code calls new function and discards/ignores result while legacy path still runs. Source: contract + implementer. Cluster fix: contract template requires `grep -E "= newFn|let _ = newFn|newFn\(\).*outcome" + reviewer-checklist clause.
- **half-done tests (1)**: test body has named scenario but commented-out steps. Source: implementer + mutation. Cluster fix: implementer self-check must run mutation before READY; mutation kill of newly-added test class < 100% on its own lines = block.
- **rigor-propagation-lag (meta, from arch1)**: rigor-PR-derived contract changes (#1019) didn't take effect for the next-after-next swarm (c8fcab76) because they hadn't merged to develop when c8fcab76 dispatched. Cluster fix: fast-track rigor-PR merges; future-fix: have the architect fetch from the latest rigor branch even if it isn't yet merged.

Re-evaluate clusters monthly OR after every ~10 entries.
