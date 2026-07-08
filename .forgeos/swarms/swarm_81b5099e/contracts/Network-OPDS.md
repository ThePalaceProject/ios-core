---
name: swarm_81b5099e-contract-Network-OPDS
type: immutable
status: active
created: 2026-05-18T19:30:00Z
last_refresh: 2026-05-19
freshness_window: never
owners: [network]
description: "Contract: Network-OPDS (swarm_81b5099e)"
---

# Contract: Network-OPDS (swarm_81b5099e)

**Sequence:** Parallel (after Accounts-Wiring merges).
**Estimated LOC:** ~80 production + ~80 test.

## Goal

Migrate two OPDS-feed Bucket A call sites that read `currentAccount?.loansUrl` (a passthrough to `details?.loansUrl` per `Account.swift:544`). BookRegistrySync already has its own retry policy and is owned by the Audiobooks-MyBooks-Reader2Sync implementer — this contract is strictly the OPDS-service layer.

## Read FIRST

1. `docs/architecture/account-state-machine.md`
2. `Palace/Accounts/Library/Account+State.swift` — frozen API
3. `.forgeos/swarms/swarm_81b5099e/plan.md` — swarm-wide context
4. `CLAUDE.md`

## Files in scope (edit)

- `Palace/OPDS2/OPDSFeedService.swift` (line ~317)
- `Palace/OPDS2/Service/UnifiedOPDSService.swift` (line ~337)

## Files OFF-LIMITS

- All state-machine files (FROZEN).
- `Palace/Accounts/`, `Palace/Audiobooks/`, `Palace/MyBooks/`, `Palace/Book/Models/`, `Palace/Reader2/`, `Palace/SignInLogic/`, `Palace/Notifications/` — other implementers in this swarm.
- `Palace/Network/TPPNetworkResponder.swift`, `TPPNetworkExecutor.swift`, `Palace/SignInLogic/TPPReauthenticator.swift`, `Palace/SignInLogic/TPPSAMLHelper.swift` — these use `currentAccountId` (UUID string) and `userAccount(for:)`, NOT `account.details`. **NOT Bucket A sites** per architect grep verification. ADR call-out was a red herring.

## Per-call-site migration

### 1. OPDSFeedService.swift:317

```swift
// BEFORE (likely around line 313-322):
guard let loansURL = accountsManager.currentAccount?.loansUrl else { ... }

// AFTER:
guard let currentAccount = accountsManager.currentAccount else { ... }
let details: AccountDetails
do {
    details = try await currentAccount.awaitReady()
} catch {
    Log.warn(#file, "Cannot fetch loans feed: awaitReady failed: \(error)")
    throw error
}
guard let loansURL = details.loansUrl else { ... existing nil handling ... }
```

Enclosing `fetchLoansFeed()` is already async. Inherit caller's timeout policy. No `withTimeout` on awaitReady.

### 2. UnifiedOPDSService.swift:337

Same pattern. Note this file reads `AppContainer.production().accountsManager.currentAccount` directly (a `.shared`-style antipattern per CLAUDE.md). **Document this technical debt in PR description** but do NOT refactor injection in this swarm — out of scope. Just migrate the `loansUrl` read.

## Tests to add (TDD — write FIRST)

Add `PalaceTests/OPDS2/OPDSFeedServiceStateMachineTests.swift`:

1. **`testFetchLoansFeed_blocksUntilLoaded_thenFetches`** — given `.detailsLoading`, fetch blocks; transition to `.detailsLoaded` resolves; assert exactly one HTTP request to the loans URL.
2. **`testFetchLoansFeed_failedDetailsLoad_throws`** — given `.detailsFailed`, fetch throws `AccountLoadError`.

Add `PalaceTests/OPDS2/UnifiedOPDSServiceStateMachineTests.swift`:

3-4. Same two tests for `UnifiedOPDSService.refreshLoansFeed()`.

Use isolated `AccountStateStore()` instances; inject via `AppContainer`. Use `HTTPStubURLProtocol` for the loans-feed HTTP.

## pbxproj

Use `ruby scripts/pbxproj_add_swift.rb --targets PalaceTests --group PalaceTests/OPDS2 ...` for new test files.

## Acceptance criteria

- Build green on Palace and Palace-noDRM.
- All 4 new tests pass.
- All existing PalaceTests pass.
- Mutation kill rate ≥50% on each changed file.
- No edits outside this contract's scope.
- `scripts/verify-pr.sh --quick` passes.

## Reporting back

Write `.forgeos/swarms/swarm_81b5099e/transcripts/Network-OPDS.md` with: summary, files modified, tests added, mutation results, gaps, build + test command outputs.
