# Contract E — MyBooks Pipeline: PIN (WS6) then EXTRACT DECISION CORES (WS7)

**Module:** MyBooks (+ PalaceTests/Contract, CLAUDE.md doc fix)
**Risk:** critical_path (borrow / return / download / DRM fulfillment — patron access)
**Depends on:** A (doctrine declares the target pure-reducer shape)

> **HARD INTERNAL ORDERING — non-negotiable, one implementer owns both halves.**
> **Phase E1 (WS6) characterization contracts for EVERY branch MUST be green before
> Phase E2 (WS7) touches any decision logic.** WS6 and WS7 are in this single
> contract so no implementer can reorder pin/extract. Do not open E2 until every E1
> snapshot passes on a clean re-run.

## CORRECTION vs first triage — MBDC is ALREADY decomposed
`MyBooksDownloadCenter` (2155 LOC) is **NOT a god-class to decompose** — it is an
already-decomposed **delegation HUB** owning ~27 extracted collaborators, wired via
injected collaborators + empty delegate conformances (verified:
`extension MyBooksDownloadCenter: BorrowOperationDelegate {}` `:1831`,
`DownloadStartCoordinatorDelegate` `:1829`, `DownloadStartDispatcherDelegate` `:1841`,
`BackgroundDownloadHandlerDelegate` `:1821`, `DownloadQueueOrchestratorDelegate` `:1877`,
plus AdobeDRMHandler/LCPFulfillmentHandler/OverdriveDownloadHandler/DownloadStateManager
etc.). Prior swarms (#1009/#1018/#1024/#1212) did the structural extraction;
`BorrowOperation` + `BookReturnService` already carry contract snapshots.
**E2 is therefore NOT "decompose the hub."** E2 = convert the DECISION CORES of the
already-extracted collaborators into pure `reduce`-style functions per the WS1
doctrine, leaving MBDC and the collaborators as the effect-runners.

## Verified starting facts
- `BorrowOperation.swift` 989 LOC; `BookReturnService.swift` 744 LOC;
  `DownloadStartDispatcher.swift` 321 LOC — the three whose decision cores E2 extracts.
- Existing contract coverage present: `BorrowOperationContractTests`,
  `BookReturnServiceContractTests`, `DownloadStartCoordinatorContractTests`,
  `BorrowReducerContractTests` (+ snapshot dirs). **E1 fills the branch GAPS.**
- **Undocumented return branches to pin (verified in `BookReturnService.swift`):**
  - No-`revokeURL`: `if book.revokeURL == nil` (`:316`) → `handleReturnWithoutRevokeURL`
    → `setState(.unregistered)` (`:402`) **then** `removeBook` (`:403`).
  - OverDrive revoke whose OPDS parse FAILS is treated as **server-success**: XML is
    not a valid OPDS feed → `PalaceError.parsing(.opdsFeedInvalid)` (`:415-417`), catch
    still runs local cleanup `setState(.unregistered)` (`:429`) + `removeBook` (`:430`).
  - Default cleanup paths also do `setState` then `removeBook` (`:457-458`, `:622-623`).
- **CLAUDE.md return-order claim at line 259** ("BookReturnService → setProcessing →
  setState → removeBook → announce.returnSucceeded"); the normal path uses
  `updateAndRemoveBook` (`:592`). If the pinned order diverges, FIX line 259.

---

## Phase E1 — WS6 PIN EVERY BRANCH (do first; must be green before E2)

### Scope
- EXTEND `PalaceTests/Contract/BookReturnServiceContractTests.swift` with a scenario
  per branch, including the undocumented ones:
  - `returnBook_noRevokeURL_cleansUp_setStateThenRemove`
  - `returnBook_overdriveRevokeParseFail_treatedAsSuccess_cleansUpLocally`
  - confirm/add: normal `revokeURL` success, offline `OfflineAction(.return)`
    no-local-cleanup, no-active-loan, loan-term-limit, invalid-credentials re-auth.
- EXTEND `PalaceTests/Contract/BorrowOperationContractTests.swift` for EVERY borrow
  branch not already snapshotted (reserved→.holding, ready→.downloadNeeded,
  streaming-HTML skip, 30s timeout, availability-map edge cases).
- EXTEND `PalaceTests/Contract/DownloadStartCoordinatorContractTests.swift` (or add a
  `DownloadStartDispatcherContractTests`) for EVERY download-start dispatch branch.
- FIX `CLAUDE.md:259` to the ACTUAL pinned return order (only if it diverges).
- Record baselines (`CONTRACT_SNAPSHOT_RECORD=1`), review `git diff` of the JSON, commit.

### E1 exit gate (BLOCKS E2)
Every borrow/return/download branch is pinned and all MyBooks contract snapshots pass
on a clean re-run (no "snapshot recorded — re-run to verify").

---

## Phase E2 — WS7 EXTRACT DECISION CORES to pure reducers (only after E1 green)

> **Re-scoped, per-collaborator, bounded.** Extract the BRANCH LOGIC of each
> collaborator into a pure `reduce`-style function/core; leave the collaborator (and
> MBDC) as the EFFECT-RUNNER that interprets the core's decision. Behavior-preserving.
> Do NOT re-plumb the hub, do NOT touch the delegate conformances, do NOT merge
> collaborators.

### Scope — three bounded extractions, each pure + snapshot-proven
1. **BookReturnService decision core** → `Palace/MyBooks/ReturnReducer.swift`
   (pure: revokeURL present/absent, OverDrive-parse-fail-as-success, offline-enqueue,
   no-active-loan, loan-term-limit → decisions). `BookReturnService.returnBook` calls
   the core, then RUNS the decided effects (setProcessing/setState/removeBook/announce).
2. **BorrowOperation decision core** → `Palace/MyBooks/BorrowReducerCore.swift`
   (pure: availability→state map, streaming-HTML skip, timeout → decisions).
   `BorrowOperation.borrowAsync` runs the resulting effects.
3. **DownloadStartDispatcher decision core** → `Palace/MyBooks/DownloadStartReducer.swift`
   (pure: rights-management / dispatch-branch selection). Dispatcher runs the effects.
- Register each new file via `scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM`.
- Each core reproduces the E1-pinned call ORDER when its decisions are interpreted —
  prove it with `ReturnReducerContractTests`, `BorrowReducerCoreContractTests`,
  `DownloadStartReducerContractTests` whose snapshots MATCH the corresponding E1
  service snapshot sequence shape (behavior preservation proof).

### Off-limits (both phases)
- `Palace/Book/Models/TPPBookRegistry.swift` / `TPPBookState.swift` (Contract C) —
  EXCEPT that E's snapshots inform C's allowedTransitions set (read-only coupling).
- The `MyBooksDownloadCenter.swift:2076` observer (Contract C owns that block).
- `Palace/MyBooks/Sideload/**` (Contract D).
- `Palace/AppInfrastructure/Store.swift` / PalaceAuth `Effect.swift` (Contract B).
- Delegate conformances + hub wiring in MBDC (:1809-1926) — do NOT re-plumb.
- No production behavior change in E1. No hub re-plumb in E2 — decision-core
  extraction only.

### What public types change
- E1: none (tests + one doc line).
- E2: NEW pure core types added (`ReturnReducer`, `BorrowReducerCore`,
  `DownloadStartReducer`); collaborator/hub public surfaces UNCHANGED (they now
  delegate branch selection to the core internally).

## Test contracts
- Every borrow/return/download branch has an E1 contract snapshot.
- Each E2 core's snapshot sequence is shape-equal to the corresponding E1 service
  snapshot — proves behavior preservation.
- 100% mutation on each NEW pure core (E2). E1 is characterization (snapshot).

## Definition of Done — TWO TIERS ("ship today, verify Monday")
**TODAY (implementer, fast/local — do NOT run the full ~7k CI suite):**
- E1 branches pinned + E2 cores implemented; changed files COMPILE clean:
  `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build`.
- Diff-scoped mutation 100% on each new core, e.g.
  `python3 scripts/palace_mutate.py --file Palace/MyBooks/ReturnReducer.swift --tests PalaceTests/ReturnReducerContractTests --diff-only`
  (repeat for BorrowReducerCore + DownloadStartReducer).
- Contract + unit tests PASS via targeted selectors:
  `-only-testing:PalaceTests/BookReturnServiceContractTests`,
  `-only-testing:PalaceTests/ReturnReducerContractTests`, etc.
- Transcript + DoD evidence pasted. **E1-green-before-E2 confirmed in the transcript.**

**MONDAY MERGE GATE (orchestrator only):**
- Full CI-parity suite green: `scripts/xcode-test-optimized.sh`.
- `/forge-review` — 3 SoD reviewers approve.
- `arch drift` clean.
- Nothing merges to `develop` until Monday-green.

## Verification criteria (Phase 4.5)
```bash
# --- E1: every branch pinned ---
# AC1: the two undocumented return branches pinned by name
grep -Eq 'noRevokeURL|revokeURL == nil|withoutRevoke' PalaceTests/Contract/BookReturnServiceContractTests.swift
grep -Eiq 'overdrive.*(parse|success)|parseFail|opdsFeedInvalid' PalaceTests/Contract/BookReturnServiceContractTests.swift

# AC2: return snapshots recorded (>= the branch count)
test -d PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests
test "$(ls PalaceTests/Contract/__Snapshots__/BookReturnServiceContractTests/*.json 2>/dev/null | wc -l | tr -d ' ')" -ge 4

# AC3: download-start branches pinned (coordinator or new dispatcher test)
test -f PalaceTests/Contract/DownloadStartCoordinatorContractTests.swift || test -f PalaceTests/Contract/DownloadStartDispatcherContractTests.swift

# AC4: CLAUDE.md return-order line reconciled with pinned truth
grep -q 'BookReturnService' CLAUDE.md

# --- E2: pure decision cores extracted (per-collaborator), NO hub re-plumb ---
# AC5: three pure cores exist and registered in BOTH targets
test -f Palace/MyBooks/ReturnReducer.swift
test -f Palace/MyBooks/BorrowReducerCore.swift
test -f Palace/MyBooks/DownloadStartReducer.swift
grep -q 'ReturnReducer' Palace.xcodeproj/project.pbxproj
grep -q 'BorrowReducerCore' Palace.xcodeproj/project.pbxproj
grep -q 'DownloadStartReducer' Palace.xcodeproj/project.pbxproj

# AC6: each core is order-proven against its E1 service snapshot
test -f PalaceTests/Contract/ReturnReducerContractTests.swift
grep -q 'ContractSnapshot.assert' PalaceTests/Contract/ReturnReducerContractTests.swift

# AC7: the collaborators now DELEGATE branch selection to the core
grep -q 'ReturnReducer' Palace/MyBooks/BookReturnService.swift
grep -Eq 'BorrowReducerCore' Palace/MyBooks/BorrowOperation.swift

# AC8: hub NOT re-plumbed — delegation conformances + entry points intact
grep -q 'extension MyBooksDownloadCenter: BorrowOperationDelegate' Palace/MyBooks/MyBooksDownloadCenter.swift
grep -q 'func returnBook' Palace/MyBooks/BookReturnService.swift
```
