## Contract A — `.forgeos/swarms/swarm_51f248d5/contracts/A-AccountNotFound-EnumSplit.md`

```markdown
# Module A — `.accountNotFound` enum split

**Critical-path module.** Memory pin: `enum_conflation_account_not_found.md`. Adjacent: PR #996 commit `121246f85` (symptom patch), the wiring test at `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift::testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives`.

## Goal

Split the dual-meaning `.detailsFailed(.accountNotFound)` terminal into two distinct enum cases so "real 404 failure" and "library-swap eviction marker" stop sharing storage. ALL existing switch arms keep their literal HTTP-404 meaning; the eviction marker moves to a new sibling case (`.detailsEvicted(.libraryDeselected(uuid:))`) and the swap-back redrive at `AccountsManager.driveCurrentAccountAuthDocIfNeeded:958` switches to the new case. The compiler's exhaustiveness check is the safety net.

## Public types/protocols changing

`Account.LoadState` (public enum in `Palace/Accounts/Library/Account+State.swift`):
- ADD: `case detailsEvicted(AccountEvictionReason)` as a new sibling to `.detailsFailed`.
- KEEP unchanged: `notLoaded`, `basicInfoLoaded`, `detailsLoading`, `detailsLoaded(AccountDetails)`, `detailsFailed(AccountLoadError)`.

ADD new public error/marker enum:
```swift
public enum AccountEvictionReason: Equatable, Sendable {
    /// User switched libraries away from this account.
    /// Awaiters on the prior account observe this terminal so they can
    /// fail-fast instead of hanging. Re-entering this UUID overwrites
    /// the marker via the basicInfoLoaded path on the next preload/loadCatalogs.
    case libraryDeselected(uuid: String)
}
```

`AccountLoadError.accountNotFound(uuid:)` — KEEP as-is. Its meaning narrows to "genuine HTTP 404 / auth-doc fetch returned not-found." No call site is removed; the eviction-marker WRITE moves to the new case.

`awaitReady()` semantics:
- Under `.detailsEvicted`: throws a NEW `AccountLoadError.evicted(reason:)` case — see below.
- Under `.detailsFailed`: unchanged (throws the underlying `AccountLoadError`).

ADD to `AccountLoadError` (in `Account+State.swift`):
```swift
case evicted(reason: AccountEvictionReason)
```

Rationale: every `awaitReady()` caller in the codebase already has a `catch AccountLoadError` arm — adding a new error case keeps the call-site shape and the compiler will surface every `switch error as AccountLoadError` block that needs a new arm.

## Internal seams

- `Palace/Accounts/Library/AccountsManager.swift:301` (eviction-marker WRITE) — change from `.detailsFailed(.accountNotFound(uuid: prev))` to `.detailsEvicted(.libraryDeselected(uuid: prev))`.
- `Palace/Accounts/Library/AccountsManager.swift:958` (eviction-marker READ in `driveCurrentAccountAuthDocIfNeeded`) — change `case .detailsFailed(.accountNotFound):` to `case .detailsEvicted(.libraryDeselected):`. The comment block around it (lines 959-965) gets refreshed to reference the new case name.
- `Palace/Accounts/Library/AccountsManager.swift:933` (real-failure WRITE in `fetchAuthDocumentWithStateMachine`) — UNCHANGED if it currently writes `.detailsFailed(.authDocumentFetchFailed(...))` or `.detailsFailed(.malformedAuthDocument(...))`. If any write at this site does write `.accountNotFound` for real, AUDIT it; the eviction marker is the only legitimate caller and that's moving to the new case.

## Test contracts

1. **Semantics test for real failure (NEW)** — `PalaceTests/Accounts/AccountStateMachineTests.swift::testDetailsFailedAccountNotFound_meansHTTP404_throwsAuthLoadError_fromAwaitReady`. Drives `account._setState(.detailsFailed(.accountNotFound(uuid: ...)))`; assert `try await account.awaitReady()` throws `AccountLoadError.accountNotFound`. Kill case: code that accidentally maps the case to `.evicted` would fail this test.

2. **Semantics test for eviction marker (NEW)** — `PalaceTests/Accounts/AccountStateMachineTests.swift::testDetailsEvicted_libraryDeselected_throwsEvictionError_fromAwaitReady`. Drives `account._setState(.detailsEvicted(.libraryDeselected(uuid: ...)))`; assert `try await account.awaitReady()` throws `AccountLoadError.evicted`. Kill case: code that conflates the cases would fail this test.

3. **Consumer disambiguation test (NEW)** — `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift::testDriveCurrentAccountAuthDoc_realAccountNotFound_doesNotRedrive`. Drives `.detailsFailed(.accountNotFound)` on the current account (simulating a real HTTP 404), calls `driveCurrentAccountAuthDocIfNeeded()`, asserts that state STAYS at `.detailsFailed(.accountNotFound)` — the eviction-marker swap-back-redrive arm MUST NOT fire on a genuine failure. Kill case: a regression that re-conflates the two meanings would observe `.detailsLoading` and fail.

4. **Test 7 adaptation (EXISTING — must still pass under the new shape)** — `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift::testDriveCurrentAccountAuthDoc_staleAccountNotFoundMarker_redrives`. RENAME and refactor:
   - New name: `testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives`.
   - Setup line 888 changes from `account._setState(.detailsFailed(.accountNotFound(uuid: currentUUID)))` to `account._setState(.detailsEvicted(.libraryDeselected(uuid: currentUUID)))`.
   - Setup-precondition assertion at line 889 changes pattern to `.detailsEvicted(.libraryDeselected)`.
   - Final assertion at lines 934-945: the polling loop's `case .detailsFailed(let err): if case .accountNotFound` block becomes `case .detailsEvicted(let reason): if case .libraryDeselected`.

5. **Test 5 adaptation (EXISTING — must still pass)** — `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift::testCurrentAccountSetter_evictsPriorAccount` (lines 624-680 area; the test that asserts the prior account terminates after A→B reselect). The expected terminal changes from `.detailsFailed(.accountNotFound)` to `.detailsEvicted(.libraryDeselected)`. The UUID-carrying assertion at line 670-672 keeps the same shape against the new payload.

6. **Mutation kill-rate (critical path).** ≥80% diff-scoped on `Palace/Accounts/Library/AccountsManager.swift` and `Palace/Accounts/Library/Account+State.swift`. Run:
   ```bash
   python3 scripts/palace_mutate.py --file Palace/Accounts/Library/AccountsManager.swift \
     --tests PalaceTests/AccountsManagerStateMachineWiringTests --diff-only --diff-base origin/develop
   python3 scripts/palace_mutate.py --file Palace/Accounts/Library/Account+State.swift \
     --tests PalaceTests/AccountStateMachineTests --diff-only --diff-base origin/develop
   ```

7. **Switch-exhaustiveness propagation.** The compiler will surface every `switch` over `Account.LoadState` that does not consider `.detailsEvicted`. Each MUST add an explicit arm. Audit:
   - `Palace/Accounts/Library/Account+State.swift:81` (`awaitReady` fast-path switch)
   - `Palace/Accounts/Library/Account+State.swift:93` (`awaitReady` slow-path switch)
   - `Palace/Accounts/Library/AccountsManager.swift:955` (`driveCurrentAccountAuthDocIfNeeded` switch)
   - `Palace/Accounts/AgeCheck/TPPAgeCheck.swift:76` (full switch)
   - Any others the compiler discovers — handle them as part of THIS module.

## Files scoped to THIS implementer

Production:
- `Palace/Accounts/Library/Account+State.swift` (MODIFIED — add `.detailsEvicted` case + `AccountEvictionReason` enum + `AccountLoadError.evicted` case + `awaitReady` switch arms)
- `Palace/Accounts/Library/AccountsManager.swift` (MODIFIED — flip the eviction-marker WRITE at :301 and READ at :955-973)
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift` (MODIFIED — add `.detailsEvicted` switch arm; same behavior as `.detailsFailed` for this consumer: completion(false))
- ANY other file the Swift compiler surfaces as non-exhaustive after the enum addition (handle inline; do not punt)

