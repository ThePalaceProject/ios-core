# Contract D — Sideload SoT Boundary (WS4) · Implementer transcript

**Status:** _pending evidence_ (build/mutation/tests below)
**Branch:** feat/inapp-nav-firebase-killswitch (staged, NOT committed — for integrator)

## Summary

Formalized `SideloadedBookRegistry` as the documented, probe-guarded **second
book-state owner**, viewed alongside the loans SoT through **one read seam**, per
the state-management doctrine's "single source of truth — scoped, not absolute"
clause. No unification of the two registries (explicitly out of scope); no
`TPPBookRegistry` internals touched (Contract C's scope).

Three deliverables:

1. **Read seam** — new `BookStateReading` protocol (`func state(for:) -> TPPBookState`)
   that both authorized owners are viewed through. `SideloadedBookRegistry`
   conforms (new file); the loan owner already exposes `state(for:)` via
   `TPPBookRegistryProvider` and is documented as the other authorized conformer
   (its production conformance is left to Contract C to avoid a cross-contract
   file collision). The doctrine's "exactly two owners" is realized as a real,
   testable seam rather than only prose.

2. **Doc header** on `SideloadedBookRegistry.swift` declaring it the AUTHORIZED
   SECOND owner, scoped to side-loaded (non-loan) content, that MUST NOT track
   loan state, never calls `setState`, and never reconciles against the loan
   owner. References the doctrine + Contract D.

3. **`state(for:)` projection** on `SideloadedBookRegistry`: a book it owns →
   `.downloadSuccessful` (matching how side-loaded books are registered into the
   main registry); any identifier it does not own (incl. every loaned book) →
   `.unregistered`. Membership-derived only; never a loan-state authority.

## Files

**Production**
- `Palace/MyBooks/Sideload/BookStateReading.swift` (NEW) — read seam + doc +
  `SideloadedBookRegistry` conformance. Registered in pbxproj (both targets) via
  `scripts/pbxproj_add_swift.rb`.
- `Palace/MyBooks/Sideload/SideloadedBookRegistry.swift` (EDIT) — authorized-
  second-owner header block + `state(for:)` read method.

**Tests**
- `PalaceTests/Contract/SideloadBoundaryTests.swift` (NEW) — boundary tests.
  Registered in pbxproj (PalaceTests target).

## Tests (SideloadBoundaryTests) — what each pins

- `testState_forUnknownIdentifier_isUnregistered` — unknown id → `.unregistered`.
- `testState_forNilIdentifier_isUnregistered` — nil guard.
- `testState_afterAdd_isDownloadSuccessful` — owned id → `.downloadSuccessful`.
- `testState_afterRemove_returnsToUnregistered` — state follows membership.
- `testTwoOwners_answerOnlyForTheirOwnBooks_andNeverReconcile` — heterogeneous
  `[BookStateReading]`; each owner returns `.unregistered` for the OTHER owner's
  book → disjoint, non-reconciling ownership.
- `testImport_registersDownloadSuccessful_butNeverCallsSetState` — importing a
  side-loaded book calls `addBook(.downloadSuccessful)` exactly once and NEVER
  `setState` on the loan owner (spy asserts 0 calls). This is the core boundary:
  registering side-load content does not drive a loan-state transition.

No existing snapshot touched (existing `SideloadImportContractTests` +
`__Snapshots__/SideloadImportContractTests/importEpub.json` unchanged) → AC4 holds.

## Gaps / notes for integrator

- Production `TPPBookRegistry: BookStateReading` conformance intentionally NOT
  added here (its file is Contract C's). The mock conforms in the test target to
  exercise the shared seam. Contract C can add a one-line empty conformance
  extension (its `state(for:)` already matches the requirement).
- No behavior change to any existing method; only additive (`state(for:)`, header,
  new protocol).

## Definition-of-done evidence

### Check 1 — compile clean
_pending — see build output_

### Check 2 — diff-scoped mutation (100% on new logic)
_pending_

### Check 3 — targeted tests (Executed N, 0 failures)
_pending_

## Verification criteria (contract AC block) — clean-tree recheck
- AC1 (`grep -Eiq 'second (book-?state )?owner|side-?loaded|scoped to' …Registry.swift`): PASS
- AC2 (anchored owner count == 2): PASS
- AC3 (`grep -Rq 'SideloadedBookRegistry' PalaceTests/Contract/`): PASS
- AC4 (`__Snapshots__/SideloadImportContractTests` dir exists, untouched): PASS
