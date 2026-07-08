---
name: swarm_81b5099e-contract-SignIn-AgeCheck-Notifications
type: immutable
status: active
created: 2026-05-18T19:30:00Z
last_refresh: 2026-05-19
freshness_window: never
owners: [signin-modal]
description: "Contract: SignIn-AgeCheck-Notifications (swarm_81b5099e)"
---

# Contract: SignIn-AgeCheck-Notifications (swarm_81b5099e)

**Sequence:** Parallel (after Accounts-Wiring merges).
**Estimated LOC:** ~180 production + ~140 test.

## Goal

Migrate Bucket A critical-path readers of `libraryAccount?.details` and `currentAccount?.details` in the sign-in flow, age-check gate, and push-notification navigation. SAML reauth inherits its existing 15s timeout — do not stack.

## Read FIRST

1. `docs/architecture/account-state-machine.md` — especially "UX contract for Bucket A awaits"
2. `Palace/Accounts/Library/Account+State.swift` — frozen API
3. `.forgeos/swarms/swarm_81b5099e/plan.md` — swarm-wide context
4. `CLAUDE.md` — project conventions

## Files in scope (edit)

- `Palace/SignInLogic/TPPSignInBusinessLogic.swift` (6 sub-sites: lines 281, 309, 732, 736, 753, 781)
- `Palace/SignInLogic/TPPSignInBusinessLogic+CardCreation.swift` (line ~17)
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift` (line ~52)
- `Palace/Notifications/NotificationService.swift` (line ~371)

## Files OFF-LIMITS

- `Palace/Accounts/Library/` (entire dir) — FROZEN or owned by Accounts-Wiring.
- All other Bucket A files — owned by other implementers in this swarm.
- `Palace/SignInLogic/TPPSignInBusinessLogic+BookmarkSyncing.swift` (Bucket B — Phase 2).
- `Palace/SignInLogic/TPPSignInBusinessLogic.swift:250` reads `authenticationDocument?.links` (NOT `details`) — leave it.
- `Palace/Accounts/User/TPPUserAccount.swift:99,102` — `details?.auths.first` fallback. Borderline-A; defer to Phase 2 audit.

## Per-call-site migration

### TPPSignInBusinessLogic.swift (6 sub-sites)

| Line | Read | Migration |
|---|---|---|
| 281 | `libraryAccount?.details?.auths` | `try await libraryAccount.awaitReady().auths` |
| 309 | `libraryAccount?.details?.userProfileUrl` | `try await libraryAccount.awaitReady().userProfileUrl` |
| 732 | `libraryAccount?.details?.signUpUrl` | `try await libraryAccount.awaitReady().signUpUrl` |
| 736 | `libraryAccount?.details?.auths.contains { $0.isSaml }` | `(try? await libraryAccount.awaitReady())?.auths.contains { $0.isSaml } ?? false` |
| 753 | `libraryAccount?.details?.auths` | `try await libraryAccount.awaitReady().auths` |
| 781 | `libraryAccount?.details?.getLicenseURL(.eula)` | `try await libraryAccount.awaitReady().getLicenseURL(.eula)` |

For sites where the enclosing function is sync, propagate `async` up one level or wrap in a `Task { ... }` with a continuation passed in — implementer picks the smaller change per call site and documents in the PR description.

SAML reauth (line 736) inherits the existing 15s reauth-coordinator timeout per ADR. Do NOT wrap awaitReady in `withTimeout`.

### TPPSignInBusinessLogic+CardCreation.swift:17

```swift
// BEFORE:
guard let signUpURL = libraryAccount?.details?.signUpUrl else { ... }

// AFTER:
guard let signUpURL = (try? await libraryAccount.awaitReady())?.signUpUrl else { ... }
```

CardCreation is user-initiated; await window is acceptable. If enclosing function is sync, wrap in `Task { ... }`.

### TPPAgeCheck.swift:52

```swift
// BEFORE:
guard let accountDetails = currentLibraryAccountProvider.currentAccount?.details else { ... }

