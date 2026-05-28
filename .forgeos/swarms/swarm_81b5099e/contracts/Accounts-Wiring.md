---
name: swarm_81b5099e-contract-Accounts-Wiring
type: immutable
status: active
created: 2026-05-18T19:30:00Z
last_refresh: 2026-05-19
freshness_window: never
owners: [accounts]
description: "Contract: Accounts-Wiring (swarm_81b5099e)"
---

# Contract: Accounts-Wiring (swarm_81b5099e)

**Sequence:** PREREQUISITE — must merge before parallel implementers start.
**Estimated LOC:** ~150 production + ~120 test.

## Goal

Wire `AccountStateStore` into the existing `AccountsManager` load lifecycle so every Bucket A consumer of `Account.awaitReady()` gets a meaningful answer. Without this wiring, every migrated call site in the parallel implementers hangs forever in production because nothing transitions the state machine.

## Read FIRST (in this order)

1. `docs/architecture/account-state-machine.md` — the ADR; canonical on API + UX + test policy.
2. `Palace/Accounts/Library/Account+State.swift` — the public API surface (FROZEN — consume, don't modify).
3. `Palace/Accounts/Library/AccountStateStore.swift` — the store layer (FROZEN — consume, don't modify).
4. `Palace/Accounts/Library/AccountsManager.swift` — the file you're modifying.
5. `CLAUDE.md` — project conventions (TDD, test quality, pbxproj helper).

## Files in scope (edit)

- `Palace/Accounts/Library/AccountsManager.swift`

## Files OFF-LIMITS

- `Palace/Accounts/Library/Account+State.swift` — FROZEN by ADR.
- `Palace/Accounts/Library/AccountStateStore.swift` — FROZEN by ADR.
- `Palace/Accounts/Library/Account.swift` — do NOT change AccountDetails or `loansUrl` passthrough; legacy backing stays unchanged (ADR Open Q #3 resolution).
- Every other file in `Palace/` — those belong to the parallel implementers.

## Wiring requirements (4 transitions)

### 1. Preload → `.basicInfoLoaded`

In `AccountsManager.preloadAccountsFromDiskCacheSync()` (~AccountsManager.swift:137-156), after `performWrite { self.accountSets[hash] = accounts }`:

```swift
for account in accounts {
    account._setState(.basicInfoLoaded)
}
```

Use the internal `_setState(_:)` seam from `Account+State.swift`. Do NOT reach into `AccountStateStore.shared` directly — go through the Account API so the call site documents intent.

### 2. `loadAccountSetsAndAuthDoc` → `.detailsLoading` → `.detailsLoaded` / `.detailsFailed`

In `AccountsManager.loadAccountSetsAndAuthDoc(fromCatalogData:key:completion:)` (~AccountsManager.swift:697-770):

- After `newAccounts` is constructed and `performWrite { self.accountSets[hash] = newAccounts }` lands:
  - For accounts that carried over an existing `authenticationDocument` (the `if let authDoc = old.authenticationDocument` branch): `newAccount._setState(.detailsLoaded(newAccount.details!))` after the `authenticationDocument` setter populates `details` (synchronously per Account.swift didSet). Use a `guard let details = newAccount.details else { newAccount._setState(.basicInfoLoaded); continue }` belt-and-suspenders for mock-data resilience.
  - For accounts WITHOUT a carry-over auth doc: `newAccount._setState(.basicInfoLoaded)`.

- The current code calls `current.loadAuthenticationDocument` only for `self.currentAccount` (~line 731-744). Wire that call site:
  - **Before** invoking `loadAuthenticationDocument`: `current._setState(.detailsLoading)`.
  - **In the completion handler**:
    - On success (`current.details != nil`): `current._setState(.detailsLoaded(current.details!))`.
    - On failure: `current._setState(.detailsFailed(.authDocumentFetchFailed(underlyingDescription: "loadAuthenticationDocument returned false")))`. If you can plumb the underlying error string without modifying `Account.swift`'s public API, do so — otherwise the placeholder above is acceptable for Phase 1.

### 3. Single-flight per-UUID auth doc fetch

Add a private `inflightAuthDocFetches: Set<String>` (or `[String: ...]` for callback fan-out) + a lock. When a transition would call `current.loadAuthenticationDocument` for a UUID already in flight, do NOT fire a duplicate HTTP request. The state machine's `CurrentValueSubject` broadcast handles multi-consumer observation — this single-flight is about not firing duplicate network requests.

Verify via test: two simultaneous `account.awaitReady()` callers on the same UUID → state machine transitions exactly once + `loadAuthenticationDocument` (or its HTTP stub) fires exactly once.

### 4. Library reselect → `.detailsFailed(.accountNotFound)` for prior

In the `currentAccount` setter (~AccountsManager.swift:165-195), after `currentAccountId = newValue?.uuid` but before the post-switch notification:

```swift
let previousAccountId: String? // (already captured earlier in the setter; rename or reuse the existing local)
if let prev = previousAccountId, prev != newValue?.uuid {
    AccountStateStore.shared.setState(.detailsFailed(.accountNotFound(uuid: prev)), for: prev)
}
```

Why `.accountNotFound` not `.notLoaded`: leaves any lingering `awaitReady()` on prior with a definitive terminal answer ("this UUID is no longer current") rather than hanging. Re-entering that UUID later (user switches back) causes the existing wiring path to call `_setState(.basicInfoLoaded)` again — `CurrentValueSubject.send` cleanly overwrites the value.

## Public API the implementer must NOT change

- `Account.LoadState` enum cases / shapes.
- `Account.awaitReady() async throws -> AccountDetails` signature.
- `Account.loadState` / `Account.stateStream` properties.
- `Account._setState(_:)` (internal seam) signature.
- `AccountStateStore.shared.setState(_:for:)` / `.state(for:)` / `.stateStream(for:)` / `.reset(for:)` signatures.
- `AccountLoadError` cases / shapes.
- `Account.details` / `Account.loansUrl` passthroughs (legacy API, unchanged).

If you think any of these is wrong: STOP and report to the integrator. Do not silently change.

## Tests to add (TDD — write FIRST)

Add `PalaceTests/Accounts/AccountsManagerStateMachineWiringTests.swift`. Use existing `AccountsManagerTests` patterns (HTTPStubURLProtocol for the auth-doc fetch, isolated `AccountStateStore` via the internal `init()` — NOT `.shared` for tests).

Required tests (ADR Phase 1 contract-snapshot tests):

1. `testPreload_drivesEachLoadedAccount_toBasicInfoLoaded` — given a cached accounts blob with N libraries, after `AccountsManager.init` returns, `AccountStateStore.shared.state(for: each.uuid) == .basicInfoLoaded` for each preloaded account.
2. `testLoadCatalogs_currentAccountWithoutDetails_drivesDetailsLoading_thenLoaded` — given the current account preloaded but `authenticationDocument == nil`, after `loadCatalogs(completion:)` resolves with success, the state stream emits `.detailsLoading` then `.detailsLoaded(details)` in order.
3. `testLoadCatalogs_authDocFetchFails_drivesDetailsFailed` — given a stubbed network failure on the auth-doc endpoint, the state stream emits `.detailsLoading` then `.detailsFailed(.authDocumentFetchFailed(...))`.
4. `testSingleFlight_twoConcurrentAwaiters_oneNetworkRequest` — two concurrent `account.awaitReady()` calls for the same UUID while `.detailsLoading` both resolve to the same `AccountDetails` instance, and `HTTPStubURLProtocol` records exactly one auth-doc request.
5. `testLibraryReselect_priorAccount_terminatesWithAccountNotFound` — given account A is `.detailsLoaded`, after `currentAccount = accountB`, an awaiter subscribed to account A's stream observes `.detailsFailed(.accountNotFound(uuid: A.uuid))` as the next emission.
6. `testLibraryReselect_reentry_resetsState_andRedrives` — given account A terminated to `.accountNotFound` per #5, after `currentAccount = accountA` again, the next transition is `.basicInfoLoaded` (or the existing carry-over fast path to `.detailsLoaded` if `authenticationDocument` is cached).

## pbxproj

If you add a new helper file, use:
```
ruby scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM \
  --group "Palace/Accounts/Library" Palace/Accounts/Library/NEW_FILE.swift
```
For test files:
```
ruby scripts/pbxproj_add_swift.rb --targets PalaceTests \
  --group "PalaceTests/Accounts" PalaceTests/Accounts/NEW_TEST_FILE.swift
```

## Acceptance criteria

- `xcodebuild -project Palace.xcodeproj -scheme Palace -destination 'platform=iOS Simulator,name=iPhone 16 Pro' build` green.
- All 6 new tests above pass (`-only-testing:PalaceTests/AccountsManagerStateMachineWiringTests`).
- All existing PalaceTests pass.
- Mutation kill rate ≥50% on changed lines (`python3 scripts/palace_mutate.py --file Palace/Accounts/Library/AccountsManager.swift --tests PalaceTests/AccountsManagerStateMachineWiringTests`).
- No edits outside `Palace/Accounts/Library/AccountsManager.swift` and the new test file.
- `scripts/verify-pr.sh --quick` passes.

## Reporting back

When done, write `.forgeos/swarms/swarm_81b5099e/transcripts/Accounts-Wiring.md` with:
- Summary: 3-5 bullets on what you did
- Files added/modified/deleted
- Tests added (file + key test names)
- Mutation results (kill rate %)
- Any gaps or things the integrator needs to know
- Build + test command outputs (last 10 lines)
