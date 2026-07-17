# State-Management Doctrine (ADR)

**Status:** Accepted · swarm `swarm_8ce6f5ae` (WS1) · supersedes the ambient,
undeclared conventions previously spread across `CLAUDE.md` and the code.
**Authority:** This is the single source of truth for *how state is held, mutated,
and observed* in Palace. Contracts B–F of this campaign conform to it; Contract F
encodes its checkable clauses as `arch drift` probes over
`docs/architecture/.arch/facts.json`. If code and this doctrine disagree, one of
them is a bug — and the probe says which.

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
divergence into *bounded, named debt with finish-lines*, and makes each clause
mechanically enforceable so it cannot silently rot again.

## Decision — the two tiers

### 1. Reducer tier — critical-path state machines
Borrow, return, download, and sign-in are **critical-path state machines** and use
the `Store<State, Action, Environment>` + pure `reduce(&state, action) -> Effect`
dialect (`Palace/AppInfrastructure/Store.swift:50`). The reducer is a *pure
function* — no I/O, no `@Published` mutation, no singleton reads — so it is
testable with zero mocks and pinnable by contract snapshot.

Fact: today `Store` has **exactly one** production consumer —
`HoldsViewModel` (`Palace/Holds/HoldsViewModel.swift:52`). That is the beachhead,
not the finish line. This doctrine declares the *direction*: critical-path
decision logic migrates onto this dialect (see Contract E, which extracts
`ReturnReducer` / `BorrowReducerCore` / `DownloadStartReducer` cores).

### 2. Leaf-UI tier — plain ObservableObject
Everything that is *not* a critical-path state machine — navigation, tab routing,
presentation, playback session UI — uses plain `@MainActor ObservableObject` with
`@Published` projections and **no `Store`**. Exemplars: `NavigationCoordinator`,
`AppTabRouter`, `AudiobookSessionManager`. This is deliberate: a `Store` for a
leaf view is the over-abstraction tax in a costume. Reducers earn their ceremony
only where a regression handles user money or access.

## Tracked debt — ALLOWED, but each carries a finish-line probe

Debt is permitted **only** when it is named here with a finish-line that Contract
F's probe enforces. An un-declared divergence is a doctrine violation; a declared
one is a scheduled repayment.

| Debt | Where | Finish-line (probe flips when repaid) |
|---|---|---|
| **Shape-only `BorrowReducer`** | `Palace/Book/UI/BookDetail/BorrowReducer.swift:114` | Every branch returns `.none`; the ViewModel owns effects. Repaid when effects move into the reducer — the `absent: .task` probe flips to a real effect. |
| **Shape-only `AuthReducer`** | `Palace/Packages/PalaceAuth/.../AuthReducer.swift:132` | All branches `.none`; `TPPSignInBusinessLogic` owns effects. Same finish-line as above. |
| **Duplicate `Effect`** | canonical `Sendable`-bound at `Palace/AppInfrastructure/Store.swift:21`; second copy WITHOUT the `Sendable` bound in `PalaceAuth` at `Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift:11` | Allowed count is fixed by Contract B (the package boundary reason is that `PalaceAuth` must not import the app module). A `count` probe pins the number so a *third* copy cannot appear silently. |

**`BorrowReducer` and `AuthReducer` are shape-only by declaration, not by
accident** — they are pure state machines already extracted and contract-tested;
only their effects have not yet moved across. That is the *last* step of a
migration, captured mid-stride, not a design defect.

## Out-of-family by design — NOT debt

`TriageBotCore.ConversationReducer`
(`Palace/Packages/PalaceTriageBot/.../ConversationReducer.swift:48`) uses a
deliberately different shape: `reduce(state, action) -> (state, effects:
[ConversationEffect])` — new state plus an array of reified effects. This is a
**separate product package** with its own evolution; it is declared
*out-of-family by design* and is explicitly **not** tracked debt. The doctrine
governs the app target's critical paths, not every package's internal choices.

## Single source of truth — scoped, not absolute

`TPPBookRegistry` (`Palace/Book/Models/TPPBookRegistry.swift`) is the single
source of truth for book state — **scoped to loans**. It projects read-only
Combine publishers (`registryPublisher` / `bookStatePublisher` /
`syncStatePublisher`); consumers observe, they never reach in and mutate.

`SideloadedBookRegistry` (`Palace/MyBooks/Sideload/SideloadedBookRegistry.swift:45`)
is a **documented, probe-guarded second owner** for side-loaded content, exempt
from loans-feed reconciliation by design (see Contract D). "Single source of
truth" is therefore honestly *scoped*, not silently violated — the boundary is
declared and a probe guards it against a third owner appearing.

## The one mutation point — enforced

`TPPBookState.allowedTransitions` (`Palace/Book/Models/TPPBookState.swift:91`,
`canTransition` at `:151`) is the declared legal-transition set. It MUST be
enforced at the single mutation seam `TPPBookRegistry.setState`
(`Palace/Book/Models/TPPBookRegistry.swift:605`) — log-only in RELEASE (never
drops state), assert in DEBUG (see Contract C). An unenforced invariant is a
comment; this doctrine promotes it to an enforced rule so illegal transitions
become detectable instead of merely discouraged.

Correspondingly, the deprecated `NotificationCenter` dual-write
(`postStateNotification`) is **deleted**, not merely marked deprecated — a
"deprecated" post that still fires on every `setState` is a lie the doctrine
does not tolerate (Contract C).

## Consequences

- **New code has a rule.** Critical-path state machine → reducer. Leaf UI →
  ObservableObject. No third dialect appears by drift; if one does, a probe reddens.
- **Debt is bounded and scheduled**, not perpetual. Each shape-only reducer and
  the duplicate `Effect` has a finish-line a machine watches.
- **The doctrine is executable.** Contract F derives `absent` / `count` /
  `contains` probes from these clauses, wired into
  `.github/workflows/tooling-checks.yml`, so the architecture cannot silently
  drift from what this document says.
- **The riskiest code becomes the most-verified.** Borrow/return/download decision
  logic moves onto the pure, snapshot-pinned reducer dialect, where a regression
  fails a test loudly instead of shipping to a patron.

## References
- Extracted architecture facts: `docs/architecture/.arch/facts.json`
- `docs/architecture/architectural-triad.md` (MVVM + Services + Reducers rationale)
- Contracts B (Effect boundary), C (registry dual-write kill + transition
  enforcement), D (Sideload SoT boundary), E (pin-then-extract cores),
  F (self-verifying probes) — `.forgeos/swarms/swarm_8ce6f5ae/contracts/`