// AFTER:
guard let currentAccount = currentLibraryAccountProvider.currentAccount else {
    completion?(false); return
}
Task {
    do {
        let accountDetails = try await currentAccount.awaitReady()
        // ... existing age-check logic with accountDetails ...
    } catch {
        await MainActor.run { completion?(false) }
    }
}
```

On `AccountLoadError`: `completion?(false)` (matches current `details == nil` path).

### NotificationService.swift:371

```swift
// BEFORE:
guard let currentAccount = self.accountsManager.currentAccount,
      currentAccount.details?.supportsReservations == true else { ... }

// AFTER:
guard let currentAccount = self.accountsManager.currentAccount else {
    completionHandler(); return
}
do {
    let details = try await currentAccount.awaitReady()
    guard details.supportsReservations else {
        Log.warn(#file, "[Notification] Cannot navigate to Holds - account doesn't support reservations")
        completionHandler(); return
    }
    // ... existing navigation logic ...
} catch {
    Log.warn(#file, "[Notification] Cannot navigate to Holds - awaitReady failed: \(error)")
    completionHandler(); return
}
```

The enclosing block is already inside `Task { @MainActor in ... }` (~line 367), so the `await` works.

## Single-timeout policy (ADR-mandated)

Never wrap awaitReady in `withTimeout`. SAML reauth path (line 736) has existing 15s reauth-coordinator timeout; everything else is user-initiated (sign-in / sign-up button, notification tap) where the existing UI spinner is the only timeout that matters.

## Tests to add (TDD — write FIRST)

Add `PalaceTests/SignInLogic/TPPSignInBusinessLogicStateMachineTests.swift`:

1. **`testSignIn_blocksUntilLoaded_thenProceeds`** — given `.detailsLoading`, sign-in path blocks; transition to `.detailsLoaded` resolves.
2. **`testSignIn_failedDetailsLoad_surfacesError`** — given `.detailsFailed`, sign-in path takes error branch instead of silent nil.
3. **`testIsSamlAuth_failedDetailsLoad_returnsFalse`** — line 736: `awaitReady` throws → `isSamlAuth` returns false (matches legacy nil semantic). Asserts migration does NOT crash on `.detailsFailed`.

Add `PalaceTests/Accounts/AgeCheck/TPPAgeCheckStateMachineTests.swift`:

4. **`testAgeCheck_blocksUntilLoaded_thenVerifies`** — same shape as #1.
5. **`testAgeCheck_failedDetailsLoad_completionFalse`** — `.detailsFailed` → `completion?(false)`.

Add `PalaceTests/Notifications/NotificationServiceStateMachineTests.swift`:

6. **`testHoldNotification_supportsReservations_navigates`** — happy path with `.detailsLoaded(supportsReservations=true)` → navigates to Holds.
7. **`testHoldNotification_doesNotSupportReservations_completes`** — `supportsReservations=false`.
8. **`testHoldNotification_detailsFailed_completes`** — failure → `completionHandler()` without navigating.

Use isolated `AccountStateStore()` per test or `_resetAllForTesting()` in DEBUG; inject via `AppContainer`.

## pbxproj

Use `ruby scripts/pbxproj_add_swift.rb --targets Palace,Palace-noDRM ...` for any new files. Test files: `--targets PalaceTests`.

## Acceptance criteria

- Build green on Palace (and Palace-noDRM if your edits touch DRM-conditioned code — listed files appear non-DRM, but verify).
- All 8 new tests pass.
- All existing PalaceTests pass.
- Mutation kill rate ≥50% on each changed file.
- `Palace/SignInLogic/` is on the critical-path enforcement list per CLAUDE.md — strict mutation gate by default.
- No edits outside this contract's scope.
- `scripts/verify-pr.sh --quick` passes.

## Reporting back

Write `.forgeos/swarms/swarm_81b5099e/transcripts/SignIn-AgeCheck-Notifications.md` with: summary, files modified, tests added, mutation results, gaps, build + test command outputs.
