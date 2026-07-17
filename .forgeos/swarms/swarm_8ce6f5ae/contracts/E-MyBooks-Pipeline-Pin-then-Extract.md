# Contract E — MyBooks Pipeline: PIN (WS6) then EXTRACT (WS7)

**Module:** MyBooks (+ PalaceTests/Contract, CLAUDE.md doc fix)
**Risk:** critical_path (borrow / return / download / DRM fulfillment — patron access)
**Depends on:** A (doctrine declares the target reducer shape)

> **HARD INTERNAL ORDERING — non-negotiable, one implementer owns both halves.**
> **Phase E1 (WS6) characterization contracts MUST be green before Phase E2 (WS7)
> changes ANY behavior.** WS6 and WS7 are in this single contract precisely so no
> implementer can reorder them. Do not open E2 until every E1 snapshot passes.

## Verified starting facts
- `MyBooksDownloadCenter.swift` is **2155 LOC / 106 KB** — the god-class.
  `BorrowOperation.swift` 989 LOC; `BookReturnService.swift` 744 LOC.
- Existing contract coverage already present: `BorrowOperationContractTests`,
  `BookReturnServiceContractTests`, `DownloadStartCoordinatorContractTests`,
  `BorrowReducerContractTests` (+ snapshot dirs). **WS6 fills the GAPS, not from zero.**
- **Undocumented return branches to pin (verified in `BookReturnService.swift`):**
  - No-`revokeURL` path: `if book.revokeURL == nil` (`:316`) →
    `handleReturnWithoutRevokeURL` → order is `setState(.unregistered)` (`:402`)
    **then** `removeBook` (`:403`).
  - OverDrive revoke whose OPDS parse FAILS is treated as **server-success**:
    the OverDrive XML is not a valid OPDS feed → parser throws
    `PalaceError.parsing(.opdsFeedInvalid)` (`:415-417`), and the catch still runs
    local cleanup `setState(.unregistered)` (`:429`) + `removeBook` (`:430`).
  - Default/other cleanup paths also do `setState` then `removeBook`
    (`:457-458`, `:622-623`).
- **CLAUDE.md return-order claim is at line 259**:
  "BookReturnService → setProcessing → setState → removeBook → announce.returnSucceeded".
  Verify this against the ACTUAL snapshot; the normal path uses
  `updateAndRemoveBook` (`:592`) — if the pinned order diverges from line 259, FIX line 259.

---

## Phase E1 — WS6 PIN THE GOD-CLASS (do first; must be green before E2)

### Scope
- EXTEND `PalaceTests/Contract/BookReturnServiceContractTests.swift` with a
  scenario per undocumented branch:
  - `returnBook_noRevokeURL_cleansUp_setStateThenRemove`
  - `returnBook_overdriveRevokeParseFail_treatedAsSuccess_cleansUpLocally`
  - (confirm existing coverage for the normal `revokeURL` path + the offline
    `OfflineAction(.return)` no-local-cleanup branch; add if missing)
- EXTEND `PalaceTests/Contract/BorrowOperationContractTests.swift` if any borrow
  branch (reserved→.holding, ready→.downloadNeeded, streaming-HTML skip, timeout)
  is not already snapshotted.
- FIX `CLAUDE.md:259` to state the ACTUAL pinned return order (only if it diverges).
- Record baselines (`CONTRACT_SNAPSHOT_RECORD=1`), review `git diff` of the JSON,
  commit the snapshots. Snapshots land under
  `PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests/`.

### E1 exit gate (BLOCKS E2)
All new + existing MyBooks contract snapshots pass on a clean re-run (no
`snapshot recorded — re-run to verify`), full-suite green for the Contract bundle.

---

## Phase E2 — WS7 EXTRACT (behavior-preserving; only after E1 green)

