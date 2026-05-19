# Contract: Audiobooks-MyBooks-Reader2Sync (swarm_81b5099e)

**Sequence:** Parallel (after Accounts-Wiring merges).
**Estimated LOC:** ~200 production + ~150 test.

## Goal

Migrate Bucket A critical-path readers of `account.details` and `currentAccount?.loansUrl` in the audiobook open path, MyBooks/registry sync path, and Reader2 bookmark/annotations sync path. Replace direct `details?` dereferences with `await currentAccount.awaitReady()`. Inherit existing pipeline timeouts; never stack a second timeout on the gate.

## Read FIRST

1. `docs/architecture/account-state-machine.md` — ADR, especially "UX contract for Bucket A awaits"
2. `Palace/Accounts/Library/Account+State.swift` — frozen API
3. `.forgeos/swarms/swarm_81b5099e/plan.md` — swarm-wide context
4. `CLAUDE.md` — project conventions + LCP test matrix discipline

## Files in scope (edit)

- `Palace/Audiobooks/AudiobookSessionManager.swift` (line ~889)
- `Palace/CarPlay/CarPlayAudiobookBridge.swift` (line ~51)
- `Palace/Book/Models/BookRegistrySync.swift` (line ~283 — the PP-4407 site)
- `Palace/Book/Models/TPPBookRegistryAsync.swift` (line ~42)
- `Palace/Reader2/BusinessLogic/TPPReaderBookmarksBusinessLogic.swift` (lines ~117, ~160)
- `Palace/Reader2/ReaderStackConfiguration/LCP/LCPPassphraseAuthenticationService.swift` (line ~32)

## Files OFF-LIMITS

- `Palace/Accounts/Library/` (entire dir) — FROZEN or owned by Accounts-Wiring.
- `Palace/SignInLogic/`, `Palace/Notifications/`, `Palace/OPDS2/`, `Palace/Accounts/AgeCheck/` — other implementers.
- `Palace/Reader2/Bookmarks/TPPAnnotations.swift` (Bucket B — Phase 2).

## Per-call-site migration

### 1. `AudiobookSessionManager.swift:889` (audiobook open)

```swift
// BEFORE:
guard let details = account.details, let defaultAuth = details.defaultAuth else { ... }

// AFTER:
let details: AccountDetails
do {
    details = try await account.awaitReady()
} catch {
    // surface to existing audiobook-open error UI; existing 20s session-manager
    // timeout covers this — do NOT add a withTimeout wrapper here.
    handleAudiobookOpenFailed(error); return
}
guard let defaultAuth = details.defaultAuth else { ... }
```

UX/timeout per ADR: existing 20s session-manager timeout is the only timeout on this path. Existing audiobook-open spinner covers the await window. On `AccountLoadError`: surface to the existing audiobook-open error UI.

### 2. `CarPlayAudiobookBridge.swift:51` (CarPlay audiobook open)

Same pattern. CarPlay inherits the same 20s timeout via the session manager.

### 3. `BookRegistrySync.swift:283` (PP-4407 site)

```swift
// BEFORE:
let loansUrl = currentAccount.loansUrl

// AFTER (verify enclosing function is async — likely is, but check):
let details: AccountDetails
do {
    details = try await currentAccount.awaitReady()
} catch {
    Log.warn(#file, "BookRegistrySync abort: awaitReady failed: \(error)")
    return  // BookRegistrySync already has its own retry policy
}
guard let loansUrl = details.loansUrl else { ... existing nil handling ... }
```

If the enclosing function is sync, do NOT change its signature in this implementer — escalate to integrator.

### 4. `TPPBookRegistryAsync.swift:42`

```swift
// BEFORE:
guard let loansURL = accountsManager.currentAccount?.loansUrl else { ... }

// AFTER:
guard let currentAccount = accountsManager.currentAccount else { ... }
let details: AccountDetails
do {
    details = try await currentAccount.awaitReady()
} catch { ... existing error handling ... }
guard let loansURL = details.loansUrl else { ... }
```

File is already async-shaped; no signature push required.

### 5. `TPPReaderBookmarksBusinessLogic.swift:117 and :160`

Two sites in same file. Both gate bookmark sync. Migrate to `try await currentAccount.awaitReady()`. Bookmark sync is best-effort silent-failure — on `AccountLoadError`, log and return; do not surface to user.

If a caller is sync-only and you can't make it async without changing its public signature beyond this file, STOP and escalate.

### 6. `LCPPassphraseAuthenticationService.swift:32`

```swift
// BEFORE:
guard let loansUrl = accountsManager.currentAccount?.loansUrl else { ... }

// AFTER:
guard let currentAccount = accountsManager.currentAccount else { ... }
let details = try await currentAccount.awaitReady()
guard let loansUrl = details.loansUrl else { ... }
```

LCP fulfillment is on the critical path for LCP-protected books — if awaitReady throws, surface via the existing LCP fulfillment error path. Function is already `async throws`.

## Single-timeout policy (ADR-mandated)

NEVER wrap `awaitReady()` in `withTimeout`. Every call site in this contract already has an upstream timeout. Stacking creates ambiguous failure attribution.

## Tests to add (TDD — write FIRST)

Per file, add a test asserting:

1. **`testReadiness_blocksUntilLoaded`** — given `.detailsLoading`, migrated path blocks; transition to `.detailsLoaded` proceeds with correct details.
2. **`testReadiness_failurePath`** — given `.detailsFailed`, migrated path takes error branch instead of silent nil branch.

Plus the **F-016 → audiobook regression repro** in `PalaceTests/Audiobooks/AudiobookOpenStateRaceTests.swift`: construct the exact F-016 scenario (preload `.basicInfoLoaded`, auth doc pending, audiobook-borrow path invoked). Assert borrow path waits for `.detailsLoaded` (does NOT fire on basicInfoLoaded's nil `loansUrl`). This test passing means the audiobook race is unrepresentable.

Use isolated `AccountStateStore()` instances per test (NOT `.shared`); inject via `AppContainer`. Use `HTTPStubURLProtocol` for any network in audiobook-open path.

## LCP test matrix discipline (CLAUDE.md MANDATORY)

This implementer touches `LCPPassphraseAuthenticationService` AND `AudiobookSessionManager`. Both Palace (DRM) and Palace-noDRM targets must stay green:
```
xcodebuild -project Palace.xcodeproj -scheme Palace ... build
xcodebuild -project Palace.xcodeproj -scheme Palace-noDRM ... build
```

Audiobook tests must run in both target configs. See existing matrix tests in `PalaceTests/LCP/LCPAudiobooksTests.swift` for template (the "Real-world OPDS shape regression tests (LCP discovery matrix)" section).

## pbxproj

Use `ruby scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM ...` for any new files. Test files: `--targets PalaceTests`.

## Acceptance criteria

- Both `Palace` and `Palace-noDRM` schemes build green on iPhone 16 Pro.
- All new tests pass.
- All existing PalaceTests pass in BOTH target configs.
- Mutation kill rate ≥50% on each changed file.
- No edits outside this contract's scope (specifically: no AccountsManager edits, no Account.swift edits).
- `scripts/verify-pr.sh --quick` passes.
- `account.details?` no longer read on the 6 sites listed.

## Reporting back

Write `.forgeos/swarms/swarm_81b5099e/transcripts/Audiobooks-MyBooks-Reader2Sync.md` with: summary, files modified, tests added, mutation results, gaps, build + test command outputs.