Test:
- `PalaceTests/Accounts/AccountStateMachineTests.swift` (MODIFIED — add the two new semantics tests, items #1 and #2)
- `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` (MODIFIED — Tests 5 + 7 adapt; new disambiguation test #3 added)

Tooling:
- `ruby scripts/pbxproj_add_swift.rb` — NOT needed for THIS module (no new files added).

## Files explicitly OFF-LIMITS

**Anti-scope (universal):**
- `Palace/Audiobooks/` — entire directory (PR #1020 territory)
- `PalaceTests/Audiobooks/AudiobookFirstOpenHangTests.swift`
- `Palace/Audiobooks/PlaybackReadinessGate.swift`
- `Palace/Audiobooks/AudiobookSessionManager.swift`
- `ios-audiobooktoolkit/` — submodule, read-only
- `worktree-refactor-saml-auth` continuation files

**Off-limits per swarm overlap resolution (Module B owns):**
- `Palace/SignInLogic/SignInModalView.swift`
- `Palace/SignInLogic/SignInModalPresenter+SignInModalPresenting.swift`
- `Palace/SignInLogic/TPPReauthenticator.swift`
- `Palace/Network/TPPNetworkExecutor.swift` (B updates the call-site at :587)
- `Palace/Holds/HoldsViewModel.swift`
- `Palace/Book/UI/BookDetail/BookDetailViewModel.swift`
- `Palace/MyBooks/MyBooksDownloadCenter.swift`
- `Palace/MyBooks/TokenRefreshInterceptor.swift`
- `Palace/MyBooks/MyBooks/MyBooksViewModel.swift`
- `Palace/MyBooks/MyBooks/BookCell/BookCellModel.swift`
- `Palace/AppInfrastructure/DLNavigator.swift`
- `PalaceTests/SignInLogic/SignInModal*.swift`

**Off-limits per swarm overlap resolution (Module C owns):**
- `CLAUDE.md`, `.claude/skills/swarm/SKILL.md`, `.claude/skills/rigorous-fix/SKILL.md`
- `.forgeos/wall-failures/2026-05-28-cs847892e8-arch1.md`
- `.forgeos/wall-failures/derived-improvements.md`

**Special note on `TPPSignInBusinessLogic.swift:286`:** read-only for A. That site only pattern-matches `.detailsLoaded` — it remains compile-clean under the enum addition because Swift only requires exhaustiveness when the switch is over the enum, and a `guard case .detailsLoaded = ...` is a single-case bind that does not need exhaustiveness. A does NOT modify this file.

**Special note on `PalaceError.swift:375` `case accountNotFound = 4`:** this is a DIFFERENT enum (`PalaceError.AuthenticationError`, not `AccountLoadError`). Out of scope. Do NOT split or rename.

## Verification criteria (MANDATORY)

For each acceptance bullet, paste the exact grep + expected output.

1. **Enum addition landed:**
   ```bash
   grep -c "case detailsEvicted(AccountEvictionReason)" Palace/Accounts/Library/Account+State.swift
   grep -c "public enum AccountEvictionReason" Palace/Accounts/Library/Account+State.swift
   grep -c "case evicted(reason: AccountEvictionReason)" Palace/Accounts/Library/Account+State.swift
   ```
   All three MUST return 1.

2. **Eviction marker write moved (per CLAUDE.md DoD check #2 — function-result usage / wire-up evidence):**
   ```bash
   grep -c "\.detailsEvicted(\.libraryDeselected(uuid: prev))" Palace/Accounts/Library/AccountsManager.swift
   ```
   MUST return 1. AND:
   ```bash
   grep -cE "AccountStateStore.shared.setState\(\s*\.detailsFailed\(\.accountNotFound\(uuid: prev\)\)" Palace/Accounts/Library/AccountsManager.swift
   ```
   MUST return 0 (the WRITE is gone from this site).

3. **Eviction marker read moved:**
   ```bash
   grep -c "case .detailsEvicted(.libraryDeselected):" Palace/Accounts/Library/AccountsManager.swift
   ```
   MUST return 1 (or 1+ if the switch is expanded to bind the uuid).
   ```bash
   grep -cE "case \.detailsFailed\(\.accountNotFound\):" Palace/Accounts/Library/AccountsManager.swift
   ```
   MUST return 0 (this arm should be gone — the real-failure case stops being treated as eviction).

4. **`try await`/`await` boundary clause (from wall-failure fix #1, applied to THIS module):** every new `try await account.awaitReady()` arm or call within this module's diff must be exercised by a test that drives the production entry point. Specifically:
   - For the new `.detailsEvicted` throw arm in `Account+State.swift::awaitReady` slow path:
     ```bash
     grep -nE "try await .+\.awaitReady\(\)" PalaceTests/Accounts/AccountStateMachineTests.swift
     ```
     MUST return ≥1 line in the body of `testDetailsEvicted_libraryDeselected_throwsEvictionError_fromAwaitReady`. The test MUST drive `account._setState(.detailsEvicted(.libraryDeselected(...)))` BEFORE the `try await` and catch the resulting error.

5. **SUT-instantiation grep (CLAUDE.md DoD check #1):**
   ```bash
   grep -c "AccountsManager(" PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
   ```
   MUST return ≥1 (test class instantiates the SUT — already true; verify preserved).
   ```bash
   grep -c "Account(publication:" PalaceTests/Accounts/AccountStateMachineTests.swift
   ```
   MUST return ≥1 (the new semantics tests instantiate Account through the production constructor).

6. **Multi-step test body check (CLAUDE.md DoD check #3):** for `testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives` (the renamed Test 7), the body MUST drive ≥3 production-seam steps (preload → eviction-marker write → driveCurrentAccountAuthDocIfNeeded). Grep:
   ```bash
   grep -cE "preloadAccountsFromDiskCacheSync\(\)|driveCurrentAccountAuthDocIfNeeded\(\)" PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift
   ```
   MUST return ≥2 (one of each, plus the unchanged round-trip Tests 6 and the new disambiguation test). The body MUST contain both literal calls in the renamed Test 7.

7. **No conflation in switch arms (compiler-enforced; also greppable):**
   ```bash
   grep -rn "case \.detailsFailed.*evict\|case \.detailsEvicted.*account.*not.*found\|case \.detailsFailed(\.accountNotFound).*evict" Palace/ PalaceTests/ 2>/dev/null
   ```
   MUST return 0 — no remaining site treats the two meanings as the same.

8. **No new force unwraps:**
   ```bash
   git diff origin/develop -- 'Palace/Accounts/*.swift' 'Palace/Accounts/**/*.swift' | grep -E '^\+.*[a-zA-Z_]!([. ;)\[])' | grep -v '!=' | grep -v '// '
   ```
   Should return empty (or only matches inside string literals / comments).

9. **No `DispatchQueue.main.asyncAfter` workarounds:**
   ```bash
   git diff origin/develop -- 'Palace/Accounts/*.swift' 'Palace/Accounts/**/*.swift' | grep -E '^\+.*asyncAfter'
   ```
   MUST be empty.

10. **Cross-module regression net (no spillover into auth flows):**
    ```bash
    xcodebuild -project Palace.xcodeproj -scheme Palace \
      -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
      -only-testing:PalaceTests/CarPlayAuthHelperReadinessTests test 2>&1 | grep -E "Test Suite '.*' passed"
    xcodebuild ... -only-testing:PalaceTests/AccountStateMachineTests test 2>&1 | grep -E "Test Suite '.*' passed"
    xcodebuild ... -only-testing:PalaceTests/AccountsManagerStateMachineWiringTests test 2>&1 | grep -E "Test Suite '.*' passed"
    ```
    All three MUST report passed.

11. **Mutation kill-rate (critical path):**
    ```bash
    python3 scripts/palace_mutate.py --file Palace/Accounts/Library/AccountsManager.swift \
      --tests PalaceTests/AccountsManagerStateMachineWiringTests --diff-only --diff-base origin/develop
    ```
    Kill rate MUST be ≥80% diff-scoped (100% ideal). Paste `Killed: X / Y (Z%)`.

## Definition of Done evidence (paste before declaring READY — 6 checks)

1. **SUT instantiation check:** `grep -c "AccountsManager(" PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift` ≥1; `grep -c "Account(publication:" PalaceTests/Accounts/AccountStateMachineTests.swift` ≥1.
2. **Function-result usage check:** every new `try await account.awaitReady()` in production callers handled (CLAUDE.md DoD check #2). Verification: `grep -cE "= try await .+\.awaitReady\(\)|try await .+\.awaitReady\(\)" Palace/Accounts/` ≥1 per call site touched.
3. **Multi-step test body check:** renamed Test 7 + new disambiguation test #3 both drive ≥2 production-seam calls (`preloadAccountsFromDiskCacheSync` + `driveCurrentAccountAuthDocIfNeeded`).
4. **Scope coverage audit:** every contracted bullet either landed or explicitly STOPPED via scope-deferral protocol.
5. **Mutation pass:** `python3 scripts/palace_mutate.py --file Palace/Accounts/Library/AccountsManager.swift --tests PalaceTests/AccountsManagerStateMachineWiringTests --diff-only` ≥50% (target ≥80%; critical-path). Paste output.
6. **Build + verify-pr:** `scripts/verify-pr.sh --quick` PASS. Paste tails.

## Implementer prompt (one paragraph)

You are Module A implementer for `swarm_51f248d5`. The current `Account.LoadState.detailsFailed(.accountNotFound)` carries two orthogonal meanings — real HTTP 404 AND library-swap eviction marker — and PR #996's commit 121246f85 patched the symptom (swap-back redrive past `.accountNotFound`). Your job is the ROOT fix: add a new sibling case `.detailsEvicted(AccountEvictionReason)` to `Account.LoadState`, move the eviction-marker WRITE at `AccountsManager.swift:301` to the new case, move the swap-back redrive READ at `AccountsManager.swift:958` to the new case, and let `.detailsFailed(.accountNotFound)` keep its original literal HTTP-404 meaning. Add a `case evicted(reason: AccountEvictionReason)` to `AccountLoadError` so `awaitReady()` throws a distinct error under eviction. Add two NEW semantics tests (pin `.detailsFailed(.accountNotFound)` as HTTP 404 and pin `.detailsEvicted(.libraryDeselected)` as eviction). Add a NEW consumer-disambiguation test asserting that a real `.detailsFailed(.accountNotFound)` does NOT trigger the redrive helper. Adapt Tests 5 and 7 in `AccountsManagerStateMachineWiringTests.swift` to the new case shape — Test 7 keeps its name spirit (rename to `testDriveCurrentAccountAuthDoc_staleEvictionMarker_redrives`) and must still pass. Handle every switch-exhaustiveness compiler error inline (do NOT defer). NO `Palace/Audiobooks/`, NO `Palace/SignInLogic/`, NO `Palace/MyBooks/` files — those are Module B / off-scope. NO docs edits — that's Module C. Critical-path mutation kill-rate ≥80% diff-scoped on `AccountsManager.swift`. If you discover a switch arm in an OFF-LIMITS module is non-exhaustive after your enum addition (e.g. an unhandled `case .detailsEvicted` somewhere in `Palace/Reader2/`), STOP and escalate — the scope expansion needs a triage call before you cross modules.
```

---
