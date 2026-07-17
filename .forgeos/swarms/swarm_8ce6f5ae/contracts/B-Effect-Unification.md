# Contract B — Effect Unification / Boundary Formalization (WS2)

**Module:** AppInfrastructure + Packages/PalaceAuth
**Risk:** critical_path (PalaceAuth is the sign-in package; AuthReducer lives here)
**Depends on:** A (doctrine declares the allowed Effect count + boundary reason)

## Verified starting facts
- Canonical `Effect` WITH `Sendable` bound: `Palace/AppInfrastructure/Store.swift:21`
  — `struct Effect<Action, Environment: Sendable>`.
- Second `Effect` WITHOUT `Sendable` bound: `Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift:11`
  — `public struct Effect<Action, Environment>`. Its own doc comment already
  frames itself as a temporary mirror ("when impl 4 wires the package, the
  main-target copy becomes redundant for auth callers").
- Third shape (NOT a collision): `TriageBotCore.ConversationReducer` returns
  `(state, effects: [ConversationEffect])` — a different, intentional shape in a
  separate product package. **Do NOT touch TriageBot.**

## Decision (pick ONE; the doctrine in A must agree)
The two `struct Effect` types cannot be trivially collapsed: PalaceAuth is a
standalone SPM package that must not import the app module. **Preferred, one-day
landable option: formalize the boundary (WS2 "OR" branch).**
- Add the missing `Sendable` bound to PalaceAuth's `Effect` so the two copies are
  *semantically identical* (closes the drift the review flagged).
- Add a documented header on PalaceAuth's `Effect.swift` stating WHY the copy
  exists (package boundary — reference `Palace/Packages/PalaceCatalog` as the SPM
  precedent for package-local mirrors) and the finish-line for eventual unification.
- Encode a Contract-F probe asserting the total `struct Effect` count is exactly
  **2, both Sendable-constrained** (N-justified), NOT 1.

Full collapse into a shared SPM module is explicitly a **gated follow-up**, not
this contract.

## Scope (exact files)
- `Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift` (add `Sendable`
  bound + boundary-reason doc header)
- (optional, if doctrine A chose collapse) NONE else — do not edit Store.swift's
  Effect signature; it is already canonical.

## Off-limits
- `Palace/AppInfrastructure/Store.swift` — canonical `Effect`/`Store` is frozen
  here; changing its signature ripples to `HoldsViewModel` (Contract-independent
  risk). Read-only.
- `Palace/Packages/PalaceTriageBot/**` — different-shape reducer by design.
- `Palace/Book/UI/BookDetail/BorrowReducer.swift`, `AuthReducer.swift` bodies —
  effect-authoring changes belong to a later tracked-debt finish-line, not here.

## What public types change
- `PalaceAuth.Effect<Action, Environment>` gains a `Sendable` constraint on
  `Environment` (matching the app copy). Verify PalaceAuth still compiles —
  `AuthEnvironment` must already be `Sendable` or become so.

## Test contracts
- PalaceAuth package tests must still pass (`AuthReducerTests`).
- If `AuthEnvironment` needs a `Sendable` conformance to satisfy the new bound,
  add a compile-level test (a `func _requireSendable<T: Sendable>(_:)` witness) in
  the PalaceAuth test target.

## Verification criteria (Phase 4.5)
```bash
# AC1: exactly two struct Effect decls in the app tree, no third crept in
test "$(grep -rl 'struct Effect<Action, Environment' Palace --include='*.swift' | wc -l | tr -d ' ')" = "2"

# AC2: BOTH Effect decls now carry the Sendable bound (drift closed)
grep -q 'struct Effect<Action, Environment: Sendable>' Palace/AppInfrastructure/Store.swift
grep -q 'Environment: Sendable' Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift

# AC3: PalaceAuth Effect.swift documents the package-boundary reason
grep -Eiq 'package boundary|boundary|import the app module' Palace/Packages/PalaceAuth/Sources/PalaceAuth/Effect.swift

# AC4: TriageBot untouched (different shape preserved)
grep -q 'effects: \[ConversationEffect\]' Palace/Packages/PalaceTriageBot/Sources/TriageBotCore/Reducer/ConversationReducer.swift
```
