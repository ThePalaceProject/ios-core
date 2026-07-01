# Contract — Accounts (swarm_afec67f0)

Swift 6 `targeted` Phase A.5 Chunk 2. **Fix by ISOLATION only. No behavior
changes.** Line numbers are the A.4 snapshot — **locate by symbol**, verify each
still warrants a fix, and clear every capture-of-non-Sendable in the touched
functions (not only the cited lines).

## Files IN scope (yours, exclusively)
- `Palace/Accounts/Library/Account.swift`
- `Palace/Accounts/Library/Account+State.swift`
- `Palace/Accounts/AgeCheck/TPPAgeCheck.swift`
- `Palace/Support/TriageBotFactory.swift`

## OFF-LIMITS
`Palace/Accounts/User/TPPUserAccount.swift` and `TPPUserAccountProvider`
protocol — do NOT edit them (TPPUserAccount was made `@unchecked Sendable` in
#1155; the age-check userAccountProvider capture is handled at-site here, NOT by
making the protocol Sendable). All Book/Models, CarPlay, OPDS, Reader2 files.

## Global rules
- NEVER `nonisolated(unsafe)`. NO **bare** `@unchecked Sendable`. **Documented**
  `@unchecked Sendable` with a stated invariant IS allowed (mirror
  `ImageCompletionBox`, `SyncCallbacks`, `TPPAgeCheck: @unchecked Sendable`).
- Do NOT run verify-pr / palace_mutate / xcresult (no DRM build).

---

## CASCADE DECISION 1 — `AccountDetails` → documented `@unchecked Sendable` (FORCED)
**This is the anchor change. Apply it FIRST; it clears two sites.**

`Account.LoadState` (`Account+State.swift:47`) is **already declared
`public enum LoadState: Sendable`** with a `.detailsLoaded(AccountDetails)`
associated value (`:51`). There is **no isolate-at-site option** — the enum must
stay `Sendable` for `awaitReady()` / `stateStream` to cross actor boundaries.

Audit (`Account.swift:37 @objcMembers final class AccountDetails: NSObject`):
- Immutable `let`: `defaults`, `uuid`, `supportsSimplyESync`, `supportsCardCreator`,
  `supportsReservations`, `auths: [Authentication]`, `mainColor`, `userProfileUrl`,
  `signUpUrl`, `loansUrl`. (`Authentication` is a `final class` with all-`let`
  stored props.)
- Mutable `fileprivate var url*: URL?` ×5 (`urlAnnotations`, `urlAcknowledgements`,
  `urlContentLicenses`, `urlEULA`, `urlPrivacyPolicy`) — **write-once during
  account parse** via `setURL(_:forLicense:)` (`Account.swift:455`), read
  thereafter.
- Computed `eulaIsAccepted` / `syncPermissionGranted` / `userAboveAgeLimit`
  setters delegate to the internally-thread-safe `UserDefaults` — not instance
  state.

**Fix:** add `@unchecked Sendable` to `AccountDetails`'s conformance list with a
documented invariant comment:
> `@unchecked Sendable`: instances are effectively immutable value-holders once
> vended into `LoadState.detailsLoaded`. The `url*` fields are write-once during
> account parse (`setURL`); the UserDefaults-backed computed setters delegate to
> the internally-thread-safe `UserDefaults`. Mirrors `TPPUserAccount` (#1155).

**Clears:** `Account+State.swift:51` (Sendable-enum associated value) AND the
`accountDetails` capture in `TPPAgeCheck` (below). Do NOT otherwise modify
`Account+State.swift` — the `@unchecked Sendable` on `AccountDetails` is enough.

---

## Site — `TPPAgeCheck.swift` ~108/113/114/115: captures in `serialQueue.async`
`TPPAgeCheck` is ALREADY `@unchecked Sendable` at the class level
(`TPPAgeCheck.swift:25` — the "capture of self" warnings are already resolved).
Remaining warnings are captures of **non-Sendable values** in the
`serialQueue.async` (`@Sendable`) closures in
`verifyCurrentAccountAgeRequirement`:
- `accountDetails` (`AccountDetails`) — **cleared for free** by Decision 1.
- `userAccountProvider` (`TPPUserAccountProvider`, an `@objc protocol` — NOT
  Sendable; VERIFIED **not** cleared by #1155, which only touched the concrete
  `TPPUserAccount`).
- `completion` (`((Bool) -> Void)?`, non-Sendable closure).

**Fix (isolation, no behavior change):** introduce ONE **documented
`@unchecked Sendable` carrier** local to `TPPAgeCheck` (mirror `SyncCallbacks`)
holding the non-Sendable pair `{ userAccountProvider, completion }`, and have the
`serialQueue.async` closures capture the carrier instead of the raw values.
`accountDetails` is Sendable after Decision 1 and may be passed directly.
Invariant comment:
> carrier is only ever unwrapped on `serialQueue`/main — `userAccountProvider`
> is read (`.needsAuth`) and `completion` is invoked exclusively inside the
> serial-queue / main-actor blocks, never concurrently.

Preserve the exact ordering: fast-path (`.detailsLoaded` → `serialQueue.async`
directly), failure-path (`.detailsFailed`/`.detailsEvicted` →
`serialQueue.async { completion(false) }`), and loading-path (`Task { await
awaitReady() }`). Do NOT change WHEN `userAccountProvider.needsAuth` is read (it
must stay on the serial queue inside `continueAgeRequirementCheck`). **Clear
every** capture warning in the verify path, even if the cited 108/113/114/115
have drifted.

**Do NOT** make `TPPUserAccountProvider` Sendable — carry it in the box instead.

---

## CASCADE DECISION 2 — `AccountsManager` → do NOT make Sendable; isolate at site
`AccountsManager` has 27+ mutable `var` fields — a large live singleton;
`@unchecked Sendable` would be a real race waiver. **Do NOT touch AccountsManager.**

## Site — `TriageBotFactory.swift` ~104
**Warning:** in `currentPalaceFields() async` (nonisolated), the code does
`let manager = await MainActor.run { AppContainer.production().accountsManager }`
then reads `manager.currentAccount?.name/.uuid` **off** the main actor —
`AccountsManager` (non-Sendable) crossed the actor boundary.

**Fix (isolation):** read the needed fields **inside** the existing
`MainActor.run` block and return only the already-`Sendable`
`DefaultIosContextProvider.PalaceFields` (`:18 public struct PalaceFields:
Sendable`). Nothing non-Sendable crosses the boundary:

```swift
let fields = await MainActor.run { () -> DefaultIosContextProvider.PalaceFields in
    let account = AppContainer.production().accountsManager.currentAccount
    return DefaultIosContextProvider.PalaceFields(
        libraryName: account?.name,
        libraryUUID: account?.uuid,
        distributor: nil,
        authType: nil
    )
}
return fields
```
Strictly more correct (`currentAccount` is main-actor state). **Behavior risk:**
none — same values, same source. **Clears** `TriageBotFactory.swift:104`.

---

## Deliverable (paste in your report — NO mutation/xcresult)
For each site: (a) file:symbol + the exact warning, (b) the applied fix + mirror
pattern, (c) behavior risk (expected: none). Confirm: `AccountDetails` conformance
edit is the ONLY change to `Account.swift`; `Account+State.swift` needs no edit
beyond what the cascade clears; `TPPUserAccountProvider` was NOT made Sendable;
you touched ONLY the 4 files above.