> **Realistic one-day scope: build the pure reducer CORE as a SEAM, snapshot-tested,
> WITHOUT rewiring the 2155-LOC god-class.** A full cutover of MyBooksDownloadCenter
> to the reducer is a MULTI-DAY gated follow-up — do NOT attempt the cutover here.

### Scope
- CREATE a pure core, e.g. `Palace/MyBooks/ReturnReducer.swift` (and/or
  `DownloadPipelineReducer.swift`): `reduce(&state, action) -> Effect`-shaped,
  modelling the return/download decision tree (revokeURL present/absent,
  OverDrive-parse-fail-as-success, offline-enqueue) as PURE state transitions.
  Register via `scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM`.
- The reducer MUST reproduce the E1-pinned call ORDER when its emitted effects are
  interpreted — prove it with a NEW `PalaceTests/Contract/ReturnReducerContractTests.swift`
  whose snapshot MATCHES the E1 `BookReturnServiceContractTests` sequence shape.
- Leave `BookReturnService` / `MyBooksDownloadCenter` as the live path (unchanged
  behavior). Optionally add ONE narrow, flagged seam where the service delegates a
  single decision to the reducer, guarded so the legacy path is the default.

### Off-limits (both phases)
- `Palace/Book/Models/TPPBookRegistry.swift` / `TPPBookState.swift` (Contract C)
- `Palace/MyBooks/Sideload/**` (Contract D)
- `Palace/AppInfrastructure/Store.swift` / PalaceAuth `Effect.swift` (Contract B)
- The MyBooksDownloadCenter `.TPPBookRegistryStateDidChange` one-shot observer at
  `:2076` — do NOT migrate it (that's Contract C's tracked debt; leave as-is).
- No production behavior change is permitted in E1. No god-class cutover in E2.

### What public types change
- E1: none (tests + one doc line only).
- E2: NEW reducer type(s) added; existing service/center public surfaces UNCHANGED.

## Test contracts
- Every return/borrow branch has a contract snapshot (E1).
- The new reducer's snapshot sequence is byte-shape-equal to the corresponding
  service snapshot (E2) — proves behavior preservation.
- 100% mutation on any NEW reducer logic (E2). E1 is characterization (snapshot),
  not mutation.

## Verification criteria (Phase 4.5)
```bash
# --- E1: characterization complete ---
# AC1: the two undocumented return branches are pinned by name
grep -Eq 'noRevokeURL|revokeURL == nil|withoutRevoke' PalaceTests/Contract/BookReturnServiceContractTests.swift
grep -Eiq 'overdrive.*(parse|success)|parseFail|opdsFeedInvalid' PalaceTests/Contract/BookReturnServiceContractTests.swift

# AC2: snapshots recorded for the return service
test -d PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests
test "$(ls PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests/*.json 2>/dev/null | wc -l | tr -d ' ')" -ge 3

# AC3: CLAUDE.md return-order line reconciled with the pinned truth
#      (line 259 must describe setState-then-removeBook accurately;
#       orchestrator diffs the snapshot order against the doc sentence)
grep -q 'BookReturnService' CLAUDE.md

# --- E2: reducer seam on top of green E1 (NO god-class cutover) ---
# AC4: a pure reducer core exists and is registered in BOTH targets
test -f Palace/MyBooks/ReturnReducer.swift || test -f Palace/MyBooks/DownloadPipelineReducer.swift
grep -Eq 'ReturnReducer|DownloadPipelineReducer' Palace.xcodeproj/project.pbxproj

# AC5: a reducer contract test proves order-preservation vs the E1 service snapshot
test -f PalaceTests/Contract/ReturnReducerContractTests.swift
grep -q 'ContractSnapshot.assert' PalaceTests/Contract/ReturnReducerContractTests.swift

# AC6: the god-class was NOT cut over (its public entry points still present)
grep -q 'class MyBooksDownloadCenter' Palace/MyBooks/MyBooksDownloadCenter.swift
grep -q 'func returnBook' Palace/MyBooks/BookReturnService.swift
```
