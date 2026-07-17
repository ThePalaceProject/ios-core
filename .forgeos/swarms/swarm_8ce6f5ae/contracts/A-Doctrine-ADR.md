# Contract A — State-Management Doctrine ADR (WS1)

**Module:** docs/architecture (no production code)
**Risk:** standard (documentation; gates the WS5 probes in Contract F)
**Depends on:** none — **land this first; B/C/D/E reference it, F encodes it as probes**

## Goal
Declare ONE canonical state-management doctrine so the swarm's other contracts
have a single authority to conform to, and so drift becomes machine-checkable.

## Scope (exact files)
- CREATE `docs/architecture/state-management-doctrine.md`

## Off-limits
- Any file under `Palace/` (no production change in this contract)
- Any test file
- `docs/architecture/.arch/facts.json` (owned by Contract F)

## What the doctrine MUST declare (verified facts, cite them)
1. **Reducer tier — critical-path state machines** (borrow/return/download/sign-in)
   use the `Store` + pure `reduce(&state, action) -> Effect` dialect.
   - Fact: `Store` has exactly ONE production consumer today — `HoldsViewModel`
     (`Palace/Holds/HoldsViewModel.swift:52`). `Store` decl at
     `Palace/AppInfrastructure/Store.swift:50`.
2. **Leaf-UI tier** uses plain `@MainActor ObservableObject` (no Store). Name the
   exemplars: `NavigationCoordinator`, `AppTabRouter`, `AudiobookSessionManager`.
3. **Tracked debt WITH explicit finish-lines** — these are ALLOWED but must carry
   a named finish-line the WS5 probes enforce:
   - `BorrowReducer` (`Palace/Book/UI/BookDetail/BorrowReducer.swift:114`) and
     `AuthReducer` (`Palace/Packages/PalaceAuth/.../AuthReducer.swift:132`) are
     **shape-only** — every branch returns `.none`; the ViewModel owns effects.
     Finish-line: when effects move into the reducer, the `.none`-only probe flips.
   - **Duplicate `Effect`**: canonical `Effect` with `Sendable` bound lives at
     `Palace/AppInfrastructure/Store.swift:21`; `PalaceAuth` ships a second copy
     WITHOUT the `Sendable` bound at
     `Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift:11`. Doctrine
     must state the ALLOWED count (see Contract B) and the package-boundary reason.
   - `TriageBotCore.ConversationReducer` uses a deliberately DIFFERENT shape
     (`reduce(state, action) -> (state, effects: [ConversationEffect])`,
     `Palace/Packages/PalaceTriageBot/.../ConversationReducer.swift:48`). Doctrine
     must declare it **out-of-family by design** (separate product package), not debt.
4. **Single source of truth for book state** is `TPPBookRegistry`
   (`Palace/Book/Models/TPPBookRegistry.swift`). Doctrine must state the SoT is
   **scoped to loans**, and that `SideloadedBookRegistry`
   (`Palace/MyBooks/Sideload/SideloadedBookRegistry.swift:45`) is a documented,
   probe-guarded second owner for side-loaded content (see Contract D).
5. **`TPPBookState.allowedTransitions`** (`Palace/Book/Models/TPPBookState.swift:91`,
   `canTransition` at `:151`) is the declared legal-transition set and MUST be
   enforced at the single mutation point `TPPBookRegistry.setState`
   (`Palace/Book/Models/TPPBookRegistry.swift:605`) — see Contract C.

## Test contracts
None (documentation). The doctrine's testable assertions are realized as probes
in Contract F; this contract must phrase each debt item so a grep/absence probe
can encode it (e.g. "BorrowReducer contains no `.task`").

## Definition of Done — TWO TIERS ("ship today, verify Monday")
**TODAY (implementer):** doctrine authored; all AC greps below pass locally; the
debt items are phrased so Contract F can encode them as probes. No build needed
(pure doc). Transcript + DoD evidence pasted.
**MONDAY MERGE GATE (orchestrator):** `/forge-review` architect approves the
doctrine; Contract F's probes derived from it pass. Merges to `develop` only Monday.

## Verification criteria (orchestrator runs at Phase 4.5)
```bash
# AC1: file exists and is non-trivial
test -f docs/architecture/state-management-doctrine.md
test "$(wc -l < docs/architecture/state-management-doctrine.md)" -ge 60

# AC2: names the single Store consumer and both Effect sites
grep -q 'HoldsViewModel' docs/architecture/state-management-doctrine.md
grep -q 'PalaceAuth/Sources/PalaceAuth/Effect.swift' docs/architecture/state-management-doctrine.md

# AC3: declares the shape-only tracked debt with finish-lines
grep -Eq 'shape-only|shape only' docs/architecture/state-management-doctrine.md
grep -q 'BorrowReducer' docs/architecture/state-management-doctrine.md
grep -q 'AuthReducer' docs/architecture/state-management-doctrine.md

# AC4: declares SoT scoping + allowedTransitions enforcement point
grep -q 'SideloadedBookRegistry' docs/architecture/state-management-doctrine.md
grep -q 'allowedTransitions' docs/architecture/state-management-doctrine.md
grep -q 'setState' docs/architecture/state-management-doctrine.md

# AC5: declares TriageBot reducer out-of-family (not debt)
grep -Eq 'ConversationReducer|TriageBot' docs/architecture/state-management-doctrine.md
```
