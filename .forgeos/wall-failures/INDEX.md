# Wall-failure catalog — index

One line per entry. Sortable by date, wall, status. Most recent first.

| Date | PR | Wall | Severity | Status | Entry | One-line |
|------|----|------|----------|--------|-------|----------|
| 2026-05-27 | #1018 | implementer | high | proposed | [arch1-discipline](2026-05-27-pr1018-arch1.md) | 7 submodule gitlinks accidentally staged as symlinks |
| 2026-05-27 | #1018 | contract | medium | proposed | [arch2-fake-wiring-test](2026-05-27-pr1018-arch2.md) | Wiring test claimed production round-trip but built fresh spies |
| 2026-05-27 | #1018 | contract+implementer | high | proposed | [arch3-dead-classifier-call](2026-05-27-pr1018-arch3.md) | TPPNetworkResponder called classifier but only logged outcome — legacy path still ran |
| 2026-05-27 | #1018 | implementer+mutation | high | proposed | [qa1-half-done-test](2026-05-27-pr1018-qa1.md) | Circuit-breaker test ran ONE attempt; second half was comments |
| 2026-05-27 | #1018 | contract+orchestrator | critical | proposed | [qa2-fake-test-instantiation](2026-05-27-pr1018-qa2.md) | TPPNetworkResponderAuthCoordinatorTests never instantiated TPPNetworkResponder |
| 2026-05-27 | #1018 | contract+orchestrator | critical | proposed | [qa3-fake-test-instantiation](2026-05-27-pr1018-qa3.md) | BookReturnServiceAuthCoordinatorTests never instantiated BookReturnService |

## Cluster patterns (updated when a cluster emerges)

- **fake-test-instantiation (2)**: tests with names referencing a SUT they never instantiate. Source: contract + orchestrator. Cluster fix: contract template requires `grep -c "<SUT>(" <test-file>" ≥ 1` as a verification criterion; orchestrator runs the same grep at Phase 4.5.
- **dishonest migration (1)**: production code calls new function and discards/ignores result while legacy path still runs. Source: contract + implementer. Cluster fix: contract template requires `grep -E "= newFn|let _ = newFn|newFn\(\).*outcome" + reviewer-checklist clause.
- **half-done tests (1)**: test body has named scenario but commented-out steps. Source: implementer + mutation. Cluster fix: implementer self-check must run mutation before READY; mutation kill of newly-added test class < 100% on its own lines = block.

Re-evaluate clusters monthly OR after every ~10 entries.
