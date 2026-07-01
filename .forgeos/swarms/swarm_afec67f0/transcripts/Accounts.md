# Transcript — Accounts (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. Fix by ISOLATION only. No behavior changes.

## Files modified (3 of 4 in-scope; Account+State.swift intentionally untouched)
- `Palace/Accounts/Library/Account.swift` — AccountDetails `@unchecked Sendable` (Decision 1)
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift` — `AgeCheckCallbacks` carrier box
- `Palace/Support/TriageBotFactory.swift` — isolate-at-site in `currentPalaceFields()`
- `Palace/Accounts/Library/Account+State.swift` — **NOT edited** (cascade-cleared by Decision 1)

`AccountsManager.swift` and `TPPUserAccount.swift` / `TPPUserAccountProvider` were
**not** touched (off-limits). No `nonisolated(unsafe)`; no bare `@unchecked Sendable`.

---

## CASCADE DECISION 1 — `AccountDetails` → documented `@unchecked Sendable`

**Site:** `Account.swift` `@objcMembers final class AccountDetails: NSObject`.

**Warning cleared:** `Account+State.swift:51` — `LoadState` is `public enum
LoadState: Sendable` with a `.detailsLoaded(AccountDetails)` associated value, so
its payload must be Sendable for `awaitReady()` / `stateStream` to cross actor
boundaries. Also clears the `accountDetails` capture inside TPPAgeCheck's
`@Sendable` closures for free.

**Fix:** added `@unchecked Sendable` to the conformance list with a documented
invariant comment (mirrors `TPPUserAccount` #1155).

**Mutable-state audit justifying `@unchecked`:**
- Immutable `let` (all meaningfully-observable state): `defaults`, `uuid`,
  `supportsSimplyESync`, `supportsCardCreator`, `supportsReservations`, `auths:
  [Authentication]`, `mainColor`, `userProfileUrl`, `signUpUrl`, `loansUrl`.
  `Authentication` is a `final class` whose every stored property is `let`.
- `fileprivate var url*: URL?` ×5 (`urlAnnotations`, `urlAcknowledgements`,
  `urlContentLicenses`, `urlEULA`, `urlPrivacyPolicy`) — **write-once during
  account parse** via `setURL(_:forLicense:)` (called only inside `init` and the
  parse path), read-only thereafter through `getLicenseURL(_:)`.
- Computed `eulaIsAccepted` / `syncPermissionGranted` / `userAboveAgeLimit`
  get/set delegate to `UserDefaults` via `get/setAccountDictionaryKey` — no
  instance storage is mutated; `UserDefaults` is internally thread-safe.

Once vended into `LoadState.detailsLoaded`, instances behave as immutable
value-holders. **Behavior risk: none** — conformance-only annotation, no code path
changes.

---

## Site — `TPPAgeCheck.swift` `verifyCurrentAccountAgeRequirement(...)`

**Warnings:** captures of non-Sendable values in the `@Sendable`
`serialQueue.async` / `Task` closures:
- `accountDetails` (`AccountDetails`) — cleared for free by Decision 1.
- `userAccountProvider` (`TPPUserAccountProvider`) — an `@objc protocol`.
- `completion` (`((Bool) -> Void)?`) — non-Sendable closure.

**Was `:114`'s `userAccountProvider` capture already cleared by #1155? NO.**
Verified `@objc protocol TPPUserAccountProvider: NSObjectProtocol` at
`TPPUserAccount.swift:47`. #1155 made only the **concrete** `TPPUserAccount`
class `@unchecked Sendable`; the capture in TPPAgeCheck is typed as the Obj-C
**protocol**, which remains non-Sendable. The box is required.

**Fix (isolation, no behavior change):** introduced one documented
`@unchecked Sendable` carrier `AgeCheckCallbacks { userAccountProvider,
completion }` (mirrors `SyncCallbacks` in `BookRegistrySync`). The box is built
once at the top of the method (before the `currentAccount` guard, so the
guard-else path uses it too); every `@Sendable` closure now captures the Sendable
carrier and reads `callbacks.userAccountProvider` / `callbacks.completion`.
`accountDetails` (Sendable after Decision 1) is passed directly.

Invariant comment on the box: only ever unwrapped on `serialQueue` / main actor —
`needsAuth` read + `completion` invoked exclusively inside the serial-queue /
main-actor blocks, never concurrently.

**Ordering preserved exactly:**
- Fast-path `.detailsLoaded` → `serialQueue.async { continueAgeRequirementCheck }`.
- Failure-path `.detailsFailed` / `.detailsEvicted` → `serialQueue.async {
  completion?(false) }`.
- Loading-path `.notLoaded`/`.basicInfoLoaded`/`.detailsLoading` → `Task { await
  awaitReady() }`, then `serialQueue.async`.
- `userAccountProvider.needsAuth` is still read only inside
  `continueAgeRequirementCheck` on the serial queue. `TPPUserAccountProvider`
  was NOT made Sendable.

`callbacks.completion == completion` and `callbacks.userAccountProvider ==
userAccountProvider` (value-copy of a struct holding the same references).
**Behavior risk: none.**

Note: the `Task` closure still captures `currentAccount` (an `Account`) directly
to call `awaitReady()`. The contract enumerated only `accountDetails`,
`userAccountProvider`, `completion` as the remaining non-Sendable captures (from
the A.4 warning snapshot) and forbids any change to Account beyond the
`AccountDetails` conformance edit, so `currentAccount` was left as-is per contract.

---

## Site — `TriageBotFactory.swift` `currentPalaceFields() async`

**Warning:** the code did `let manager = await MainActor.run {
AppContainer.production().accountsManager }` then read `manager.currentAccount?.name/.uuid`
**off** the main actor — the non-Sendable `AccountsManager` crossed the actor
boundary.

**Fix (isolation):** read `currentAccount` **inside** the `MainActor.run` block
and return only the already-`Sendable` `DefaultIosContextProvider.PalaceFields`.
Nothing non-Sendable crosses the boundary. `Account.name` / `Account.uuid` are
`let`, so same values, same source. **Behavior risk: none** (strictly more
correct — `currentAccount` is main-actor state).

---

## Confirmations
- `AccountDetails` conformance edit is the ONLY change to `Account.swift`.
- `Account+State.swift` needs no edit beyond what the cascade clears — untouched.
- `TPPUserAccountProvider` was NOT made Sendable (carried in the box).
- Touched ONLY the 4 in-scope files (3 edited, Account+State.swift untouched);
  `AccountsManager.swift` NOT touched.
- No mutation / verify-pr / xcresult run (no DRM build in this worktree).
