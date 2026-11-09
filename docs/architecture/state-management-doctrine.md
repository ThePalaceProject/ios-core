# State-Management Doctrine (ADR)

**Status:** Accepted · supersedes the ambient,
undeclared conventions previously spread across `CLAUDE.md` and the code.
**Authority:** This is the single source of truth for *how state is held, mutated,
and observed* in Palace. If code and this doctrine disagree, one of them is a bug.
Most clauses are kept by review and by the tests named under each one; the
clauses that CI checks mechanically are listed in
[What CI checks](#what-ci-checks), and no other clause is machine-checked.

## Context

Palace had **excellent patterns but undeclared doctrine**. A unidirectional
`Store`, pure reducers, contract snapshots, and a single-source-of-truth registry
all exist — but nothing declared which is *canonical*, so multiple half-adopted
dialects accumulated by drift rather than decision. An adversarial source review
(verified, cited below) found: one production `Store` consumer among many
ViewModels; three separate `Effect` implementations; reducers that are
"shape-only" (pure state machine, but every branch returns `.none` and the
ViewModel still owns the effects); a registry that dual-writes to both Combine
publishers *and* a deprecated `NotificationCenter` post; a second book-state
owner; and a documented-but-unenforced legal-transition set.

The problem was never a shortage of good patterns. It was **unfinished migrations
and no stated rule**. This doctrine states the rule, converts the accidental
divergence into *bounded, named debt with finish-lines*, and names the test or
check that holds each clause where one exists.

## Decision — the two tiers

### 1. Reducer tier — critical-path state machines
Borrow, return, download, and sign-in are **critical-path state machines** and use
the `Store<State, Action, Environment>` + pure `reduce(&state, action) -> Effect`
dialect (`Palace/AppInfrastructure/Store.swift:50`). The reducer is a *pure
function* — no I/O, no `@Published` mutation, no singleton reads — so it is
testable with zero mocks and pinnable by contract snapshot.

Fact: today `Store` has **exactly one** production consumer —
`HoldsViewModel` (`Palace/Holds/HoldsViewModel.swift:56`). That is the beachhead,
not the finish line. This doctrine declares the *direction*: critical-path
decision logic migrates onto this dialect. The borrow, return and download
decision cores (`BorrowReducerCore`, `ReturnReducer`, `DownloadStartReducer`
in `Palace/MyBooks/`) are already extracted as pure functions with their own
contract tests; see [MyBooks pipeline shape](#mybooks-pipeline-shape--hub-effect-runners-decision-cores).

### 2. Leaf-UI tier — plain ObservableObject
Everything that is *not* a critical-path state machine — navigation, tab routing,
presentation, playback session UI — uses plain `@MainActor ObservableObject` with
`@Published` projections and **no `Store`**. Exemplars: `NavigationCoordinator`,
`AppTabRouter`, `AudiobookSessionManager`. This is deliberate: a `Store` for a
leaf view is the over-abstraction tax in a costume. Reducers earn their ceremony
only where a regression handles user money or access.

## Tracked debt — allowed, each with a finish line

Debt is permitted **only** when it is named here with a finish line. An
undeclared divergence is a doctrine violation; a declared one is a scheduled
repayment. No CI check watches these rows; a reviewer holds them, and the
finish line says what the code looks like when the debt is repaid.

| Debt | Where | Finish line |
|---|---|---|
| **Shape-only `BorrowReducer`** | `Palace/Book/UI/BookDetail/BorrowReducer.swift:117` | Integrated: `BookDetailViewModel` runs it at `:306` and `:833`. Every branch returns `.none` and the ViewModel still performs the borrow, download, return and cancel side effects. Repaid when at least one of those side effects is returned by the reducer as an `Effect` and run by its caller, instead of being started by the ViewModel. |
| **Shape-only `AuthReducer`** | `Palace/Packages/PalaceAuth/Sources/PalaceAuth/AuthReducer.swift:139` | Integrated: `TPPSignInBusinessLogic.authState` (`Palace/SignInLogic/TPPSignInBusinessLogic.swift:194`) is the source of truth for in-flight sign-in state, and every legacy `@objc` auth property is computed from it through `dispatch(_:)` (`:198`). All 12 branches return `.none`; token requests, credential saves and DRM activation still run in `TPPSignInBusinessLogic`. Repaid on the same terms as `BorrowReducer`. |
| **Duplicate `Effect`** | canonical at `Palace/AppInfrastructure/Store.swift:21`; mirror at `Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift:39` | Two copies, both with `Environment: Sendable`, because `PalaceAuth` cannot import the app module. Keep the mirror identical to the canonical type and do not add a third copy. Repaid when both move into one SPM module that the app target and `PalaceAuth` import. |

**`BorrowReducer` and `AuthReducer` are shape-only by declaration, not by
accident.** They are pure state machines, already integrated and covered by
`BorrowReducerTests`, `BorrowReducerContractTests` and `AuthReducerTests`; only
their effects have not moved across. That is the last step of a migration, not a
design defect.

## Out-of-family by design — NOT debt

`TriageBotCore.ConversationReducer`
(`Palace/Packages/PalaceTriageBot/.../ConversationReducer.swift:48`) uses a
deliberately different shape: `reduce(state, action) -> (state, effects:
[ConversationEffect])` — new state plus an array of reified effects. This is a
**separate product package** with its own evolution; it is declared
*out-of-family by design* and is explicitly **not** tracked debt. The doctrine
governs the app target's critical paths, not every package's internal choices.

## Single source of truth — scoped, not absolute

`TPPBookRegistry` (`Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/TPPBookRegistry.swift`) is the single
source of truth for book state — **scoped to loans**. It projects read-only
Combine publishers (`registryPublisher` / `bookStatePublisher` /
`syncEventPublisher` / `registryDidChangePublisher`); consumers observe, they never reach in and mutate.

`SideloadedBookRegistry` (`Palace/MyBooks/Sideload/SideloadedBookRegistry.swift`)
(`:24`) is a **documented second owner** for side-loaded content, exempt from
loans-feed reconciliation by design. "Single source of truth" is therefore
*scoped*, not violated: `PalaceTests/Contract/SideloadBoundaryTests.swift` pins
that each owner answers only for its own books and that importing a side-loaded
book never calls the loan owner's `setState`. No check counts book-state owners;
a third owner is a review finding.

## The one mutation point — enforced

`TPPBookState.allowedTransitions` (`Palace/Packages/PalaceBookModel/Sources/PalaceBookModel/TPPBookState.swift:93`,
`canTransition` at `:188`) is the declared legal-transition set. It is enforced
at the single mutation seam `TPPBookRegistry.setState`
(`Palace/Packages/PalaceBookRegistry/Sources/PalaceBookRegistry/TPPBookRegistry.swift:819`):
an illegal transition is logged in RELEASE (the state is still written, never
dropped) and fails an assertion in DEBUG, through the injectable
`IllegalTransitionHandler` (`:492`). `TPPBookRegistryMutationContractTests`
covers the handler.

The deprecated `NotificationCenter` dual-write (`postStateNotification`) is
**deleted**, not only marked deprecated: a deprecated post that still fires on
every `setState` keeps old observers working and hides them from review.

## Consequences

- **New code has a rule.** Critical-path state machine → reducer. Leaf UI →
  ObservableObject. A third dialect is a review finding; no check detects one.
- **Debt is bounded and scheduled**, not perpetual. Each shape-only reducer and
  the duplicate `Effect` has a written finish line.
- **The checks that exist are ratchets on ambient reach**, not on these clauses.
  See [What CI checks](#what-ci-checks).
- **The riskiest code becomes the most-verified.** Borrow/return/download decision
  logic moves onto the pure, snapshot-pinned reducer dialect, where a regression
  fails a test loudly instead of shipping to a patron.

## MyBooks pipeline shape — hub, effect-runners, decision cores

`MyBooksDownloadCenter` (~2.1k LOC) is **not a god-class awaiting decomposition**
— it is the already-decomposed *delegation hub* of the borrow/return/download
pipeline: wiring, delegate conformances, and URLSession/UIKit plumbing for its
~27 extracted collaborators. Do not re-triage it for extraction by line count,
and do not re-plumb the hub. The pipeline's declared shape is three layers:

1. **Hub** (`MyBooksDownloadCenter`) — wiring + delegate surface, no decisions.
2. **Effect-runners** (`BorrowOperation`, `BookReturnService`,
   `DownloadStartDispatcher`, …) — async I/O, DRM, alerts, registry writes.
3. **Pure decision cores** (`BorrowReducerCore`, `ReturnReducer`,
   `DownloadStartReducer`) — branch selection + effect ordering; no I/O, no
   singletons; 100%-mutation-testable.

New branch logic goes in a core; new side effects go in the effect-runner; new
collaborators get wired in the hub.

## Extraction discipline — pin, then extract

Moving decision logic out of an effect-runner (including repaying the
shape-only-reducer debt above) follows **pin-then-extract**: every branch of
the live service is characterization-pinned as a contract snapshot and green on
a clean re-run *before* any decision logic moves. The extracted core's contract
test then interprets its emitted effect plan into a `CallLog` using the same
labels the service snapshot recorded — **snapshot shape-equality is the
behavior-preservation proof**. An extraction without a pinned baseline is a
rewrite, not a refactor.

## What CI checks

These checks run on every pull request in `.github/workflows/tooling-checks.yml`.
The first two hold a baseline count and fail when the count rises; the other two
fail on any file or package that breaks their rule. None of them reads this
document.

| Check | What it bounds | Where CI runs it |
|---|---|---|
| `scripts/check-shared-read-count.sh` (baseline `scripts/godclass-shared-read-baseline.txt`) | `<Type>.shared` reads in app-target Swift under `Palace/` (SPM packages excluded) | `tooling-checks.yml` "pytest detector suite": `scripts/tests/test_check_shared_read_count.py::test_live_repo_baseline_passes` runs it on the whole tree |
| `scripts/check-appcontainer-locator-count.sh` (baseline `scripts/godclass-appcontainer-locator-baseline.txt`, allowlist `scripts/godclass-appcontainer-locator-allowlist.txt`) | `AppContainer.production()` used as a service locator outside composition roots | same step, `scripts/tests/test_check_appcontainer_locator_count.py::test_live_repo_baseline_passes` |
| `scripts/check-package-tests-wired.sh` | every SPM package under `Palace/Packages/` that has tests is run by CI | `tooling-checks.yml` step "package tests are wired (whole tree)" |
| `scripts/check-file-size-ceiling.sh` | code lines per app-target Swift file; a file over the ceiling fails unless allowlisted at a recorded size | `tooling-checks.yml` step "file-size ceiling (whole tree)" |

`scripts/verify-pr.sh` also runs all four as its `decomposition_ratchets` leg.
`scripts/tests/test_verify_pr_ratchet_wiring.sh` (run by the "verify-pr
detector wiring test" step) checks that `verify-pr.sh` still calls them.

The reducer-tier rule, the leaf-UI rule, the debt table, the single
`Effect` mirror and the single mutation point are not machine-checked. A new
check for one of them needs a real instance in the tree first; see the
"Adding a detector" rule in the repository `CLAUDE.md`.

## Flow descriptions come from the snapshots

The contract-snapshot JSON under `PalaceTests/Contract/__Snapshots__/` is the
record of each pinned flow's call order. When a document describes one of those
flows, take the order from the snapshot, not from memory, and cite the snapshot
file. No tool generates flow diagrams from the snapshots today.

## References
- `docs/architecture/architectural-triad.md` (MVVM + Services + Reducers rationale)
